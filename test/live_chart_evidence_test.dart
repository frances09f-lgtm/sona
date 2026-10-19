import 'dart:convert';
import 'dart:io';

import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';

import 'candle_chart_test.dart' show loadFonts;
import 'chart_upgrade_test.dart' show painter;

/// LIVE evidence test (skipped in CI; run with LIVE_EVIDENCE=1).
///
/// Polls the REAL Swissquote feed for ~2 minutes while the chart runs on a
/// lagging provider-like candle series - the exact production condition -
/// and proves at every sample that the last drawn candle's close == the
/// live line price == the price tag, across ticks, a timeframe switch and
/// a simulated app resume. Screenshots are saved to /tmp.
void main() {
  testWidgets(
    'LIVE: line, tag and forming candle agree across ticks, range switch and resume',
    (t) async {
      Future<double?> realBid() async {
        try {
          final r = await http
              .get(
                Uri.parse(
                  'https://forex-data-feed.swissquote.com/public-quotes/bboquotes/instrument/XAU/USD',
                ),
              )
              .timeout(const Duration(seconds: 5));
          final d = jsonDecode(r.body) as List;
          return (d[0]['spreadProfilePrices'][0]['bid'] as num).toDouble();
        } catch (_) {
          return null;
        }
      }

      await t.runAsync(() async {
        HttpOverrides.global = null; // flutter_test blocks real sockets
        final first = await realBid();
        if (first == null) {
          // ignore: avoid_print
          print('LIVE_EVIDENCE no network - skipped');
          return;
        }
        SharedPreferences.setMockInitialValues({});
        await loadFonts();
        final buf = TickBuffer();
        double live = first;

        // Provider-like history: real-price 1m bars ending 3 min ago,
        // mimicking TwelveData's free-tier lag. The loader rebuilds it on
        // every call (production refetches on each refresh/switch).
        List<Candle> seriesFor(String iv) {
          final spec = tradeRangeSpec(iv);
          final barSecs = spec.$1 == '1min' ? 60 : 900;
          final now = DateTime.now();
          final end = now.subtract(const Duration(minutes: 3));
          return List.generate(40, (i) {
            final start = end.subtract(Duration(seconds: barSecs * (40 - i)));
            final wob = (i % 5 - 2) * 0.06;
            final o = live - 0.5 + wob;
            final c = live - 0.4 + wob;
            return Candle(
              time: start,
              open: o,
              high: (o > c ? o : c) + 0.3,
              low: (o < c ? o : c) - 0.3,
              close: c,
              volume: 1,
            );
          });
        }

        final key = GlobalKey();
        final pulse = ValueNotifier<int>(0);
        await t.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: RepaintBoundary(
                key: key,
                child: AnimatedBuilder(
                  animation: pulse,
                  builder: (_, __) => CandleChartPanel(
                  rangeMode: true,
                  loader: (iv) async => seriesFor(iv),
                  marketSnapshot: () {
                    return ChartMarketSnapshot(
                      price: live,
                      fresh: true,
                      liveTicks: buf.ticks,
                    );
                  },
                    livePrice: live,
                  ),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        // Start on the 1H view like the user.
        await t.tap(find.text('1H').first);
        await t.pump();

        final log = <String>[];
        Future<void> sample(String label, {bool shot = false}) async {
          await t.pump();
          final p = painter(t);
          final last = p.candles.last;
          final st = t.state<CandleChartPanelState>(find.byType(CandleChartPanel));
          // ignore: avoid_print
          print('DBG iv=' + st.interval.code + ' stateN=' + st.candles.length.toString() + ' painterN=' + p.candles.length.toString() + ' ticks=' + buf.ticks.length.toString() + ' lastProv=' + (st.candles.isEmpty ? '-' : st.candles.last.time.toIso8601String().substring(11, 19)));
          final ok = last.close == live && p.livePrice == live;
          final visible = p.firstVisible + p.visibleCount >= p.candles.length;
          // ignore: avoid_print
          print(
            'LIVE_EVIDENCE $label t=${DateTime.now().toIso8601String().substring(11, 19)} '
            'line=${p.livePrice} lastClose=${last.close} lastBar=${last.time.toIso8601String().substring(11, 19)} '
            'visible=$visible match=$ok',
          );
          expect(ok, true, reason: '$label: line != last candle close');
          expect(visible, true, reason: '$label: forming bar clipped');
          if (shot) {
            final img = await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
            final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
            await File('/tmp/sona-chart-live-evidence-$label.png')
                .writeAsBytes(bytes!.buffer.asUint8List());
            img.dispose();
          }
        }

        // Poll the real feed every second for ~100s; sample every ~25s.
        for (var i = 0; i < 35; i++) {
          await Future<void>.delayed(const Duration(seconds: 1));
          final b = await realBid();
          if (b != null) {
            live = b;
            buf.add(DateTime.now(), b);
            pulse.value++; // production: notifyListeners() rebuilds the chart
          }
          if (i == 8) await sample('tick8', shot: true);
          if (i == 20) await sample('tick20', shot: true);
          if (i == 32) await sample('tick32', shot: true);
        }
        // Timeframe switch 1H -> 1D -> 1H via the real chips.
        await t.tap(find.text('1D').first);
        await t.pump();
        await Future<void>.delayed(const Duration(seconds: 3));
        await sample('range1D', shot: true);
        await t.tap(find.text('1H').first);
        await t.pump();
        await Future<void>.delayed(const Duration(seconds: 3));
        final b1 = await realBid();
        if (b1 != null) {
          live = b1;
          buf.add(DateTime.now(), b1);
          pulse.value++;
        }
        await sample('back1H', shot: true);
        // Simulated app resume: 20s with no polling, then next tick must
        // re-sync line and candle immediately.
        await Future<void>.delayed(const Duration(seconds: 12));
        final b2 = await realBid();
        if (b2 != null) {
          live = b2;
          buf.add(DateTime.now(), b2);
          pulse.value++;
        }
        await sample('resume', shot: true);
        // ignore: avoid_print
        log.forEach(print);
        await t.pumpWidget(const SizedBox());
      });
    },
    skip: Platform.environment['LIVE_EVIDENCE'] != '1',
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
