import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/pending_orders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  Future<PendingPaperOrders> create() async {
    SharedPreferences.setMockInitialValues({});
    return PendingPaperOrders.load(await SharedPreferences.getInstance());
  }

  PendingPaperOrder order({bool above = false, bool gtc = true}) =>
      PendingPaperOrder(
        id: '1',
        side: 'buy',
        qty: .1,
        trigger: 4000,
        above: above,
        gtc: gtc,
        createdAt: 1,
        expiresAt: 100,
      );
  test('complete removal deletes persisted order and can never fill', () async {
    final s = await create();
    s.orders.add(order());
    await s.save();
    expect(await s.remove('1'), isTrue);
    expect(s.orders, isEmpty);
    expect(PendingPaperOrders.load(s.prefs).orders, isEmpty);
    await s.evaluate(bid: 3990, ask: 3999, fresh: true, active: true, now: 50,
      submit: (_) async => fail('removed order must not submit'));
    expect(await s.remove('1'), isFalse);
  });
  test('submitting, filled and uncertain orders cannot be removed', () async {
    final s = await create();
    for (final status in ['submitting', 'needsReview', 'filled', 'expired']) {
      s.orders.clear();
      s.orders.add(order()..status = status);
      expect(await s.remove('1'), isFalse);
      expect(s.orders.single.status, status);
    }
    s.orders.single.status = 'cancelled';
    expect(await s.remove('1'), isTrue);
    expect(PendingPaperOrders.load(s.prefs).orders, isEmpty);
  });
  test('snapshot cannot fill another order removed during first submission', () async {
    final s = await create();
    final second = PendingPaperOrder(id: '2', side: 'buy', qty: .1, trigger: 4000,
      above: false, gtc: true, createdAt: 1, expiresAt: 100);
    s.orders.addAll([order(), second]);
    final started = Completer<void>(), finish = Completer<SubmitResult>();
    var calls = 0;
    final evaluation = s.evaluate(bid: 3990, ask: 3999, fresh: true, active: true,
      now: 50, submit: (_) { calls++; started.complete(); return finish.future; });
    await started.future;
    expect(await s.remove('1'), isFalse);
    expect(await s.remove('2'), isTrue);
    finish.complete(const SubmitFilled());
    await evaluation;
    expect(calls, 1);
    expect(s.orders.single.status, 'filled');
    expect(PendingPaperOrders.load(s.prefs).orders.single.id, '1');
  });
  test('failed removal restores order and reports failure', () async {
    final base = await create();
    final o = order();
    final s = FailingRemovalStore(base.prefs, [o]);
    await expectLater(s.remove('1'), throwsStateError);
    expect(s.orders.single, same(o));
    expect(o.status, 'pending');
  });
  test(
    'threshold uses executable side, freshness and foreground, fills once',
    () async {
      final s = await create();
      s.orders.add(order());
      int calls = 0;
      Future<SubmitResult> submit(PendingPaperOrder o) async {
        calls++;
        return const SubmitFilled();
      }

      await s.evaluate(
        bid: 3990,
        ask: 4001,
        fresh: true,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 0);
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: false,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 0);
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: false,
        now: 50,
        submit: submit,
      );
      expect(calls, 0);
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 1);
      expect(s.orders.first.status, 'filled');
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 50,
        submit: submit,
      );
      expect(calls, 1);
    },
  );
  test('timeout and crash stay needs review, never retry', () async {
    final s = await create();
    s.orders.add(order());
    int calls = 0;
    await s.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 50,
      submit: (o) async {
        calls++;
        throw Exception('timeout');
      },
    );
    expect(s.orders.first.status, 'needsReview');
    await s.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 50,
      submit: (o) async {
        calls++;
        return const SubmitFilled();
      },
    );
    expect(calls, 1);
    s.orders.first.status = 'submitting';
    await s.save();
    expect(PendingPaperOrders.load(s.prefs).orders.first.status, 'needsReview');
  });
  test(
    'definitive pre-submit rejection keeps waiting with visible reason, backs off, then fills',
    () async {
      final s = await create();
      s.orders.add(order());
      var calls = 0;
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 50,
        submit: (o) async {
          calls++;
          return const SubmitRetry(
            'Estimated paper margin insufficient: needs \$8.10, available \$-7.00 at assumed 1:500.',
          );
        },
      );
      expect(calls, 1);
      expect(s.orders.single.status, 'pending');
      expect(
        s.orders.single.note,
        startsWith('Estimated paper margin insufficient'),
      );
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 100,
        submit: (o) async {
          calls++;
          return const SubmitFilled();
        },
      );
      expect(calls, 1);
      expect(s.orders.single.status, 'pending');
      await s.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 50 + PendingPaperOrders.retryBackoffMs,
        submit: (o) async {
          calls++;
          return const SubmitFilled();
        },
      );
      expect(calls, 2);
      expect(s.orders.single.status, 'filled');
      expect(s.orders.single.note, isNull);
    },
  );
  test('retry backoff timestamp survives reload', () async {
    final s = await create();
    s.orders.add(order());
    var calls = 0;
    await s.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 50,
      submit: (o) async {
        calls++;
        return const SubmitRetry(
          'Another paper order is being checked. Wait for its result.',
        );
      },
    );
    expect(calls, 1);
    final reloaded = PendingPaperOrders.load(s.prefs);
    await reloaded.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 100,
      submit: (o) async {
        calls++;
        return const SubmitFilled();
      },
    );
    expect(calls, 1);
    expect(reloaded.orders.single.status, 'pending');
  });
  test(
    'stuck needs-review orders recover to waiting only when the note proves pre-submit rejection',
    () async {
      final s = await create();
      s.orders.add(
        PendingPaperOrder(
          id: 'margin',
          side: 'buy',
          qty: .1,
          trigger: 4000,
          above: false,
          gtc: true,
          createdAt: 1,
          expiresAt: 100,
          status: 'needsReview',
          note:
              'Estimated paper margin insufficient: needs \$8.10, available \$-7.00 at assumed 1:500. Reduce oz.',
        ),
      );
      s.orders.add(
        PendingPaperOrder(
          id: 'unknown',
          side: 'buy',
          qty: .1,
          trigger: 4000,
          above: false,
          gtc: true,
          createdAt: 1,
          expiresAt: 100,
          status: 'needsReview',
          note:
              'Submission outcome unknown. Check positions. No automatic retry.',
        ),
      );
      await s.save();
      final reloaded = PendingPaperOrders.load(s.prefs);
      expect(reloaded.orders[0].status, 'pending');
      expect(
        reloaded.orders[0].note,
        startsWith('Estimated paper margin insufficient'),
      );
      expect(reloaded.orders[1].status, 'needsReview');
      await reloaded.evaluate(
        bid: 3990,
        ask: 3999,
        fresh: true,
        active: true,
        now: 50,
        submit: (o) async => const SubmitFilled(),
      );
      expect(reloaded.orders[0].status, 'filled');
      expect(reloaded.orders[1].status, 'needsReview');
    },
  );
  test('expiry and cancel cannot fill', () async {
    final s = await create();
    s.orders.add(order(gtc: false));
    await s.evaluate(
      bid: 3990,
      ask: 3999,
      fresh: true,
      active: true,
      now: 100,
      submit: (o) async => throw Exception('must not submit'),
    );
    expect(s.orders.first.status, 'expired');
    s.orders.clear();
    s.orders.add(order());
    await s.cancel('1');
    expect(s.orders.first.status, 'cancelled');
  });
}

class FailingRemovalStore extends PendingPaperOrders {
  FailingRemovalStore(super.prefs, super.orders);
  @override
  Future<void> save() async => throw StateError('test storage failed');
}
