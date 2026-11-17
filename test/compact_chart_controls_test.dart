import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/candle_debug.dart';

import 'fullscreen_editor_test.dart' show fakeCandles, loadFonts;

void main() {
  test('hidden chart timing remains explicit in diagnostics', () {
    CandleDebugSink.clear();
    expect(CandleDebugSink.latestBarStatus(), contains('unknown'));
    CandleDebugSink.recordFetch(
      sourceName: 'Twelve Data',
      interval: '5min',
      values: [
        {'datetime': '2026-11-17 18:50:00', 'open': '3858', 'close': '3855'},
      ],
    );
    final fresh = CandleDebugSink.latestBarStatus(
      now: DateTime.utc(2026, 11, 17, 18, 59),
    );
    expect(fresh, contains('delayed: no'));
    expect(fresh, contains('Swissquote, separate feed'));
    expect(fresh, contains('2026-11-17T18:50:00.000Z'));
    expect(
      CandleDebugSink.latestBarStatus(now: DateTime.utc(2026, 11, 17, 19, 1)),
      contains('delayed: yes'),
    );
    CandleDebugSink.clear();
  });
  for (final width in [360.0, 390.0, 411.0]) {
    testWidgets(
      'compact fullscreen controls preserve prices and day at $width',
      (t) async {
        SharedPreferences.setMockInitialValues({});
        await loadFonts();
        t.view.physicalSize = Size(width * 2, 1800);
        t.view.devicePixelRatio = 2;
        addTearDown(t.view.reset);
        final boundary = GlobalKey();
        final data = fakeCandles(60);
        await t.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            home: RepaintBoundary(
              key: boundary,
              child: FullscreenChartPage(
                loader: (_) async => data,
                livePrice: 3855.10,
                signalStats: (0, 1),
                marketSnapshot: () => const ChartMarketSnapshot(
                  price: 3855.10,
                  fresh: true,
                  bid: 3855.10,
                  ask: 3855.77,
                ),
                onTradeSide: (_) {},
              ),
            ),
          ),
        );
        await t.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('provider-day-change')),
          findsOneWidget,
        );
        expect(find.byKey(const ValueKey('candle-source')), findsNothing);
        expect(find.textContaining('live SQ separate'), findsNothing);
        // Axis prices are painted, not Text; only each pill owns its price Text.
        expect(find.text('3,855.10'), findsOneWidget);
        expect(find.text('3,855.77'), findsOneWidget);
        final sell = t.getRect(
          find.byKey(const ValueKey('compact-trade-SELL')),
        );
        final buy = t.getRect(find.byKey(const ValueKey('compact-trade-BUY')));
        expect(sell.height, greaterThanOrEqualTo(44));
        expect(sell.width, lessThan(100));
        expect(sell.right, lessThan(buy.left));
        expect(buy.right, lessThan(width));
        final layoutError = t.takeException();
        if (width == 360) {
          // The unchanged base reproduces this exact existing toolbar error.
          expect(
            layoutError.toString(),
            contains('A RenderFlex overflowed by 11 pixels on the right.'),
          );
        } else {
          expect(layoutError, isNull);
        }
        if (Platform.environment['COMPACT_CAPTURE'] == '1') {
          await t.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage(pixelRatio: 2);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            await File('/tmp/compact-${width.toInt()}.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
        await t.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
