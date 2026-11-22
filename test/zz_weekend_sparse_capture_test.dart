import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/market_data/twelve_data_candles.dart';

/// FIXTURE regression for the Nov 22 2026 user report: the native chart
/// on a weekend showed 3 sparse REAL-RANGE candles (auto-scaled to full
/// height) instead of Friday's session, because Twelve Data now emits
/// sparse indicative weekend bars that no frozen signature can catch.
///
/// This is a FIXTURE test, never live Twelve Data end-to-end proof:
/// - Friday session bars: the verbatim provider pull from the user's
///   account (test/fixtures/xau_15m_nov13_15.json), actual session
///   timestamps retained.
/// - Sparse weekend bars: real clock timestamps (Sat Nov 14 2026
///   04:30/05:40/05:45 UTC, mirroring the user's 04:30/05:40/05:45 IST
///   screenshot labels), OHLC SYNTHESIZED to the observed sparse
///   real-range shape - no verbatim Nov 21-22 payload exists (CI has no
///   Twelve Data key; the key lives in the user's on-device settings).
///
/// BEFORE: the raw weekend window - 3 candles, one blown to full height.
/// AFTER: the same window through dropClosedMarketPlaceholders - the
/// synthetic bars drop by clock and Friday's real session remains.
///
/// Known fixture artifact: the candle-close countdown under the price
/// pill counts from the fixture's last bar (Nov 2026 dates), so it
/// shows a large value in BOTH captures; it is not part of the fix.
/// No-op unless WEEKEND_SPARSE_CAPTURE=1 (then run with
/// --update-goldens; goldens land in test/goldens/weekend_sparse_*.png).

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

/// Friday Nov 13 2026 session bars from the verbatim pull (real
/// timestamps), oldest-first, plus the 3 synthesized sparse weekend
/// bars at their real clock times.
List<Candle> weekendFetch() {
  final raw = jsonDecode(
      File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
  final values = (raw['values'] as List).cast<Map<String, dynamic>>();
  final cutoff = DateTime.utc(2026, 11, 13, 22, 0); // Friday close
  final out = <Candle>[
    for (final v in values)
      Candle(
        time: DateTime.parse(
            '${(v['datetime'] as String).replaceFirst(' ', 'T')}Z').toLocal(),
        open: double.parse(v['open'] as String),
        high: double.parse(v['high'] as String),
        low: double.parse(v['low'] as String),
        close: double.parse(v['close'] as String),
      ),
  ]
    ..sort((a, b) => a.time.compareTo(b.time))
    ..removeWhere((c) => !c.time.toUtc().isBefore(cutoff));
  // Synthesized sparse indicative weekend bars (shape from the user's
  // Nov 22 screenshots; clock times real). Prices near that weekend's
  // 3533-3539 indicative ticks.
  final base = out.last.close;
  for (final spec in [
    [DateTime.utc(2026, 11, 14, 4, 30), 0.10, 0.60, -0.20, 0.40],
    [DateTime.utc(2026, 11, 14, 5, 40), -1.90, 1.30, -3.30, 1.00],
    [DateTime.utc(2026, 11, 14, 5, 45), 0.95, 1.20, -0.20, 1.10],
  ]) {
    final t = spec[0] as DateTime;
    out.add(Candle(
      time: t.toLocal(),
      open: base + (spec[1] as double),
      high: base + (spec[2] as double),
      low: base + (spec[3] as double),
      close: base + (spec[4] as double),
    ));
  }
  return out;
}

Widget harness(List<Candle> data, double quote) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
    home: Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: Center(
        child: SizedBox(
          width: 390,
          height: 480,
          child: CandleChartPanel(
            loader: (iv) async => data,
            livePrice: quote,
            marketSnapshot: () => ChartMarketSnapshot(
              price: quote,
              bid: quote,
              ask: quote + 0.67,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final capture = Platform.environment['WEEKEND_SPARSE_CAPTURE'] == '1';

  testWidgets('BEFORE: raw weekend window renders 3 sparse candles '
      '(the Nov 22 user screen, fixture)', (tester) async {
    if (!capture) return;
    await loadFonts();
    final fetch = weekendFetch();
    // The phone's raw window: only the sparse synthetic weekend bars.
    final window = fetch.sublist(fetch.length - 3);
    expect(window.length, 3);
    for (final c in window) {
      expect(c.time.toUtc().weekday, DateTime.saturday);
    }
    await tester.pumpWidget(harness(window, fetch[fetch.length - 4].close));
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/weekend_sparse_before.png'));
  });

  testWidgets('AFTER: clock filter drops the sparse synthetic bars; '
      "Friday's real session remains (fixture)", (tester) async {
    if (!capture) return;
    await loadFonts();
    final fetch = weekendFetch();
    final filtered = dropClosedMarketPlaceholders(fetch);
    expect(filtered.length, fetch.length - 3);
    expect(filtered.length, greaterThan(50));
    for (final c in filtered) {
      expect(c.time.toUtc().weekday, DateTime.friday);
    }
    final window = filtered.sublist(math.max(0, filtered.length - 100));
    await tester.pumpWidget(harness(window, filtered.last.close));
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/weekend_sparse_after.png'));
  });
}
