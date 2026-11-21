import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/main.dart';

import 'screens_test.dart' show demoState, loadFonts;

Future<AppState> mountStats(WidgetTester t, AppState app) async {
  await t.binding.setSurfaceSize(const Size(412, 915));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: AnimatedBuilder(
        animation: app,
        builder: (_, __) => Scaffold(body: SafeArea(child: StatsTab(app: app))),
      ),
    ),
  );
  await t.pump();
  return app;
}

Map<String, dynamic> closedTrade(String id, double pnl, String closedAt) => {
  'id': id,
  'direction': 'buy',
  'entry': 4100.0,
  'qty': 1.0,
  'tp': null,
  'sl': null,
  'pnl': pnl,
  'exit': 4101.0,
  'status': 'closed',
  'opened_at': closedAt,
  'closed_at': closedAt,
  'reason': 'tp',
};

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await loadFonts();
  });

  testWidgets('Stats cards show real counts, win rate and honest signal state', (t) async {
    final app = demoState();
    app.positions = [
      closedTrade('a', 6.10, '2026-11-18T21:40:00'),
      closedTrade('b', -2.30, '2026-11-17T15:05:00'),
      closedTrade('c', 4.00, '2026-11-19T10:00:00'),
    ];
    await mountStats(t, app);
    expect(find.text('PERFORMANCE'), findsOneWidget);
    expect(find.text('CUMULATIVE CLOSED PNL'), findsOneWidget);
    expect(
      find.text('Cumulative closed PnL · 3 trade(s) · real timestamps.'),
      findsOneWidget,
    );
    expect(find.text('WIN RATE'), findsOneWidget);
    expect(find.text('67%'), findsWidgets); // 2 wins of 3 (card + summary row)
    expect(find.text('TRADES'), findsOneWidget);
    expect(find.text('3'), findsWidgets);
    expect(find.text('SIGNALS TODAY'), findsOneWidget);
    expect(
      find.textContaining('resets at midnight IST'),
      findsOneWidget,
    );
    // Step chart is painted from real records.
    final charts = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter != null &&
          w.painter.runtimeType.toString() == '_PnlStepChart',
    );
    expect(charts, findsOneWidget);
  });

  testWidgets('Single closed trade keeps the honest insufficient-history note', (t) async {
    final app = demoState();
    app.positions = [closedTrade('a', 6.10, '2026-11-18T21:40:00')];
    await mountStats(t, app);
    expect(
      find.text('Only 1 closed trade yet. The curve appears once more history exists.'),
      findsOneWidget,
    );
    expect(find.text('Cumulative closed PnL · 1 trade(s) · real timestamps.'), findsOneWidget);
  });

  testWidgets('No closed trades: honest empty state, no fabricated curve', (t) async {
    final app = demoState();
    app.positions = [];
    await mountStats(t, app);
    expect(find.text('No closed trades in this view yet.'), findsOneWidget);
    expect(find.text('--'), findsOneWidget); // win rate placeholder
    expect(find.text('0'), findsWidgets); // trades count
    final charts = find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter != null &&
          w.painter.runtimeType.toString() == '_PnlStepChart',
    );
    expect(charts, findsNothing);
  });
}
