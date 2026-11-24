import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/main.dart';

import 'screens_test.dart' show demoState, loadFonts, testCandles;

// Preview capture (user request Nov 24 2026): what the Sona chart looks
// like with its built-in indicators switched on - SMA20, EMA50, SMA200,
// Bollinger on the price pane plus RSI and MACD panes. Fixture data,
// synthetic; no app-code change, capture only. Runs in the fixture
// evidence step of sona-orion.yml; the PNG lands in fixture-ui-evidence.
void main() {
  testWidgets('sona chart with built-in indicators on (capture)', (t) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues(
      {'trade_chart_mode_v1': 'sona'});
    final app = demoState();
    app.prefs = await SharedPreferences.getInstance();
    final key = GlobalKey();
    await t.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: Scaffold(
            body: TradeTab(app: app, candleLoaderOverride: testCandles),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.fullscreen));
    await t.pumpAndSettle();
    final st = t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
    st.setState(() {
      st.smaOn = true;
      st.emaOn = true;
      st.sma200On = true;
      st.bollingerOn = true;
      st.rsiOn = true;
      st.macdOn = true;
    });
    await t.pumpAndSettle();
    await t.runAsync(() async {
      final im = await (key.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage();
      final b = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-chart-indicators-synthetic.png')
          .writeAsBytes(b!.buffer.asUint8List());
    });
    expect(t.takeException(), isNull);
  });
}
