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

/// Visual proof for the closed-market placeholder fix (user report
/// Nov 15 2026: main gold chart full of full-height slivers, axis
/// 3874.35-3874.60, while the header quote sat ~5.6 USD away).
///
/// Data: the REAL Twelve Data XAU/USD 15-minute payload pulled from the
/// user's own account over Oct 30 - Nov 2 2026
/// (test/fixtures/xau_15m_real.json, market OHLC only). It contains a
/// 182-bar frozen placeholder run (Oct 30 22:15 UTC - Nov 1 19:30 UTC),
/// the same provider behavior the user's Nov 14 screenshot showed. The
/// captures slice the payload as of Sunday Nov 1 12:00 UTC, mid-run -
/// the situation the user hit (a weekend window with nothing but
/// placeholders in it) - so this is a real-payload reproduction
/// of the symptom class, not a re-creation of his exact screen.
///
/// BEFORE: the chart gets the raw tail - only placeholders are in view,
/// auto-scale blows their ~0.2 USD ranges up to full-height slivers.
/// AFTER: the same fetch through [dropClosedMarketPlaceholders] - the
/// window backfills with Friday's real bars.
///
/// Known fixture artifact: the candle-close countdown under the price
/// pill counts from the fixture's last bar (Nov 2026 dates), so it shows
/// a large value in BOTH captures; it is not part of the fix.
/// No-op unless PLACEHOLDER_CAPTURE=1 (then run with --update-goldens).

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

/// The payload as a mid-weekend fetch would have returned it:
/// every bar up to Oct 31 12:00 UTC, oldest-first.
List<Candle> saturdayFetch() {
  final raw = jsonDecode(
      File('test/fixtures/xau_15m_real.json').readAsStringSync());
  final values = (raw['values'] as List).cast<Map<String, dynamic>>();
  final cutoff = DateTime.utc(2026, 11, 1, 12, 0);
  final out = <Candle>[
    for (final v in values)
      Candle(
        // Parse like the service does: naive UTC, then device-local.
        time: DateTime.parse(
            '${(v['datetime'] as String).replaceFirst(' ', 'T')}Z').toLocal(),
        open: double.parse(v['open'] as String),
        high: double.parse(v['high'] as String),
        low: double.parse(v['low'] as String),
        close: double.parse(v['close'] as String),
      ),
  ]
    ..sort((a, b) => a.time.compareTo(b.time))
    ..removeWhere((c) => c.time.isAfter(cutoff));
  return out;
}

/// Friday's real close inside this payload (last non-frozen bar before
/// the cutoff): what the stale quote row would show.
double fridayClose(List<Candle> fetch) {
  for (var i = fetch.length - 1; i > 0; i--) {
    if ((fetch[i].open - fetch[i - 1].open).abs() > 0.02 ||
        (fetch[i].high - fetch[i].low) > 1.0) {
      return fetch[i].close;
    }
  }
  return fetch.last.close;
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
  final capture = Platform.environment['PLACEHOLDER_CAPTURE'] == '1';

  testWidgets('BEFORE: weekend window is all placeholders -> slivers',
      (tester) async {
    if (!capture) return;
    await loadFonts();
    final fetch = saturdayFetch();
    final window = fetch.sublist(math.max(0, fetch.length - 100));
    expect(window.length, 100);
    // The user's state: the visible window is nothing but placeholders.
    final frozen = window
        .where((c) => (c.high - c.low) <= 1.0)
        .length;
    expect(frozen, greaterThan(95));
    await tester.pumpWidget(harness(window, fridayClose(fetch)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/placeholder_before.png'));
  });

  testWidgets('AFTER: filtered fetch backfills Friday real bars',
      (tester) async {
    if (!capture) return;
    await loadFonts();
    final fetch = saturdayFetch();
    final filtered = dropClosedMarketPlaceholders(fetch);
    expect(filtered.length, lessThan(fetch.length) /* placeholders gone */);
    expect(filtered.length, greaterThan(50) /* real bars survive */);
    // Every dropped bar sat inside a closure; none were weekday bars.
    final window = filtered.sublist(math.max(0, filtered.length - 100));
    await tester.pumpWidget(harness(window, fridayClose(fetch)));
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/placeholder_after.png'));
  });
}
