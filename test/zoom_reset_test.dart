import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';

import 'candle_chart_test.dart' show fakeCandles, loadFonts;

void main() {
  testWidgets('double-tap resets zoom/scroll to auto-fit newest', (t) async {
    await loadFonts();
    final data = fakeCandles(120);
    final key = GlobalKey<CandleChartPanelState>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 420,
            child: CandleChartPanel(
              key: key,
              loader: (iv) async => data,
              livePrice: data.last.close,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    final st = key.currentState!;
    // Simulate the user zooming in and scrolling back.
    st.debugSetView(visibleCount: 30, scroll: 12);
    await t.pumpAndSettle();
    expect(st.visibleOverride, 30);
    expect(st.scrollCandles, 12);
    await t.tap(find.byType(CandleChartPanel));
    await t.pump(const Duration(milliseconds: 60));
    await t.tap(find.byType(CandleChartPanel));
    await t.pumpAndSettle();
    expect(st.visibleOverride, isNull);
    expect(st.scrollCandles, 0);
    expect(t.takeException(), isNull);
  });

  testWidgets('pinch zoom clamp allows down to 8 visible bars', (t) async {
    await loadFonts();
    final data = fakeCandles(120);
    final key = GlobalKey<CandleChartPanelState>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 380,
            height: 420,
            child: CandleChartPanel(
              key: key,
              loader: (iv) async => data,
              livePrice: data.last.close,
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    key.currentState!.debugSetView(visibleCount: 8, scroll: 0);
    await t.pumpAndSettle();
    expect(key.currentState!.visibleOverride, 8);
    expect(t.takeException(), isNull);
  });
}
