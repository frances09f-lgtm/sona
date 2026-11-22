import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/main.dart';
import 'package:sona/pending_orders.dart';

/// Fill-to-position verification: a pending order crossing its trigger runs
/// the REAL AppState.openPaper -> openPaperDetailed path (freshness checks,
/// margin guard, protection validation, account refresh) with only the
/// network boundary (rpc) replaced by canned paper-backend responses.
/// Synthetic fresh quote; no real account, order, or production change.
class FillAccount extends AppState {
  final List<String> rpcCalls = [];
  bool opened = false;

  @override
  Future<dynamic> rpc(String fn, Map<String, dynamic> args) async {
    rpcCalls.add(fn);
    switch (fn) {
      case 'paper_open':
        opened = true;
        return null;
      case 'paper_state':
        return {
          'starting': 10000,
          'balance': 10000,
          'positions': opened
              ? [
                  {
                    'id': 'fx-1',
                    'direction': args.containsKey('d') ? args['d'] : 'buy',
                    'qty': 0.01,
                    'entry': 3990.0,
                    'status': 'open',
                  },
                ]
              : [],
        };
    }
    throw StateError('unexpected rpc: $fn');
  }
}

void main() {
  test('pending fill runs production open path and yields a real position',
      () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final app = FillAccount()
      ..prefs = prefs
      ..pendingOrders = PendingPaperOrders.load(prefs)
      ..unlocked = true
      ..pin = 'test-pin'
      ..bid = 4000
      ..ask = 4001
      ..price = 4000.5
      ..priceOk = true
      ..priceAt = DateTime.now().millisecondsSinceEpoch;
    expect(app.priceFresh, isTrue);

    app.pendingOrders!.orders.add(
      PendingPaperOrder(
        id: 'fill-1',
        side: 'buy',
        qty: 0.01,
        trigger: 3990,
        above: false,
        gtc: true,
        createdAt: 1,
        expiresAt: 2,
      ),
    );

    await app.pendingOrders!.evaluate(
      bid: 3989,
      ask: 3990,
      fresh: true,
      active: true,
      now: DateTime.now().millisecondsSinceEpoch,
      submit: (o) async {
        final e = await app.openPaper(o.side, o.qty, o.tp, o.sl);
        return e == null ? const SubmitFilled() : SubmitUnknown(e);
      },
    );

    expect(app.pendingOrders!.orders.single.status, 'filled');
    expect(app.rpcCalls.where((c) => c == 'paper_open').length, 1);
    expect(app.positions.length, 1);
    expect(app.positions.single['direction'], 'buy');
    expect(app.positions.single['status'], 'open');
    expect(
      PendingPaperOrders.load(prefs).orders.single.status,
      'filled',
    );
  });
}
