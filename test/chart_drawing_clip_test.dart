import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/main.dart';
import 'package:sona/chart/candle_chart.dart';

import 'fullscreen_live_fix_test.dart' show barsFor;
import 'screens_test.dart' show demoState, loadFonts;

void main() {
  testWidgets(
    'steep drawing tools stay inside price plot, including pending anchors',
    (t) async {
      await loadFonts();
      final bars = barsFor('5min');
      final steep = TrendLine(bars[90].time, 3880, bars[91].time, 3910);
      Future<ui.Image> render(bool drawings) async {
        final rec = ui.PictureRecorder();
        final c = Canvas(rec);
        c.drawColor(const Color(0xFF172030), BlendMode.src);
        c.translate(30, 100);
        CandlePainter(
          candles: bars,
          trendLines: drawings ? [steep] : [],
          rects: drawings
              ? [TrendLine(bars[20].time, 3800, bars[110].time, 4000)]
              : [],
          channels: drawings
              ? [Channel(steep.t1, steep.p1, steep.t2, steep.p2, 10)]
              : [],
          pendingTrend: drawings
              ? TrendLine(bars[20].time, 4000, bars[20].time, 4000)
              : null,
          pendingRect: drawings ? steep : null,
          pendingChannel: drawings
              ? Channel(steep.t1, steep.p1, steep.t2, steep.p2, -10)
              : null,
          pendingFib: drawings
              ? TrendLine(bars[20].time, 4000, bars[20].time, 4000)
              : null,
        ).paint(c, const Size(360, 440));
        final pic = rec.endRecording();
        final image = await pic.toImage(420, 640);
        pic.dispose();
        return image;
      }

      await t.runAsync(() async {
        final plain = await render(false), drawn = await render(true);
        final a = (await plain.toByteData())!.buffer.asUint8List();
        final b = (await drawn.toByteData())!.buffer.asUint8List();
        var escaped = 0, inside = 0;
        for (var y = 0; y < 640; y++) {
          for (var x = 0; x < 420; x++) {
            final i = (y * 420 + x) * 4;
            if (a[i] != b[i] ||
                a[i + 1] != b[i + 1] ||
                a[i + 2] != b[i + 2] ||
                a[i + 3] != b[i + 3]) {
              if (x >= 30 && x < 338 && y >= 100 && y < 524) {
                inside++;
              } else {
                escaped++;
              }
            }
          }
        }
        plain.dispose();
        drawn.dispose();
        expect(inside, greaterThan(100));
        expect(
          escaped,
          0,
          reason: 'Drawing pixels must not touch header, axis, time labels or footer',
        );
      });
    },
  );

  testWidgets(
    'actual embedded TradeTab retains clipped drawing across all phone timeframes',
    (t) async {
      SharedPreferences.setMockInitialValues(
      {'trade_chart_mode_v1': 'sona'});
      await loadFonts();
      t.view.physicalSize = const Size(1080, 2400);
      t.view.devicePixelRatio = 2.625;
      addTearDown(t.view.reset);
      final app = demoState()
        ..price = 3861.87
        ..bid = 3861.87
        ..ask = 3862.53
        ..priceOk = true
        ..priceAt = DateTime.now().millisecondsSinceEpoch;
      final boundary = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            home: Scaffold(
              appBar: AppBar(title: const Text('Sona')),
              body: TradeTab(
                app: app,
                candleLoaderOverride: (iv) async => barsFor(iv),
              ),
              bottomNavigationBar: BottomNavigationBar(
                currentIndex: 0,
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.show_chart),
                    label: 'Trade',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.work_outline),
                    label: 'Portfolio',
                  ),
                  BottomNavigationBarItem(icon: Icon(Icons.add), label: 'Add'),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final st = t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
      st.applyChartSelection(range: false, code: '5min');
      await t.pumpAndSettle();
      final data = st.candles;
      st.trendLines.add(TrendLine(data[90].time, 3880, data[91].time, 3910));
      st.rects.add(TrendLine(data[80].time, 3880, data[95].time, 3890));
      st.debugSetView(visibleCount: 60, scroll: 0);
      await t.pumpAndSettle();
      for (final code in ['5min', '1min', '1h', '4h', '1day']) {
        st.applyChartSelection(range: false, code: code);
        await t.pumpAndSettle();
        expect(st.trendLines.length, 1);
        expect(st.rects.length, 1);
        expect(t.takeException(), isNull);
        if (Platform.environment['DRAWING_CAPTURE'] == '1') {
          await t.runAsync(() async {
            final img =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 2.625);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            final dir = Platform.environment['DRAWING_CAPTURE_DIR'] ?? '/tmp';
            await File('$dir/trade-drawing-$code.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            img.dispose();
          });
        }
      }
      await t.pumpWidget(const SizedBox.shrink());
    },
  );
}
