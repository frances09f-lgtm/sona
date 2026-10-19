import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/ai_paper_allocation.dart';
import 'package:sona/auto_trade.dart';
import 'package:sona/main.dart';
import 'package:sona/slippage.dart';

import 'candle_chart_test.dart' show loadFonts;

class FakeAccount extends AppState {
  final orders = <Map<String, dynamic>>[];
  double refreshedBalance = 20;
  bool failRefresh = false;
  bool injectPosition = false;
  FakeAccount() {
    unlocked = true;
    pin = 'synthetic';
    balance = 10;
    price = 4185.5;
    bid = 4185;
    ask = 4186;
    priceOk = true;
    priceAt = DateTime.now().millisecondsSinceEpoch;
  }
  @override
  Future<void> paperRefresh() async {
    if (failRefresh) return;
    balance = refreshedBalance;
    accountRevision++;
    if (injectPosition) {
      positions = [
        {'status': 'open', 'qty': .1, 'entry': 4186, 'direction': 'buy'},
      ];
    }
  }

  @override
  Future<dynamic> rpc(String fn, Map<String, dynamic> args) async {
    expect(fn, 'paper_open');
    orders.add(args);
    return {};
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  AiPaperAllocation? allocate({
    double balance = 10,
    double bid = 4185,
    double ask = 4186,
    double entry = 4186,
    double pct = 100,
    double fixed = 0,
    double extra = 0,
    List<Map<String, dynamic>> positions = const [],
  }) => sizeAiPaperTrade(
    balance: balance,
    bid: bid,
    ask: ask,
    entryPrice: entry,
    percent: pct,
    positions: positions,
    fixedCosts: fixed,
    extraCostPerOz: extra,
  );
  test('100% allocates cash notional including spread/fill costs, not 500x leverage or stop risk', () {
    for (final b in [0.01, 10.0, 10000.0]) {
      for (final entry in [4185.0, 4186.0]) {
        final a = allocate(
          balance: b,
          entry: entry,
          extra: .1,
          fixed: b * .01,
        )!;
        expect(a.budget, b);
        expect(a.quantity, greaterThan(0));
        expect(a.quantity * (4186 + 1 + .1) + b * .01, closeTo(b, 1e-9));
        expect(a.quantity * entry, lessThan(b));
        expect(a.quantity, lessThan(b / 4185));
      }
    }
    expect(
      allocate(pct: 10)!.quantity,
      closeTo(allocate()!.quantity * .1, 1e-12),
    );
    expect(allocate(ask: 4200)!.quantity, lessThan(allocate()!.quantity));
    expect(allocate(extra: 5)!.quantity, lessThan(allocate()!.quantity));
  });
  test(
    'zero, invalid account/quote/budget and existing positions fail closed',
    () {
      for (final b in [0.0, -1.0, double.nan, double.infinity]) {
        expect(allocate(balance: b), isNull);
      }
      for (final pct in [0.0, -1.0, 101.0, double.nan]) {
        expect(allocate(pct: pct), isNull);
      }
      expect(allocate(bid: 4187), isNull);
      expect(allocate(ask: double.nan), isNull);
      expect(allocate(fixed: 10), isNull);
      expect(allocate(fixed: -1), isNull);
      expect(allocate(extra: double.infinity), isNull);
      expect(
        allocate(
          positions: [
            {'status': 'open', 'qty': 1, 'entry': 4180, 'direction': 'buy'},
          ],
        ),
        isNull,
      );
      expect(
        allocate(
          positions: [
            {'status': 'open', 'qty': null},
          ],
        ),
        isNull,
      );
      expect(
        allocate(
          positions: [
            {'status': 'closed', 'qty': null},
          ],
        ),
        isNotNull,
      );
    },
  );
  test('opt-in persists independently; default sizing/enabled/protection preferences retained', () async {
    SharedPreferences.setMockInitialValues({
      'tj_ai_size_pct': 15.0,
      'tj_ai_enabled': false,
      'tj_slippage_mode': 'low',
    });
    final p = await SharedPreferences.getInstance();
    expect(AutoTrade.usesFullBalance(p), false);
    await AutoTrade.setFullBalance(p, true);
    await p.reload();
    expect(AutoTrade.usesFullBalance(p), true);
    expect(p.getDouble('tj_ai_size_pct'), 15);
    expect(p.getBool('tj_ai_enabled'), false);
    expect(p.getString('tj_slippage_mode'), 'low');
    await AutoTrade.setFullBalance(p, false);
    expect(p.getDouble('tj_ai_size_pct'), 15);
  });
  testWidgets(
    'real foreground order path sizes after account refresh, keeps side/SL/TP and precision',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      for (final side in ['buy', 'sell']) {
        final a = FakeAccount()..slippage = const Slippage('low');
        final tp = side == 'buy' ? 4200.0 : 4170.0,
            sl = side == 'buy' ? 4170.0 : 4200.0;
        final r = await a.openAiFullBalance(side, tp, sl);
        expect(r.error, isNull);
        expect(a.orders.length, 1);
        final order = a.orders.single;
        expect(order['target'], tp);
        expect(order['stop'], sl);
        expect(order['d'], side);
        final q = order['q'] as double;
        expect(q, r.quantity);
        expect(q, greaterThan(10 / 4186));
        expect(q * 4187.15, lessThanOrEqualTo(20.001));
        a.dispose();
      }
    },
  );
  testWidgets(
    'refresh failure, newly opened position, invalid balance/SL, stale quote and concurrent order block actual RPC',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      for (final prepare in <void Function(FakeAccount)>[
        (a) => a.failRefresh = true,
        (a) => a.injectPosition = true,
        (a) => a.refreshedBalance = 0,
        (a) => a.refreshedBalance = double.nan,
        (a) => a.priceAt = 1,
        (a) => a.openingPaper = true,
      ]) {
        final a = FakeAccount();
        prepare(a);
        expect((await a.openAiFullBalance('buy', 4200, 4170)).error, isNotNull);
        expect(a.orders, isEmpty);
        a.dispose();
      }
      final a = FakeAccount();
      expect((await a.openAiFullBalance('buy', 4170, 4200)).error, isNotNull);
      expect(a.orders, isEmpty);
      a.dispose();
    },
  );
  testWidgets(
    'AI screen opt-in works without enabling AI or changing saved default',
    (t) async {
      SharedPreferences.setMockInitialValues({'tj_ai_size_pct': 15.0});
      FlutterSecureStorage.setMockInitialValues({});
      await loadFonts();
      await t.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final app = FakeAccount(), image = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: image,
          child: MaterialApp(
            theme: ThemeData.dark(),
            debugShowCheckedModeBanner: false,
            home: Scaffold(body: AiTab(app: app)),
          ),
        ),
      );
      await t.pumpAndSettle();
      final sw = find.byKey(const ValueKey('ai-full-balance'));
      await t.ensureVisible(sw);
      await t.tap(sw);
      await t.pumpAndSettle();
      final p = await SharedPreferences.getInstance();
      expect(AutoTrade.usesFullBalance(p), true);
      expect(p.getBool('tj_ai_enabled') ?? false, false);
      expect(p.getDouble('tj_ai_size_pct'), 15);
      expect(app.orders, isEmpty);
      expect(find.textContaining('High allocation:'), findsOneWidget);
      expect(t.takeException(), isNull);
      await t.runAsync(() async {
        final im =
            await (image.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/home/user/workspace/sona-ai-chart-evidence/ai-full-balance-synthetic.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        im.dispose();
      });
      await t.tap(sw);
      await t.pumpAndSettle();
      expect(AutoTrade.usesFullBalance(p), false);
      expect(p.getDouble('tj_ai_size_pct'), 15);
      await t.pumpWidget(const SizedBox());
      app.dispose();
    },
  );
}
