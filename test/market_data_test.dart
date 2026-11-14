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
      // 3 real Friday bars + the first frozen bar (indistinguishable from
      // a real bar: its open moved from the previous real bar) + the real
      // Sunday bar. The other 19 frozen bars are gone.
      expect(candles.length, 5);
      expect(candles.last.time.toUtc(), DateTime.utc(2026, 11, 15, 22, 30));
      expect(candles[2].time.toUtc(), DateTime.utc(2026, 11, 13, 22, 15));
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

    test('drops a long frozen run anywhere in the series', () {
      final cs = <Candle>[
        for (var i = 0; i < 5; i++) bar(i, 3900 + i * 3.0, 20.0),
        for (var i = 5; i < 25; i++) bar(i, 3874.43, 0.23),
        bar(25, 3900.0, 18.0),
      ];
      // First frozen bar survives: from the preceding real bar its open
      // moved, so nothing marks it. The other 19 are dropped.
      final kept = dropClosedMarketPlaceholders(cs);
      expect(kept.length, 7);
      expect(kept.last.close, 3909.0);
    });

    test('keeps short quiet stretches - they can be a live market', () {
      final cs = <Candle>[
        for (var i = 0; i < 3; i++) bar(i, 3900 + i * 2.0, 15.0),
        // 7 frozen bars: below the run-length bar, all kept.
        for (var i = 3; i < 10; i++) bar(i, 3874.43, 0.23),
        bar(10, 3900.0, 15.0),
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

    test('keeps real bars whose opens move, however quiet', () {
      // 10 flat-ish bars but each open steps 0.5 - a drifting market,
      // not a frozen feed.
      final cs = <Candle>[
        for (var i = 0; i < 10; i++) bar(i, 3874.0 + i * 0.5, 0.8),
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
