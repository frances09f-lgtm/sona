import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/market_data/twelve_data_candles.dart';

import 'zz_placeholder_fix_capture_test.dart' show loadFonts;

/// PREVIEW-ONLY capture for user approval (Nov 16): proposed gold signal
/// boxes on the real dark chart, sample zones and sample daily counts.
/// Candles are the REAL Twelve Data Friday session from
/// test/fixtures/xau_15m_nov13_15.json after the production placeholder
/// drop. No-op unless SIGNAL_PREVIEW=1 (then run with --update-goldens).
void main() {
  final capture = Platform.environment['SIGNAL_PREVIEW'] == '1';

  testWidgets('proposed signal boxes preview', (tester) async {
    if (!capture) return;
    await loadFonts();
    final raw = jsonDecode(
        File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
    final values = (raw['values'] as List).cast<Map<String, dynamic>>();
    final all = <Candle>[
      for (final v in values)
        Candle(
          time: DateTime.parse(
                  '${(v['datetime'] as String).replaceFirst(' ', 'T')}Z')
              .toLocal(),
          open: double.parse(v['open'] as String),
          high: double.parse(v['high'] as String),
          low: double.parse(v['low'] as String),
          close: double.parse(v['close'] as String),
        ),
    ]..sort((a, b) => a.time.compareTo(b.time));
    final data = dropClosedMarketPlaceholders(all);
    expect(data, isNotEmpty);
    final tail = data.sublist(data.length - 40);
    final hi = tail.map((c) => c.high).reduce(math.max);
    final lo = tail.map((c) => c.low).reduce(math.min);
    final last = data.last.close;
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
        home: Scaffold(
          backgroundColor: const Color(0xFF0F1115),
          body: Center(
            child: SizedBox(
              width: 390,
              height: 480,
              child: CandleChartPanel(
                chromeless: true,
                rangeMode: true,
                loader: (iv) async => data,
                livePrice: last,
                marketSnapshot: () => ChartMarketSnapshot(
                  price: last,
                  bid: last,
                  ask: last + 0.67,
                  fresh: true,
                ),
                signalZones: [
                  SignalZone(isBuy: false, low: hi - 1.0, high: hi + 2.0),
                  SignalZone(isBuy: true, low: lo - 2.0, high: lo + 1.0),
                ],
                signalStats: (3, 1), // SAMPLE counts for the preview
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/signal_preview.png'));
  });
}
