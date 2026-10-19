import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';
import 'package:sona/journal_record.dart';

import 'screens_test.dart' show loadFonts;

class PreviewAccount extends AppState {
  Map<String, dynamic>? saved;
  int calls = 0;
  @override
  bool get priceFresh => true;
  @override
  Future<String?> saveTrade(Map<String, dynamic> t) async {
    saved = Map.from(t);
    return null;
  }

  @override
  Future<String?> openPaper(
    String side,
    double qty,
    double? tp,
    double? sl,
  ) async {
    calls++;
    return null;
  }
}

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Future<void> capture(WidgetTester t, GlobalKey key, String name) async {
  await t.pumpAndSettle();
  await t.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/sona-$name-synthetic.png')
        .writeAsBytes(bytes!.buffer.asUint8List());
  });
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

void main() {
  testWidgets(
    'risk calculator and preview at 390px, wrong-sided stop cannot submit',
    (t) async {
      final app = PreviewAccount()
        ..bid = 4000
        ..ask = 4001
        ..balance = 10000;
      final key = await mount(t, PaperOrderSheet(app: app, side: 'sell'));
      await t.tap(find.byType(Switch).last);
      await t.pumpAndSettle();
      await t.enterText(field('Take Profit Level (optional)'), '3980');
      await t.enterText(field('Stop Loss Level (optional)'), '4010');
      await t.ensureVisible(find.text('Calculate size from stop'));
      await t.tap(find.text('Calculate size from stop'));
      await t.pump();
      expect(
        (t.widget<TextField>(find.byType(TextField).first)).controller!.text,
        '0.10',
      );
      expect(find.text('Loss at stop: \$100.00'), findsOneWidget);
      expect(find.textContaining('Reward/risk 2.00'), findsOneWidget);
      await t.ensureVisible(find.text('Order preview · USD'));
      await capture(t, key, 'risk-preview');
      await t.enterText(field('Stop Loss Level (optional)'), '3990');
      await t.ensureVisible(find.text('Place Order at 4000.00'));
      await t.tap(find.text('Place Order at 4000.00'));
      await t.pump();
      expect(app.calls, 0);
      expect(find.text('Stop loss must be above entry.'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'journal captures size/cost/tag and saves correctly sized net at 390px',
    (t) async {
      final app = PreviewAccount();
      final key = await mount(t, AddTab(app: app));
      await t.enterText(field('Entry'), '4000');
      await t.enterText(field('Exit (optional)'), '4010');
      await t.enterText(field('Quantity (lots · 1 lot = 100 oz)'), '0.02');
      await t.enterText(field('Total costs (USD)'), '3');
      await t.enterText(field('Setup tag (optional)'), 'Breakout');
      await capture(t, key, 'journal');
      expect(
        t
            .widget<TextField>(field('Net PnL USD (auto; editable override)'))
            .controller!
            .text,
        '17.0',
      );
      await t.ensureVisible(find.text('Save trade'));
      await t.tap(find.text('Save trade'));
      await t.pumpAndSettle();
      expect(app.saved?['qty'], 2);
      expect(app.saved?['pnl'], 17);
      expect(app.saved?['costs'], 3);
      expect(app.saved?['setup'], 'Breakout');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets(
    'manual source and simulated results stay separate, legacy is explicit',
    (t) async {
      final app = PreviewAccount()
        ..trades = [
          decodeJournal({
            'id': 'a',
            'pnl': -20,
            'traded_at': '2026-10-10T10:00:00Z',
            'note': 'kept',
          }),
        ]
        ..positions = [
          {
            'id': 'p',
            'status': 'closed',
            'qty': 1,
            'pnl': 50,
            'closed_at': '2026-10-10T10:00:00Z',
          },
        ];
      final key = await mount(t, StatsTab(app: app));
      expect(find.text('\$+50.00'), findsWidgets);
      await t.tap(find.text('Manual journal'));
      await t.pumpAndSettle();
      expect(find.textContaining('1 legacy record'), findsOneWidget);
      expect(find.text('\$+50.00'), findsNothing);
      expect(find.text('Performance by setup'), findsOneWidget);
      await capture(t, key, 'manual-performance');
      expect(t.takeException(), isNull);
    },
  );
}
