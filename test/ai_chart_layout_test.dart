import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';

import 'candle_chart_test.dart' show loadFonts;

void main() {
  test('price-axis marker suppresses only intersecting tick text', () {
    expect(priceAxisLabelCollides(40, 10, 45, 14), true);
    expect(priceAxisLabelCollides(30, 10, 45, 14), false);
    expect(priceAxisLabelCollides(64, 10, 45, 14), false);
  });
  testWidgets(
    'offscreen drawing anchors and retained selection stay inside price pane',
    (t) async {
      await loadFonts();
      final data = List.generate(
        100,
        (i) => Candle(
          time: DateTime.utc(2026, 1, 1).add(Duration(minutes: i * 15)),
          open: 4100 + i.toDouble(),
          high: 4102 + i.toDouble(),
          low: 4098 + i.toDouble(),
          close: 4101 + i.toDouble(),
        ),
      );
      Future<List<int>> render({bool overlays = false}) async {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder)..translate(40, 40);
        CandlePainter(
          candles: data,
          firstVisible: 60,
          visibleCount: 40,
          selected: overlays ? 0 : null,
          trendLines: overlays
              ? [TrendLine(data[0].time, 4000, data[99].time, 4300)]
              : [],
          fibs: overlays
              ? [TrendLine(data[0].time, 4160, data[99].time, 4199)]
              : [],
          pendingFib: overlays
              ? TrendLine(data[0].time, 4150, data[0].time, 4150)
              : null,
          rsi: List.filled(86, 50),
          macdLine: List.filled(75, 1),
          macdSignal: List.filled(67, 1),
          macdHist: List.filled(67, 0),
        ).paint(canvas, const Size(320, 300));
        final im = await recorder.endRecording().toImage(400, 380);
        final b = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
        im.dispose();
        return b!.buffer.asUint8List();
      }

      await t.runAsync(() async {
        final base = await render(), drawn = await render(overlays: true);
        // Match actual painter pane geometry. Everything outside price plot,
        // including axis labels, legend margin and oscillator panes, is unchanged.
        final plotBottom = 40 + 300 - 16 - chartPaneHeight(300, true, true) * 2;
        int changedInside = 0;
        for (var y = 0; y < 380; y++) {
          for (var x = 0; x < 400; x++) {
            final k = (y * 400 + x) * 4;
            final changed = List.generate(
              4,
              (c) => base[k + c] != drawn[k + c],
            ).any((v) => v);
            if (x < 40 || x >= 308 || y < 40 || y >= plotBottom.ceil()) {
              expect(
                changed,
                false,
                reason: 'line escaped price pane at $x,$y',
              );
            } else if (changed) {
              changedInside++;
            }
          }
        }
        expect(changedInside, greaterThan(0));
      });
    },
  );
  testWidgets('screenshot matched range chart synthetic capture and styles', (
    t,
  ) async {
    await loadFonts();
    SharedPreferences.setMockInitialValues({});
    await t.binding.setSurfaceSize(const Size(360, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final data = List.generate(97, (i) {
      final o = 4155.65 + i * .26 + math.sin(i * .5) * 4;
      final c = o + math.sin(i * 1.8) * 3;
      return Candle(
        time: DateTime.utc(2026, 10, 18, 18, 30).add(Duration(minutes: 15 * i)),
        open: o,
        high: math.max(o, c) + 3,
        low: math.min(o, c) - 3,
        close: c,
      );
    });
    final image = GlobalKey();
    final state = GlobalKey<CandleChartPanelState>();
    await t.pumpWidget(
      RepaintBoundary(
        key: image,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: ThemeData.dark(),
          home: Scaffold(
            backgroundColor: const Color(0xff101522),
            body: SingleChildScrollView(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: [
                    const Text(
                      'SYNTHETIC · 1D / 15min',
                      style: TextStyle(fontSize: 12),
                    ),
                    const SizedBox(height: 12),
                    CandleChartPanel(
                      key: state,
                      rangeMode: true,
                      loader: (_) async => data,
                      onAlertPrice: (_) {},
                      livePrice: 4182.68,
                      initialLayout: const {
                        'rangeMode': true,
                        'interval': 'range:1D',
                        'visibleCount': 40,
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(state.currentState!.candles.length, 97);
    Future<void> capture(String name) async {
      const captureDir = String.fromEnvironment('SONA_CAPTURE_DIR');
      if (captureDir.isEmpty) return;
      await Directory(captureDir).create(recursive: true);
      await t.runAsync(() async {
        final im =
            await (image.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = await im.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '$captureDir/chart-${const String.fromEnvironment('STAGE', defaultValue: 'after')}-$name.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        im.dispose();
      });
    }

    await capture('candles');
    if (const bool.fromEnvironment('BASELINE')) {
      await t.pumpWidget(const SizedBox());
      return;
    }
    final draw = find.text('Draw');
    expect(draw.hitTestable(), findsOneWidget);
    final legend = find.textContaining('O ');
    final mode = find.text('Candle intervals');
    expect(t.getTopLeft(legend).dy - t.getBottomLeft(mode).dy, lessThan(16));
    for (final style in ChartStyle.values) {
      await t.tap(find.byTooltip('Chart style'));
      await t.pumpAndSettle();
      await t.tap(find.text(style.label).last);
      await t.pumpAndSettle();
      expect(state.currentState!.chartStyle, style);
      expect(t.takeException(), isNull);
      await capture(style.name);
    }
    for (final label in ['EMA 50', 'RSI 14', 'MACD 12/26/9']) {
      await t.tap(find.byTooltip('Indicators'));
      await t.pumpAndSettle();
      await t.ensureVisible(find.text(label));
      await t.pumpAndSettle();
      await t.tap(find.text(label));
      await t.pumpAndSettle();
    }
    expect(state.currentState!.emaOn, true);
    expect(state.currentState!.rsiOn, true);
    expect(state.currentState!.macdOn, true);
    await capture('indicators');
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox());
  });
}
