import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/main.dart';
import 'package:sona/pending_orders.dart';

import 'screens_test.dart' show loadFonts;

class PendingAccount extends AppState {
  int journalCalls = 0, fills = 0;
  @override
  bool get priceFresh => true;
  @override
  Future<String?> saveTrade(Map<String, dynamic> record) async {
    journalCalls++;
    trades.add(record);
    notifyListeners();
    return null;
  }

  @override
  Future<String?> openPaper(
    String side,
    double qty,
    double? tp,
    double? sl,
  ) async {
    fills++;
    return null;
  }
}

Future<SubmitResult> submitVia(PendingAccount app, PendingPaperOrder o) async {
  final e = await app.openPaper(o.side, o.qty, o.tp, o.sl);
  return e == null ? const SubmitFilled() : SubmitUnknown(e);
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Future<PendingAccount> account() async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  return PendingAccount()
    ..prefs = prefs
    ..pendingOrders = PendingPaperOrders.load(prefs)
    ..unlocked = true
    ..bid = 4000
    ..ask = 4001
    ..price = 4000.5
    ..priceOk = true
    ..priceAt = DateTime.now().millisecondsSinceEpoch;
}

Future<GlobalKey> mount(WidgetTester t, Widget child) async {
  t.view.physicalSize = const Size(780, 1688);
  t.view.devicePixelRatio = 2;
  addTearDown(t.view.reset);
  await loadFonts();
  final key = GlobalKey();
  await t.pumpWidget(
    RepaintBoundary(
      key: key,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: Scaffold(body: SafeArea(child: child)),
      ),
    ),
  );
  await t.pumpAndSettle();
  return key;
}

Future<void> capture(WidgetTester t, GlobalKey key, String name) async {
  if (Platform.environment['PENDING_CAPTURE'] != '1') return;
  await t.pumpAndSettle();
  await t.runAsync(() async {
    final img =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/sona-$name.png').writeAsBytes(bytes!.buffer.asUint8List());
  });
}

void main() {
  testWidgets(
    'Add tab creates visible persistent price order, not journal or immediate fill',
    (t) async {
      final app = await account();
      final key = await mount(t, AddTab(app: app));
      expect(find.text('Buy at entry price'), findsOneWidget);
      await t.tap(find.text('Buy at entry price'));
      await t.pumpAndSettle();
      await t.ensureVisible(field('Entry price'));
      await t.enterText(field('Entry price'), '3990');
      await t.ensureVisible(find.text('Save pending order'));
      await capture(t, key, 'pending-entry');
      await t.tap(find.text('Save pending order'));
      await t.pumpAndSettle();
      expect(app.journalCalls, 0);
      expect(app.fills, 0);
      expect(app.pendingOrders!.orders.single.trigger, 3990);
      expect(app.pendingOrders!.orders.single.above, false);
      expect(
        PendingPaperOrders.load(app.prefs!).orders.single.status,
        'pending',
      );
      expect(
        find.textContaining('Waiting for Ask at or below 3,990.00'),
        findsOneWidget,
      );
      await capture(t, key, 'pending-added');
      final portfolioKey = await mount(t, PositionsTab(app: app));
      expect(
        find.textContaining('Waiting for Ask at or below 3,990.00'),
        findsOneWidget,
      );
      await capture(t, portfolioKey, 'pending-portfolio');
      final store = app.pendingOrders!;
      await store.evaluate(
        bid: 3989,
        ask: 3990,
        fresh: true,
        active: true,
        now: DateTime.now().millisecondsSinceEpoch,
        submit: (o) => submitVia(app, o),
      );
      app.notifyListeners();
      await t.pumpAndSettle();
      expect(app.fills, 1);
      expect(find.text('Filled'), findsNothing);
      expect(find.text('Pending orders'), findsNothing);
      await capture(t, portfolioKey, 'pending-auto-removed');
      await store.evaluate(
        bid: 3989,
        ask: 3990,
        fresh: true,
        active: true,
        now: DateTime.now().millisecondsSinceEpoch,
        submit: (o) => submitVia(app, o),
      );
      expect(app.fills, 1);
    },
  );
  testWidgets(
    'sell entry uses bid direction and complete removal persists across restart',
    (t) async {
      final app = await account();
      await mount(t, AddTab(app: app));
      await t.tap(find.text('Sell at entry price'));
      await t.pumpAndSettle();
      await t.ensureVisible(field('Entry price'));
      await t.enterText(field('Entry price'), '4010');
      await t.tap(find.text('Save pending order'));
      await t.pumpAndSettle();
      final saved = app.pendingOrders!.orders.single;
      expect(saved.side, 'sell');
      expect(saved.above, true);
      expect(saved.qty, 1);
      app.pendingOrders = PendingPaperOrders.load(app.prefs!);
      await mount(t, PositionsTab(app: app));
      expect(
        find.textContaining('Waiting for Bid at or above 4,010.00'),
        findsOneWidget,
      );
      await t.tap(find.byTooltip('Remove order'));
      await t.pumpAndSettle();
      expect(find.text('Cancelled'), findsNothing);
      expect(find.textContaining('Waiting for Bid'), findsNothing);
      expect(
        PendingPaperOrders.load(app.prefs!).orders,
        isEmpty,
      );
      await app.pendingOrders!.evaluate(
        bid: 4010,
        ask: 4011,
        fresh: true,
        active: true,
        now: DateTime.now().millisecondsSinceEpoch,
        submit: (o) => submitVia(app, o),
      );
      expect(app.fills, 0);
    },
  );
  testWidgets(
    'uncertain submission is visible in Portfolio and never retried',
    (t) async {
      final app = await account();
      app.pendingOrders!.orders.add(
        PendingPaperOrder(
          id: 'uncertain',
          side: 'buy',
          qty: 1,
          trigger: 3990,
          above: false,
          gtc: true,
          createdAt: 1,
          expiresAt: 2,
        ),
      );
      int attempts = 0;
      Future<SubmitResult> fail(PendingPaperOrder o) async {
        attempts++;
        throw StateError('test transport');
      }

      await app.pendingOrders!.evaluate(
        bid: 3989,
        ask: 3990,
        fresh: true,
        active: true,
        now: 3,
        submit: fail,
      );
      await mount(t, PositionsTab(app: app));
      expect(
        find.text('Needs review - check positions before retrying'),
        findsOneWidget,
      );
      expect(find.byTooltip('Remove order'), findsNothing);
      await app.pendingOrders!.evaluate(
        bid: 3989,
        ask: 3990,
        fresh: true,
        active: true,
        now: 4,
        submit: fail,
      );
      expect(attempts, 1);
      expect(
        PendingPaperOrders.load(app.prefs!).orders.single.status,
        'needsReview',
      );
    },
  );
  testWidgets('Add manual journal remains non-executable', (t) async {
    final app = await account();
    await mount(t, AddTab(app: app));
    await t.enterText(field('Entry'), '3900');
    await t.dragUntilVisible(
      find.text('Save trade'),
      find.byType(Scrollable).first,
      const Offset(0, -300),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('Save trade'));
    await t.pumpAndSettle();
    expect(app.journalCalls, 1);
    expect(app.pendingOrders!.orders, isEmpty);
    expect(app.fills, 0);
  });
}
