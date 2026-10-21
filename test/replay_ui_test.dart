import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sona/main.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/sessions.dart';

import 'screens_test.dart' show demoState, testCandles, loadFonts;

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    await loadFonts();
    SessionsStrip.debugNow = () => DateTime.utc(2026, 10, 7, 14, 0);
  });

  testWidgets('Bar replay: pick start, step, paper BUY, golden', (t) async {
    final app = demoState();
    t.view.physicalSize = const Size(390 * 2, 844 * 2);
    t.view.devicePixelRatio = 2.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildAppTheme(),
        home: AnimatedBuilder(
          animation: app,
          builder: (_, __) => Scaffold(
            body: SafeArea(
              child: TradeTab(app: app, candleLoaderOverride: testCandles),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();

    // Trade page is chromeless: replay is entered via the fullscreen
    // editor's left toolbar, which pops back into pick mode.
    await t.tap(find.byIcon(Icons.fullscreen));
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.play_circle_outline));
    await t.pumpAndSettle();
    expect(
      find.text('Tap the candle where replay should start'),
      findsOneWidget,
    );

    // Tap a candle left-of-center as the replay start, then Start.
    final chart = t.getRect(find.byType(CandleChartPanel));
    await t.tapAt(Offset(chart.left + chart.width * 0.45, chart.top + 140));
    await t.pumpAndSettle();
    await t.tap(find.text('Start'));
    await t.pumpAndSettle();

    expect(find.text('REPLAY'), findsOneWidget);
    expect(find.text('SELL GOLD · Paper order'), findsNothing);

    // Step two bars forward and open a paper BUY at the bar close.
    await t.tap(find.byKey(const ValueKey('replay-step')));
    await t.pumpAndSettle();
    await t.tap(find.byKey(const ValueKey('replay-step')));
    await t.pumpAndSettle();
    await t.tap(find.text('BUY'));
    await t.pumpAndSettle();
    expect(find.textContaining('1 open'), findsOneWidget);
    expect(find.text('Close all'), findsOneWidget);
    expect(app.positions.length, 4, reason: 'live account untouched');
    expect(t.takeException(), isNull);

    await expectLater(
      find.byType(MaterialApp),
      matchesGoldenFile('goldens/chart_replay.png'),
    );

    // Exit restores the live ticket buttons.
    await t.tap(find.byIcon(Icons.close).first);
    await t.pumpAndSettle();
    expect(find.text('REPLAY'), findsNothing);
  });
}
