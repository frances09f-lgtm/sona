import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';

import 'candle_chart_test.dart' show fakeCandles, loadFonts;

Future<GlobalKey<CandleChartPanelState>> pumpChart(WidgetTester t) async {
  await loadFonts();
  final data = fakeCandles(200);
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
  return key;
}

void main() {
  testWidgets('focal-anchored pinch keeps the focal candle stationary',
      (t) async {
    final key = await pumpChart(t);
    final st = key.currentState!;
    st.debugSetView(visibleCount: 60, scroll: 40);
    await t.pumpAndSettle();

    // Two-finger pinch inward (zoom in 2x) with focal near left-center.
    final center = t.getCenter(find.byType(CandleChartPanel));
    final focal = Offset(center.dx - 40, center.dy);
    final g1 = await t.startGesture(focal);
    final g2 = await t.startGesture(focal + const Offset(100, 0));
    await t.pump();
    await g2.moveBy(const Offset(70, 0));
    await t.pump();
    await g1.moveBy(const Offset(-30, 0));
    await t.pump();
    await g1.up();
    await g2.up();
    await t.pumpAndSettle();
    // Zoomed in meaningfully but clamped, no exceptions.
    expect(st.visibleOverride, isNotNull);
    expect(st.visibleOverride! < 60, isTrue);
    expect(st.visibleOverride! >= 8, isTrue);
    expect(t.takeException(), isNull);
  });

  testWidgets('fling scrolls kinetically past the drag end, then settles',
      (t) async {
    final key = await pumpChart(t);
    final st = key.currentState!;
    st.debugSetView(visibleCount: 40, scroll: 0);
    await t.pumpAndSettle();
    // Fast drag left-to-right = scroll back in time (content follows finger).
    await t.fling(
        find.byType(CandleChartPanel), const Offset(300, 0), 1800);
    final afterDrag = st.scrollCandles;
    await t.pump(const Duration(milliseconds: 200));
    final later = st.scrollCandles;
    // ignore: avoid_print
    print('SCROLL afterDrag=$afterDrag later=$later');
    expect(later > afterDrag, isTrue,
        reason: 'kinetic scroll should continue past the drag');
    // Let it decay fully.
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    final settled = st.scrollCandles;
    await t.pump(const Duration(milliseconds: 300));
    expect(st.scrollCandles, settled,
        reason: 'scroll should settle after decay');
    expect(t.takeException(), isNull);
  });

  testWidgets('price-axis drag scales the price range, double-tap resets',
      (t) async {
    final key = await pumpChart(t);
    final st = key.currentState!;
    st.debugSetView(visibleCount: 60, scroll: 0);
    await t.pumpAndSettle();
    final rect = t.getRect(find.byType(CandleChartPanel));
    // Vertical drag on the right price axis pad (last ~40px), downward =
    // expand the range.
    final g = await t
        .startGesture(Offset(rect.right - 20, rect.center.dy - 60));
    await t.pump();
    for (var i = 0; i < 10; i++) {
      await g.moveBy(const Offset(0, 12));
      await t.pump();
    }
    await g.up();
    await t.pumpAndSettle();
    // ignore: avoid_print
    print('PRICESCALE after drag: ${st.debugPriceScale}');
    expect(st.debugPriceScale > 1.0, isTrue,
        reason: 'dragging the price axis down should expand the range');
    // Double-tap on the chart area resets everything incl. the price scale.
    await t.tapAt(rect.center);
    await t.pump(const Duration(milliseconds: 60));
    await t.tapAt(rect.center);
    await t.pumpAndSettle();
    expect(st.debugPriceScale, 1.0);
    expect(t.takeException(), isNull);
  });

  testWidgets('press-and-hold shows the crosshair and drags it', (t) async {
    final key = await pumpChart(t);
    final st = key.currentState!;
    final center = t.getCenter(find.byType(CandleChartPanel));
    final g = await t.startGesture(center);
    await t.pump(const Duration(milliseconds: 600)); // long-press timeout
    expect(st.crosshairMode, isTrue);
    expect(st.crosshairPos, isNotNull);
    await g.moveBy(const Offset(40, -30));
    await t.pump();
    expect(st.crosshairPos, isNot(center));
    await g.up();
    await t.pumpAndSettle();
    expect(st.crosshairMode, isTrue, reason: 'stays until toggled off');
    expect(t.takeException(), isNull);
  });

  testWidgets('right-edge margin allows ~5 bars past the newest', (t) async {
    final key = await pumpChart(t);
    final st = key.currentState!;
    st.debugSetView(visibleCount: 40, scroll: -4);
    await t.pumpAndSettle();
    expect(st.scrollCandles, -4);
    // Double-tap reset restores the pinned-newest view.
    st.debugSetView(visibleCount: null, scroll: 0);
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
  });
}
