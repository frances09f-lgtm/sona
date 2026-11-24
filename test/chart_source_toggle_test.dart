import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:sona/main.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/investing_chart_page.dart';

import 'screens_test.dart' show demoState, testCandles, loadFonts;

/// Trade-tab chart source toggle (added Nov 24, 2026 for "Add investing"):
/// the native Sona chart is the default and stays verified; the
/// Investing.com box is one tap away and persists across restarts.
void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    FlutterSecureStorage.setMockInitialValues({});
    await loadFonts();
  });

  Future<void> pumpTrade(WidgetTester t, AppState app) async {
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
  }

  testWidgets('chart source toggle: Sona default, Investing switch and back',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    debugTradeTvSupported = true;
    addTearDown(() => debugTradeTvSupported = null);
    final app = demoState();
    await pumpTrade(t, app);

    // Default with no stored choice: native Sona chart.
    expect(find.byType(CandleChartPanel), findsOneWidget);
    expect(find.byType(InvestingChartView), findsNothing);

    // Switch to Investing. Off-Android the box honestly shows its note
    // instead of a WebView; the switch itself is what is verified here.
    await t.tap(find.text('Investing'));
    await t.pumpAndSettle();
    expect(find.byType(CandleChartPanel), findsNothing);
    expect(find.byType(InvestingChartView), findsOneWidget);
    expect(find.textContaining('available in the Android app'),
        findsOneWidget);
    var prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('trade_chart_mode_v1'), 'investing');

    // Back to the Sona chart.
    await t.tap(find.text('Sona chart'));
    await t.pumpAndSettle();
    expect(find.byType(CandleChartPanel), findsOneWidget);
    expect(find.byType(InvestingChartView), findsNothing);
    prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('trade_chart_mode_v1'), 'sona');
  });

  testWidgets('stored investing choice restores the Investing box',
      (t) async {
    SharedPreferences.setMockInitialValues(
        {'trade_chart_mode_v1': 'investing'});
    debugTradeTvSupported = true;
    addTearDown(() => debugTradeTvSupported = null);
    final app = demoState();
    await pumpTrade(t, app);
    expect(find.byType(InvestingChartView), findsOneWidget);
    expect(find.byType(CandleChartPanel), findsNothing);
  });
}
