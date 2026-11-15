import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/market_data/twelve_data_candles.dart';

import 'zz_placeholder_fix_capture_test.dart' show loadFonts;

/// Phone-faithful harness: chromeless trade chart, quote STALE (the
/// weekend state: chartPrice is null, so the axis fits the candles
/// alone - exactly the user's screen).
Widget phoneHarness(List<Candle> data, double staleQuote) {
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
            chromeless: true,
            rangeMode: true,
            loader: (iv) async => data,
            livePrice: staleQuote,
            marketSnapshot: () => ChartMarketSnapshot(
              price: staleQuote,
              bid: staleQuote,
              ask: staleQuote + 0.67,
              fresh: false,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Visual proof for the SECOND weekend chart failure (user report
/// Nov 15 2026, ~09:54 IST / 04:24 UTC: the whole chart showed ONE huge
/// candle at 3,874.50 while the header quote sat at 3880.07, stale).
///
/// Data: the REAL Twelve Data XAU/USD 15-minute payload pulled live from
/// the user's own account on Nov 15 2026 ~04:26 UTC, preserved verbatim
/// in test/fixtures/xau_15m_nov13_15.json (200 bars, Fri Nov 13 02:30 UTC
/// - Sun Nov 15 04:15 UTC). The phone's 1D fetch is the last 120 bars
/// (Fri 22:30 UTC - Sun 04:15 UTC): all weekend placeholder bars.
///
/// Mechanism reproduced: the placeholder stream's frozen open STEPS by
/// 2.2 cents at Sat 04:15 UTC (3874.387 -> 3874.409), just over the old
/// 0.02 freeze tolerance, so the step bar survived the placeholder drop
/// alone - 119 dropped, 1 kept - and the chart auto-scaled that single
/// 0.23-USD bar into a full-screen candle.
///
/// Known fixture artifacts: the candle-close countdown under the price
/// pill counts from the fixture's last bar (Nov 2026 dates) and the
/// phone screenshot's extra drawn objects (the user's own rect zone and
/// lines at 3874.50) are not part of the candle data. Neither is part
/// of the fix.
///
/// No-op unless PLACEHOLDER_CAPTURE=1 (then run with --update-goldens).

List<Candle> phoneFetch() {
  final raw = jsonDecode(
      File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
  final values = (raw['values'] as List).cast<Map<String, dynamic>>();
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
  ]..sort((a, b) => a.time.compareTo(b.time));
  // The trade chart's 1D fetch: last 120 bars, exactly what the phone
  // received at 04:24 UTC on Nov 15.
  return out.sublist(out.length - 120);
}

void main() {
  final capture = Platform.environment['PLACEHOLDER_CAPTURE'] == '1';

  // The BEFORE state was captured with the pre-fix filter (0.02 chain):
  // exactly one bar - the Sat 04:15 UTC step bar O 3874.41 H 3874.60
  // L 3874.37 C 3874.50 - survived and rendered as one full-screen
  // candle, pixel-matching the user's phone screenshot. That golden
  // (goldens/weekend_single_before.png) is kept as the documented
  // reproduction; the fixed filter empties the same window, so the
  // render assertion below covers the regression at data level.
  test('BEFORE window now drops every placeholder bar', () {
    final filtered = dropClosedMarketPlaceholders(phoneFetch());
    expect(filtered, isEmpty);
  });


  testWidgets('AFTER: closed weekend fetch backfills the last real session',
      (tester) async {
    if (!capture) return;
    await loadFonts();
    final raw = jsonDecode(
        File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
    final values = (raw['values'] as List).cast<Map<String, dynamic>>()
      ..sort((a, b) =>
          (a['datetime'] as String).compareTo(b['datetime'] as String));
    final responses = <String>[
      jsonEncode(
          {'status': 'ok', 'values': values.sublist(values.length - 120)}),
      jsonEncode({'status': 'ok', 'values': values}),
    ];
    final svc = TwelveDataCandleService(
        apiKey: 'k',
        client: MockClient(
            (req) async => http.Response(responses.removeAt(0), 200)));
    // The real production path: service filter empties the 120-bar
    // weekend window, one widened refetch returns Friday's real session.
    final data = await svc.fetchCandles(Instrument.xauUsd,
        interval: '15min', limit: 120, backfillWhenClosed: true);
    expect(data.length, 81); // Friday session + transition bars, no placeholders
    await tester.pumpWidget(phoneHarness(data, 3880.07));
    await tester.pumpAndSettle();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/weekend_single_after.png'));
  });
}
