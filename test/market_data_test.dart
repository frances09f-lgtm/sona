import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/market_data/swissquote_provider.dart';
import 'package:sona/market_data/twelve_data_candles.dart';
import 'package:sona/market_data/realtime_price_stream.dart';

const swissquoteFixture = '''
[{"topo":{"platform":"SwissquoteCapitalMarkets","server":"Live7"},
  "spreadProfilePrices":[
    {"spreadProfile":"premium","bidSpread":25.40,"askSpread":25.40,"bid":4160.696,"ask":4161.354},
    {"spreadProfile":"prime","bidSpread":24.40,"askSpread":24.40,"bid":4160.706,"ask":4161.344}],
  "ts":1791304088743},
 {"topo":{"platform":"AT","server":"AT"},
  "spreadProfilePrices":[
    {"spreadProfile":"standard","bidSpread":27.00,"askSpread":27.00,"bid":4160.500,"ask":4161.400}],
  "ts":1791304088000}]''';

const twelveDataFixture = '''
{"meta":{"symbol":"XAU/USD","interval":"15min","currency_base":"Gold Spot"},
 "values":[
  {"datetime":"2026-10-06 14:30:00","open":"4161.10","high":"4162.40","low":"4160.80","close":"4162.10"},
  {"datetime":"2026-10-06 14:15:00","open":"4160.20","high":"4161.30","low":"4159.90","close":"4161.00"}],
 "status":"ok"}''';

http.Client fakeClient(int statusCode, String body) => MockClient((req) async {
      return http.Response(body, statusCode,
          headers: {'content-type': 'application/json'});
    });

void main() {
  group('SwissquoteQuoteProvider', () {
    test('parses real bid/ask from the freshest platform entry', () async {
      final p = SwissquoteQuoteProvider(
          client: fakeClient(200, swissquoteFixture));
      final q = await p.fetchQuote(Instrument.xauUsd);
      expect(q.instrument, 'XAU/USD');
      expect(q.bid, 4160.696);
      expect(q.ask, 4161.354);
      expect(q.spread, closeTo(0.658, 0.001));
      expect(q.mid, closeTo(4161.025, 0.001));
      expect(q.ts.millisecondsSinceEpoch, 1791304088743);
      expect(q.source, 'swissquote');
    });

    test('throws on HTTP error - no fabricated price', () {
      final p = SwissquoteQuoteProvider(client: fakeClient(500, '{}'));
      expect(() => p.fetchQuote(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });

    test('throws on empty payload', () {
      final p = SwissquoteQuoteProvider(client: fakeClient(200, '[]'));
      expect(() => p.fetchQuote(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });

    test('throws on malformed quote (zero prices)', () {
      const bad =
          '[{"spreadProfilePrices":[{"bid":0,"ask":0}],"ts":1791304088743}]';
      final p = SwissquoteQuoteProvider(client: fakeClient(200, bad));
      expect(() => p.fetchQuote(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });
  });

  group('TwelveDataCandleService', () {
    test('parses OHLC candles oldest-first', () async {
      final s = TwelveDataCandleService(
          apiKey: 'testkey', client: fakeClient(200, twelveDataFixture));
      final candles =
          await s.fetchCandles(Instrument.xauUsd, interval: '15min');
      expect(candles.length, 2);
      expect(
        candles.first.time.millisecondsSinceEpoch,
        DateTime.utc(2026, 10, 6, 14, 15).millisecondsSinceEpoch,
      );
      expect(candles.first.time.isUtc, false); // converted to device-local
      expect(candles.first.close, 4161.00);
      expect(candles.last.close, 4162.10);
    });

    test('requests UTC timezone and parses datetimes as UTC instants', () async {
      Uri? seen;
      final client = MockClient((req) async {
        seen = req.url;
        return http.Response(twelveDataFixture, 200,
            headers: {'content-type': 'application/json'});
      });
      final svc = TwelveDataCandleService(apiKey: 'k', client: client);
      final candles =
          await svc.fetchCandles(Instrument.xauUsd, interval: '1min');
      expect(seen!.queryParameters['timezone'], 'UTC');
      // Naive "2026-10-06 14:30:00" is read as 14:30 UTC, not device-local.
      expect(candles.last.time.toUtc(), DateTime.utc(2026, 10, 6, 14, 30));
    });

    test('refuses to call without an API key', () {
      final s = TwelveDataCandleService(apiKey: '', client: fakeClient(200, '{}'));
      expect(() => s.fetchCandles(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });

    test('surfaces provider error responses', () {
      final s = TwelveDataCandleService(
          apiKey: 'k',
          client: fakeClient(
              200, '{"status":"error","message":"invalid symbol"}'));
      expect(() => s.fetchCandles(Instrument.xauUsd),
          throwsA(isA<MarketDataException>()));
    });

    test('drops the frozen closed-market placeholder run, keeps real bars',
        () async {
      // Shape verified against the live feed on Nov 14-15, 2026: real
      // Friday bars (multi-dollar ranges), then from Friday 22:15 UTC a
      // run of synthetic bars with frozen opens and ~0.2 USD ranges.
      final buf = StringBuffer('{"status":"ok","values":[');
      String bar(String dt, double o, double h, double l, double c) =>
          '{"datetime":"$dt","open":"$o","high":"$h","low":"$l",'
          '"close":"$c","volume":"0"}';
      final bars = <String>[
        bar('2026-11-13 21:45:00', 3874.14, 3882.14, 3874.14, 3878.58),
        bar('2026-11-13 22:00:00', 3878.27, 3878.27, 3874.41, 3874.84),
        // transition bar where the feed freezes mid-step: survives.
        bar('2026-11-13 22:15:00', 3875.18, 3875.18, 3874.38, 3874.50),
      ];
      for (var i = 0; i < 20; i++) {
        final t = DateTime.utc(2026, 11, 13, 22, 30).add(
            Duration(minutes: 15 * i));
        final dt =
            '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
            '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';
        bars.add(bar(dt, 3874.4327, 3874.61, 3874.38, 3874.47));
      }
      // Real reopening bar on Sunday evening: must survive.
      bars.add(bar('2026-11-08 22:30:00', 4067.25, 4068.50, 4066.64, 4066.85)
          .replaceFirst('2026-11-08', '2026-11-15'));
      buf.writeAll(bars.reversed, ','); // API returns newest-first
      buf.write(']}');
      final s = TwelveDataCandleService(
          apiKey: 'k', client: fakeClient(200, buf.toString()));
      final candles =
          await s.fetchCandles(Instrument.xauUsd, interval: '15min');
      // Time-based filter (Nov 22 revision): only the Friday 21:45 UTC
      // bar (last bar before the 22:00 UTC close) and the real Sunday
      // reopening bar survive. The 22:00/22:15 Friday bars and every
      // frozen bar sit inside the confirmed-closed window and drop by
      // clock, whatever their shape.
      expect(candles.length, 2);
      expect(candles.first.time.toUtc(), DateTime.utc(2026, 11, 13, 21, 45));
      expect(candles.last.time.toUtc(), DateTime.utc(2026, 11, 15, 22, 30));
    });

    test('live payload: the phone\'s exact Nov 15 weekend fetch drops '
        'EVERY placeholder bar - including the 2.2-cent step bar that '
        'survived as one full-screen candle (user report Nov 15 2026)',
        () async {
      // test/fixtures/xau_15m_nov13_15.json is the verbatim Twelve Data
      // pull from the user's account (Nov 15 2026 04:26 UTC). The trade
      // chart's 1D fetch = the last 120 bars (Fri 22:30 UTC - Sun 04:15
      // UTC). The placeholder stream's frozen open steps 0.022 USD at
      // Sat 04:15 UTC; the old 0.02 chain left that one bar alive.
      final raw = jsonDecode(
          File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
      final values = (raw['values'] as List).cast<Map<String, dynamic>>()
        ..sort((a, b) =>
            (a['datetime'] as String).compareTo(b['datetime'] as String));
      final phoneWindow =
          values.sublist(values.length - 120).reversed.toList(); // API order
      final s = TwelveDataCandleService(
          apiKey: 'k',
          client: fakeClient(
              200, jsonEncode({'status': 'ok', 'values': phoneWindow})));
      await expectLater(
          s.fetchCandles(Instrument.xauUsd, interval: '15min', limit: 120),
          throwsA(isA<MarketDataException>()));
    });

    test('live payload: backfillWhenClosed widens once and returns the '
        'last real session instead of a blank weekend chart', () async {
      final raw = jsonDecode(
          File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
      final values = (raw['values'] as List).cast<Map<String, dynamic>>()
        ..sort((a, b) =>
            (a['datetime'] as String).compareTo(b['datetime'] as String));
      final phoneWindow =
          values.sublist(values.length - 120).reversed.toList();
      final fullWindow = values.reversed.toList(); // 200 bars, API order
      final responses = <String>[
        jsonEncode({'status': 'ok', 'values': phoneWindow}),
        jsonEncode({'status': 'ok', 'values': fullWindow}),
      ];
      final requestedSizes = <String>[];
      final client = MockClient((req) async {
        requestedSizes.add(req.url.queryParameters['outputsize'] ?? '');
        return http.Response(responses.removeAt(0), 200);
      });
      final s = TwelveDataCandleService(apiKey: 'k', client: client);
      final candles = await s.fetchCandles(Instrument.xauUsd,
          interval: '15min', limit: 120, backfillWhenClosed: true);
      // Widened exactly once, 120 -> 300.
      expect(requestedSizes, ['120', '300']);
      // Friday's real session only: 78 bars. The three Fri 22:00-22:30
      // UTC transition bars now drop by clock (post-close synthetic,
      // Nov 22 revision).
      expect(candles.length, 78);
      expect(candles.first.time.toUtc(), DateTime.utc(2026, 11, 13, 2, 30));
      expect(candles.last.time.toUtc(), DateTime.utc(2026, 11, 13, 21, 45));
      // No survivor sits inside the confirmed-closed clock window.
      for (final c in candles) {
        final u = c.time.toUtc();
        final inClosed = u.weekday == DateTime.saturday ||
            (u.weekday == DateTime.sunday && u.hour < 21) ||
            (u.weekday == DateTime.friday && u.hour >= 22);
        expect(inClosed, isFalse, reason: 'closed-window survivor at $u');
      }
    });

    test('Nov 22 user report: sparse REAL-RANGE weekend bars are dropped '
        'by clock; the bounded loop backfills Friday\'s session and the '
        '15-minute cache caps provider requests', () async {
      // Nov 21-22 2026: Twelve Data emitted sparse bars with multi-dollar
      // ranges through the weekend (the 5m chart showed 3 candles, one
      // auto-scaled to full height). No frozen signature matches them;
      // the clock window is the only reliable discriminator.
      String bar(String dt, double o, double h, double l, double c) =>
          '{"datetime":"$dt","open":"$o","high":"$h","low":"$l",'
          '"close":"$c","volume":"0"}';
      // First window (as the 5m chart fetched it Sunday 12:49 IST):
      // nothing but 3 sparse real-range weekend bars.
      final firstWindow = jsonEncode({'status': 'ok', 'values': [
        bar('2026-11-21 23:00:00', 3538.10, 3538.60, 3537.90, 3538.40),
        bar('2026-11-22 00:10:00', 3536.20, 3539.40, 3535.80, 3539.10),
        bar('2026-11-22 00:15:00', 3539.05, 3539.30, 3538.90, 3539.20),
      ]});
      // Widened to 300: still only weekend bars.
      final secondWindow = jsonEncode({'status': 'ok', 'values': [
        for (var i = 0; i < 40; i++)
          bar('2026-11-21 0${i % 10}:0${i % 6}0:00', 3538.0 + i * 0.3,
              3538.5 + i * 0.3, 3537.8 + i * 0.3, 3538.2 + i * 0.3),
      ]});
      // Widened to 1200: Friday's real session tail appears.
      final fridayBars = <String>[
        for (var i = 0; i < 100; i++)
          () {
            final t = DateTime.utc(2026, 11, 20, 12, 0)
                .add(Duration(minutes: 5 * i));
            final dt =
                '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
                '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';
            return '{"datetime":"$dt","open":"${3530 + i * 0.4}",'
                '"high":"${3531 + i * 0.4}","low":"${3529.5 + i * 0.4}",'
                '"close":"${3530.5 + i * 0.4}","volume":"0"}';
          }(),
        bar('2026-11-21 23:00:00', 3538.10, 3538.60, 3537.90, 3538.40),
      ];
      final thirdWindow =
          jsonEncode({'status': 'ok', 'values': fridayBars.reversed.toList()});
      final responses = <String>[firstWindow, secondWindow, thirdWindow];
      final requestedSizes = <String>[];
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        requestedSizes.add(req.url.queryParameters['outputsize'] ?? '');
        return http.Response(responses.removeAt(0), 200);
      });
      final s = TwelveDataCandleService(apiKey: 'k', client: client);
      final candles = await s.fetchCandles(Instrument.xauUsd,
          interval: '5min', limit: 120, backfillWhenClosed: true);
      // Bounded loop: 120 -> 300 -> 1200, then Friday's session.
      expect(requestedSizes, ['120', '300', '1200']);
      // Every synthetic weekend bar is gone; only Friday bars survive.
      expect(candles.length, 100);
      expect(candles.last.time.toUtc(), DateTime.utc(2026, 11, 20, 20, 15));
      for (final c in candles) {
        expect(c.time.toUtc().weekday, DateTime.friday);
      }
      // The 15-minute weekend cache: an immediate reload (chart timer)
      // reuses the widened result without new provider requests.
      final again = await s.fetchCandles(Instrument.xauUsd,
          interval: '5min', limit: 120, backfillWhenClosed: true);
      expect(again.length, 100);
      expect(calls, 3);
    });

    test('backfill refetch failure throws - no candles are ever '
        'synthesized to fill a closed window', () async {
      final raw = jsonDecode(
          File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
      final values = (raw['values'] as List).cast<Map<String, dynamic>>()
        ..sort((a, b) =>
            (a['datetime'] as String).compareTo(b['datetime'] as String));
      final phoneWindow =
          values.sublist(values.length - 120).reversed.toList();
      final responses = <http.Response>[
        http.Response(
            jsonEncode({'status': 'ok', 'values': phoneWindow}), 200),
        http.Response('server error', 500),
      ];
      final s = TwelveDataCandleService(
          apiKey: 'k', client: MockClient((req) async => responses.removeAt(0)));
      await expectLater(
          s.fetchCandles(Instrument.xauUsd,
              interval: '15min', limit: 120, backfillWhenClosed: true),
          throwsA(isA<MarketDataException>()));
    });

    test('backfillWhenClosed off by default: all-closed fetch still '
        'throws (AutoTrade weekend skip preserved)', () async {
      final raw = jsonDecode(
          File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
      final values = (raw['values'] as List).cast<Map<String, dynamic>>()
        ..sort((a, b) =>
            (a['datetime'] as String).compareTo(b['datetime'] as String));
      final phoneWindow =
          values.sublist(values.length - 120).reversed.toList();
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        return http.Response(
            jsonEncode({'status': 'ok', 'values': phoneWindow}), 200);
      });
      final s = TwelveDataCandleService(apiKey: 'k', client: client);
      await expectLater(
          s.fetchCandles(Instrument.xauUsd, interval: '15min', limit: 120),
          throwsA(isA<MarketDataException>()));
      expect(calls, 1); // no silent widening
    });

    test('all-placeholder fetch throws honestly (AutoTrade skips, '
        'never signals on synthetic bars)', () async {
      // Saturday: AutoTrade's 60-bar fetch (auto_trade.dart) lands
      // entirely inside the closed market. Every bar is a placeholder, so
      // the filter empties the series and fetchCandles throws; AutoTrade's
      // catch logs "No candle data - skipped" and no signal is computed
      // on fabricated prices.
      final buf = StringBuffer('{"status":"ok","values":[');
      final bars = <String>[
        for (var i = 0; i < 60; i++)
          () {
            final t = DateTime.utc(2026, 11, 14, 3, 0)
                .add(Duration(minutes: 15 * i));
            final dt =
                '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
                '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:00';
            return '{"datetime":"$dt","open":"3874.43","high":"3874.61",'
                '"low":"3874.38","close":"3874.47","volume":"0"}';
          }(),
      ];
      buf.writeAll(bars.reversed, ',');
      buf.write(']}');
      final s = TwelveDataCandleService(
          apiKey: 'k', client: fakeClient(200, buf.toString()));
      await expectLater(
          s.fetchCandles(Instrument.xauUsd, interval: '15min', limit: 60),
          throwsA(isA<MarketDataException>()));
    });
  });

  group('dropClosedMarketPlaceholders', () {
    Candle bar(int i, double open, double range) => Candle(
        time: DateTime.utc(2026, 11, 14).add(Duration(minutes: 15 * i)),
        open: open,
        high: open + range,
        low: open,
        close: open + range / 2);

    test('drops every bar inside the confirmed-closed window, whatever '
        'its shape (Nov 22 revision)', () {
      // Saturday bars, real-shaped (moving opens, 20 USD ranges) and
      // frozen-shaped alike: no tradable session exists on Saturday, so
      // the clock drops all of them. Shape no longer matters.
      final cs = <Candle>[
        for (var i = 0; i < 5; i++) bar(i, 3900 + i * 3.0, 20.0),
        for (var i = 5; i < 25; i++) bar(i, 3874.43, 0.23),
        bar(25, 3900.0, 18.0),
      ];
      expect(dropClosedMarketPlaceholders(cs), isEmpty);
    });

    test('keeps quiet weekday stretches - shape is never a reason to '
        'drop (Nov 22 revision)', () {
      // Monday 03:00 UTC: frozen-looking bars during real trading hours
      // are real market data and must survive.
      final cs = <Candle>[
        for (var i = 0; i < 3; i++)
          Candle(
              time: DateTime.utc(2026, 11, 9, 3, 0)
                  .add(Duration(minutes: 15 * i)),
              open: 3900 + i * 2.0,
              high: 3900 + i * 2.0 + 15.0,
              low: 3900 + i * 2.0,
              close: 3900 + i * 2.0 + 7.5),
        for (var i = 3; i < 10; i++)
          Candle(
              time: DateTime.utc(2026, 11, 9, 3, 0)
                  .add(Duration(minutes: 15 * i)),
              open: 3874.43,
              high: 3874.66,
              low: 3874.43,
              close: 3874.55),
        Candle(
            time: DateTime.utc(2026, 11, 9, 3, 0)
                .add(const Duration(minutes: 150)),
            open: 3900.0,
            high: 3915.0,
            low: 3900.0,
            close: 3907.5),
      ];
      expect(dropClosedMarketPlaceholders(cs).length, cs.length);
    });

    test('keeps a long frozen run during legitimate WEEKDAY trading', () {
      // The closed-session guard is load-bearing: a quiet weekday stretch
      // with frozen-looking bars is real market data and must survive
      // even past the run-length bar. Tuesday 03:00 UTC, 20 frozen bars.
      final cs = <Candle>[
        for (var i = 0; i < 3; i++) bar(i, 3900 + i * 2.0, 15.0),
        for (var i = 3; i < 23; i++)
          Candle(
              time: DateTime.utc(2026, 11, 10, 3, 0)
                  .add(Duration(minutes: 15 * i)),
              open: 3874.43,
              high: 3874.66,
              low: 3874.43,
              close: 3874.55),
        bar(23, 3900.0, 15.0),
      ];
      expect(dropClosedMarketPlaceholders(cs).length, cs.length);
    });

    test('keeps a frozen run in the DST-ambiguous Friday 21:00-22:00 UTC '
        'hour (winter: market actually live)', () {
      // Friday Nov 13 2026 (EST): cited closes disagree (20:58-22:00 UTC),
      // and Twelve Data itself served real bars until 22:00 UTC. A frozen
      // run starting 21:00 UTC must survive - sources disagree, no delete.
      final cs = <Candle>[
        Candle(
            time: DateTime.utc(2026, 11, 13, 20, 45),
            open: 3900.0,
            high: 3915.0,
            low: 3900.0,
            close: 3907.5),
        for (var i = 1; i < 13; i++)
          Candle(
              time: DateTime.utc(2026, 11, 13, 21, 0)
                  .add(Duration(minutes: 15 * (i - 1))),
              open: 3874.43,
              high: 3874.66,
              low: 3874.43,
              close: 3874.55),
      ];
      // The ambiguous 21:00-21:45 UTC bars survive (sources disagree
      // there); bars from 22:00 UTC are post-close synthetic and drop
      // by clock. Kept: the 20:45 real bar + the four edge bars.
      expect(dropClosedMarketPlaceholders(cs).length, 5);
    });

    test('keeps a frozen run crossing the ambiguous Sunday reopen edge', () {
      // Sunday 20:00-22:45 UTC: cited reopens disagree (21:00-23:05).
      // Bars before 21:00 are confirmed-closed and drop by clock; the
      // ambiguous edge bars from 21:00 are kept whole.
      final cs = <Candle>[
        for (var i = 1; i < 13; i++)
          Candle(
              time: DateTime.utc(2026, 11, 15, 20, 0)
                  .add(Duration(minutes: 15 * (i - 1))),
              open: 3874.43,
              high: 3874.66,
              low: 3874.43,
              close: 3874.55),
      ];
      expect(dropClosedMarketPlaceholders(cs).length, 8);
    });

    test('drops a frozen run fully inside the confirmed weekend '
        '(Sat 00:00 - Sun 21:00 UTC)', () {
      final cs = <Candle>[
        bar(0, 3900.0, 15.0),
        for (var i = 1; i < 13; i++)
          Candle(
              time: DateTime.utc(2026, 11, 14, 22, 0)
                  .add(Duration(minutes: 15 * (i - 1))),
              open: 3874.43,
              high: 3874.66,
              low: 3874.43,
              close: 3874.55),
      ];
      // Saturday 22:00 - Sunday 00:45: all confirmed-closed, every bar
      // drops by clock (Nov 22 revision: shape no longer consulted).
      expect(dropClosedMarketPlaceholders(cs), isEmpty);
    });

    test('drops a frozen run whose open STEPS a few cents mid-run '
        '(the one-candle bug, user report Nov 15 2026)', () {
      // Saturday run of 12 placeholder bars; the 6th open steps +0.03 -
      // over the old 0.02 chain, which used to split the run and leave
      // the step bar alive as a single full-screen candle.
      final cs = <Candle>[
        bar(0, 3900.0, 15.0),
        for (var i = 1; i < 13; i++)
          Candle(
              time: DateTime.utc(2026, 11, 14, 8, 0)
                  .add(Duration(minutes: 15 * (i - 1))),
              open: 3874.43 + (i >= 6 ? 0.03 : 0),
              high: 3874.66 + (i >= 6 ? 0.03 : 0),
              low: 3874.43 + (i >= 6 ? 0.03 : 0),
              close: 3874.55 + (i >= 6 ? 0.03 : 0)),
      ];
      // Nov 22 revision: every bar here sits on Saturday, so the clock
      // drops all of them; the step-chain reasoning is retired with the
      // signature filter.
      expect(dropClosedMarketPlaceholders(cs), isEmpty);
    });

    test('keeps real bars whose opens move on a WEEKDAY, however quiet',
        () {
      // 10 flat-ish bars but each open steps 0.5 - a drifting market.
      // (Inside the closed window even moving bars now drop by clock:
      // covered by the Nov 22 test above.)
      final cs = <Candle>[
        for (var i = 0; i < 10; i++)
          Candle(
              time: DateTime.utc(2026, 11, 10, 6, 0)
                  .add(Duration(minutes: 15 * i)),
              open: 3874.0 + i * 0.5,
              high: 3874.0 + i * 0.5 + 0.8,
              low: 3874.0 + i * 0.5,
              close: 3874.0 + i * 0.5 + 0.4),
      ];
      expect(dropClosedMarketPlaceholders(cs).length, cs.length);
    });
  });

  group('RealtimePriceStream', () {
    test('connected -> keeps last real quote on error -> disconnects after maxFailures, never fabricates', () async {
      var calls = 0;
      final client = MockClient((req) async {
        calls++;
        if (calls == 1) {
          return http.Response(swissquoteFixture, 200);
        }
        return http.Response('boom', 500);
      });
      final rps = RealtimePriceStream(
        provider: SwissquoteQuoteProvider(client: client),
        interval: const Duration(milliseconds: 20),
        maxFailures: 3,
      );
      final events = <QuoteEvent>[];
      final sub = rps.stream.listen(events.add);
      rps.start();
      await Future.delayed(const Duration(milliseconds: 250));
      await sub.cancel();
      await rps.stop();

      expect(events.first.status, MarketDataStatus.connected);
      expect(events.first.quote!.bid, 4160.696);
      // failures: reconnecting twice, then disconnected
      expect(events[1].status, MarketDataStatus.reconnecting);
      expect(events[2].status, MarketDataStatus.reconnecting);
      expect(events[3].status, MarketDataStatus.disconnected);
      // last real quote is retained, never replaced
      expect(events[3].quote!.bid, 4160.696);
    });
  });

  group('TwelveDataCandleService daily/weekly datetimes', () {
    // Real api.twelvedata.com/time_series format for interval=1day/1week:
    // date-only datetimes (captured from Twelve Data's own XAU/USD widget,
    // 2026-10-25). Regression: these used to parse as null and produce
    // "zero usable candles", killing D1/W1 and the 3M/1Y ranges.
    const dailyFixture = '''
{"meta":{"symbol":"XAU/USD","interval":"1day","currency_base":"Gold Spot"},
 "values":[
  {"datetime":"2026-10-23","open":"4111.5","high":"4130.2","low":"4101.1","close":"4120.4"},
  {"datetime":"2026-10-24","open":"3993.62","high":"3993.80","low":"3993.56","close":"3993.68"},
  {"datetime":"2026-10-25","open":"3993.61501","high":"3993.79632","low":"3993.55518","close":"3993.68466"}],
 "status":"ok"}''';

    test('date-only daily bars parse anchored to UTC midnight', () async {
      final svc = TwelveDataCandleService(
          apiKey: 'k', client: fakeClient(200, dailyFixture));
      final candles = await svc.fetchCandles(Instrument.xauUsd,
          interval: '1day', limit: 3);
      expect(candles, hasLength(3));
      // UTC midnight -> local: the instant equals 00:00 UTC on that date.
      expect(candles.last.time.toUtc(), DateTime.utc(2026, 10, 25));
      expect(candles.last.open, 3993.61501);
      expect(candles.last.close, 3993.68466);
      expect(candles.first.time.toUtc(), DateTime.utc(2026, 10, 23));
    });
  });

  group('Quote model', () {
    test('spread/mid/staleness', () {
      final q = Quote(
        instrument: 'XAU/USD',
        bid: 100,
        ask: 101,
        ts: DateTime.now(),
        source: 'test',
      );
      expect(q.spread, closeTo(1, 1e-9));
      expect(q.mid, closeTo(100.5, 1e-9));
      expect(q.isStale(const Duration(minutes: 1)), isFalse);
      final old = Quote(
        instrument: 'XAU/USD',
        bid: 100,
        ask: 101,
        ts: DateTime.now().subtract(const Duration(minutes: 10)),
        source: 'test',
      );
      expect(old.isStale(const Duration(minutes: 1)), isTrue);
    });
  });
}
