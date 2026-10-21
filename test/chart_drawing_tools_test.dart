import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/market_data/models.dart';

import 'candle_chart_test.dart' show fakeCandles, loadFonts;

Future<GlobalKey<CandleChartPanelState>> pumpChart(
    WidgetTester t, List<Candle> data) async {
  await loadFonts();
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
  testWidgets('Rect mode: two taps place a rectangle', (t) async {
    SharedPreferences.setMockInitialValues({});
    final data = fakeCandles(120);
    final key = await pumpChart(t, data);
    final st = key.currentState!;
    await t.scrollUntilVisible(find.text('Rect'), 60,
        scrollable: find.byType(Scrollable).first);
    await t.tap(find.text('Rect'));
    await t.pumpAndSettle();
    expect(st.rectMode, isTrue);
    final rect = t.getRect(find.byType(CandleChartPanel));
    await t.tapAt(Offset(rect.left + 80, rect.top + 150));
    await t.pumpAndSettle();
    expect(st.pendingRect, isNotNull);
    await t.tapAt(Offset(rect.left + 220, rect.top + 260));
    await t.pumpAndSettle();
    expect(st.rects.length, 1);
    expect(st.pendingRect, isNull);
    expect(t.takeException(), isNull);
  });

  testWidgets('Ruler mode: two taps place a measurement', (t) async {
    SharedPreferences.setMockInitialValues({});
    final data = fakeCandles(120);
    final key = await pumpChart(t, data);
    final st = key.currentState!;
    st.rulerMode = true;
    await t.pumpAndSettle();
    final rect = t.getRect(find.byType(CandleChartPanel));
    await t.tapAt(Offset(rect.left + 60, rect.top + 200));
    await t.pumpAndSettle();
    await t.tapAt(Offset(rect.left + 200, rect.top + 120));
    await t.pumpAndSettle();
    expect(st.rulers.length, 1);
    expect(t.takeException(), isNull);
  });

  testWidgets('Channel mode: three taps place a channel', (t) async {
    SharedPreferences.setMockInitialValues({});
    final data = fakeCandles(120);
    final key = await pumpChart(t, data);
    final st = key.currentState!;
    st.channelMode = true;
    await t.pumpAndSettle();
    final rect = t.getRect(find.byType(CandleChartPanel));
    await t.tapAt(Offset(rect.left + 60, rect.top + 180));
    await t.pumpAndSettle();
    expect(st.channelStage, 1);
    await t.tapAt(Offset(rect.left + 220, rect.top + 90));
    await t.pumpAndSettle();
    expect(st.channelStage, 2);
    await t.tapAt(Offset(rect.left + 140, rect.top + 260));
    await t.pumpAndSettle();
    // ignore: avoid_print
    print('CHAN stage=${st.channelStage} pending=${st.pendingChannel} saved=${st.channels.length}');
    expect(st.channels.length, 1);
    expect(st.channels.single.dp, isNot(0));
    expect(t.takeException(), isNull);
  });

  testWidgets('magnet snaps anchors to candle high/low, toggle disables',
      (t) async {
    SharedPreferences.setMockInitialValues({});
    final data = fakeCandles(120);
    final key = await pumpChart(t, data);
    final st = key.currentState!;
    st.debugSetView(visibleCount: 40, scroll: 0);
    await t.pumpAndSettle();
    expect(st.magnetOn, isTrue);
    // Anchor near (within 2.5% of range) a candle high snaps exactly.
    final i = data.length - 10;
    final c = data[i];
    final snapped = st.debugSnapForTest(c.high - 0.4, i);
    expect(snapped, c.high);
    // Magnet off: no snap.
    st.magnetOn = false;
    await t.pumpAndSettle();
    expect(st.magnetOn, isFalse);
    final raw = st.debugSnapForTest(c.high - 0.4, i);
    expect(raw, c.high - 0.4);
    expect(t.takeException(), isNull);
  });

  testWidgets('drawing tools render (golden)', (t) async {
    await loadFonts();
    final base = DateTime.utc(2026, 10, 21);
    double px = 4120;
    final candles = List.generate(96, (i) {
      final o = px;
      final cl = o + ((i % 7) - 3) * 1.3;
      px = cl;
      return Candle(
        time: base.add(Duration(minutes: 15 * i)),
        open: o,
        high: o + 2.5 + (i % 3),
        low: o - 2.5 - (i % 2),
        close: cl,
      );
    });
    final painter = CandlePainter(
      candles: candles,
      rects: [
        TrendLine(
          base.add(const Duration(hours: 4)), 4126,
          base.add(const Duration(hours: 10)), 4116,
        ),
      ],
      channels: [
        Channel(
          base.add(const Duration(hours: 2)), 4112,
          base.add(const Duration(hours: 18)), 4126,
          6,
        ),
      ],
      rulers: [
        TrendLine(
          base.add(const Duration(hours: 12)), 4110,
          base.add(const Duration(hours: 20)), 4130,
        ),
      ],
    );
    await t.pumpWidget(
      RepaintBoundary(
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFF0F1115),
            body: Center(
              child: SizedBox(
                width: 380,
                height: 300,
                child:
                    CustomPaint(size: const Size(380, 300), painter: painter),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await expectLater(
      find.byType(CustomPaint).last,
      matchesGoldenFile('goldens/chart_drawing_tools.png'),
    );
    expect(t.takeException(), isNull);
  });
}
