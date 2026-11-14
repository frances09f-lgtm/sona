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
/// Nov 15 2026: main gold chart shows full-height slivers, axis
/// 3874.35-3874.60, while the header quote sits ~5.6 USD away).
///
/// The payload mirrors the live Twelve Data XAU/USD 15m feed observed on
/// Nov 14-15 2026: real Friday bars with 20-36 USD ranges through
/// 22:00 UTC, then ~90 synthetic bars with the open frozen at
/// 3874.43 and ~0.23 USD ranges through the weekend.
///
/// BEFORE: the chart gets the raw payload - every placeholder auto-scales
/// to a sliver. AFTER: the same payload through
/// [dropClosedMarketPlaceholders] - only real bars render.
/// No-op unless PLACEHOLDER_CAPTURE=1 (then run with --update-goldens).

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

List<Candle> weekendPayload() {
  final rnd = math.Random(11);
  double px = 3852.0;
  final out = <Candle>[];
  // Real Friday session: 60 bars ending 2026-11-13 22:00 UTC.
  final start = DateTime.utc(2026, 11, 13, 7, 0);
  for (var i = 0; i < 60; i++) {
    final o = px;
    final c = o + (rnd.nextDouble() - 0.48) * 14;
    final h = math.max(o, c) + rnd.nextDouble() * 8 + 6;
    final l = math.min(o, c) - rnd.nextDouble() * 8 - 6;
    px = c;
    out.add(Candle(
      time: start.add(Duration(minutes: 15 * i)),
      open: o, high: h, low: l, close: c,
    ));
  }
  px = 3874.43; // where the real feed actually froze
  out.last = Candle(
    time: out.last.time, open: 3878.27, high: 3878.27, low: 3874.41,
    close: 3874.84,
  );
  // Synthetic closed-market placeholders: frozen open, ~0.23 USD range.
  var t = DateTime.utc(2026, 11, 13, 22, 15);
  for (var i = 0; i < 90; i++) {
    out.add(Candle(
      time: t,
      open: px,
      high: px + 0.18,
      low: px - 0.05,
      close: px + 0.04,
    ));
    t = t.add(const Duration(minutes: 15));
  }
  return out;
}

Widget harness(List<Candle> data) {
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
            livePrice: 3880.07, // Friday's real close, as in the report
            marketSnapshot: () => ChartMarketSnapshot(
              price: 3880.07,
              bid: 3880.07,
              ask: 3880.74,
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  final capture = Platform.environment['PLACEHOLDER_CAPTURE'] == '1';

  testWidgets('BEFORE: frozen weekend bars render as slivers', (tester) async {
    if (!capture) return;
    await loadFonts();
    final raw = weekendPayload();
    expect(raw.length, 150);
    await tester.pumpWidget(harness(raw));
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/placeholder_before.png'));
  });

  testWidgets('AFTER: filter leaves a clean real-market chart', (tester) async {
    if (!capture) return;
    await loadFonts();
    final filtered = dropClosedMarketPlaceholders(weekendPayload());
    expect(filtered.length, lessThan(65));
    await tester.pumpWidget(harness(filtered));
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/placeholder_after.png'));
  });
}
