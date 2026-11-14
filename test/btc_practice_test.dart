import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/btc_feed.dart';
import 'package:sona/btc_paper.dart';

void main() {
  group('BinanceBtcFeed', () {
    test('parses book ticker into a BTC/USDT quote', () async {
      final feed = BinanceBtcFeed(
        hostOverride: 'test.local',
        client: MockClient((req) async {
          expect(req.url.path, '/api/v3/ticker/bookTicker');
          expect(req.url.queryParameters['symbol'], 'BTCUSDT');
          return http.Response(
            '{"symbol":"BTCUSDT","bidPrice":"66938.33","bidQty":"0.4","askPrice":"66963.33","askQty":"0.2"}',
            200,
          );
        }),
      );
      final q = await feed.fetchQuote();
      expect(q.instrument, 'BTC/USDT');
      expect(q.bid, 66938.33);
      expect(q.ask, 66963.33);
      expect(q.source, 'binance');
    });

    test('maps chart intervals to Binance kline intervals', () {
      expect(BinanceBtcFeed.toBinanceInterval('1min'), '1m');
      expect(BinanceBtcFeed.toBinanceInterval('15min'), '15m');
      expect(BinanceBtcFeed.toBinanceInterval('1h'), '1h');
      expect(BinanceBtcFeed.toBinanceInterval('4h'), '4h');
      expect(BinanceBtcFeed.toBinanceInterval('1day'), '1d');
      expect(BinanceBtcFeed.toBinanceInterval('bogus'), '15m');
    });

    test('parses klines oldest-first with UTC times', () async {
      final feed = BinanceBtcFeed(
        hostOverride: 'test.local',
        client: MockClient((req) async {
          expect(req.url.path, '/api/v3/klines');
          expect(req.url.queryParameters['interval'], '15m');
          return http.Response(
            '[[1700000000000,"66000.0","66100.0","65900.0","66050.0","12.5",1700000899999],'
            '[1700000900000,"66050.0","66200.0","66000.0","66150.0","9.1",1700001799999]]',
            200,
          );
        }),
      );
      final cs = await feed.fetchCandles(interval: '15min', limit: 2);
      expect(cs, hasLength(2));
      expect(cs.first.close, 66050.0);
      expect(cs.last.close, 66150.0);
      expect(cs.first.time.isUtc, isTrue);
      expect(cs.first.time.millisecondsSinceEpoch, 1700000000000);
    });

    test('raises a clear error when every host fails', () async {
      final feed = BinanceBtcFeed(
        hostOverride: 'test.local',
        client: MockClient((req) async => http.Response('nope', 418)),
      );
      expect(feed.fetchQuote(), throwsA(isA<BtcFeedException>()));
      expect(feed.fetchCandles(), throwsA(isA<BtcFeedException>()));
    });

    test('rejects a crossed or unusable quote', () async {
      final feed = BinanceBtcFeed(
        hostOverride: 'test.local',
        client: MockClient(
          (req) async => http.Response(
            '{"symbol":"BTCUSDT","bidPrice":"67000","bidQty":"1","askPrice":"66000","askQty":"1"}',
            200,
          ),
        ),
      );
      expect(feed.fetchQuote(), throwsA(isA<BtcFeedException>()));
    });
  });

  group('BtcPaperState', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await SharedPreferences.getInstance();
    });

    test('opens a buy at ask; non-step sizes are refused', () {
      final s = BtcPaperState();
      final err = s.open(prefs, 'buy', 0.002, null, null, 100, 101);
      expect(err, isNull);
      expect(s.open(prefs, 'buy', 0.0014, null, null, 100, 101), contains('steps of 0.001'));
      expect(s.openPositions.single['qty'], closeTo(0.002, 1e-9));
      expect(s.openPositions.single['entry'], 101);
      expect(s.openPositions.single['instrument'], 'BTC/USDT');
    });

    test('rejects below-minimum size and bad protection sides', () {
      final s = BtcPaperState();
      expect(s.open(prefs, 'buy', 0.0004, null, null, 100, 101), isNotNull);
      expect(s.open(prefs, 'buy', 0.01, 90, null, 100, 101), isNotNull);
      expect(s.open(prefs, 'buy', 0.01, null, 120, 100, 101), isNotNull);
      expect(s.open(prefs, 'sell', 0.01, 120, null, 100, 101), isNotNull);
      expect(s.open(prefs, 'sell', 0.01, 95, 105, 100, 101), isNull);
    });

    test('margin guard blocks oversized positions', () {
      final s = BtcPaperState();
      // 1 BTC @ 67000 / 500 = 134 USDT margin; affordable on 10000.
      expect(s.open(prefs, 'buy', 1, null, null, 66900, 67000), isNull);
      // 100 BTC needs 13400 USDT > balance - blocked.
      final err = s.open(prefs, 'buy', 100, null, null, 66900, 67000);
      expect(err, contains('Not enough practice margin'));
      expect(err, isNot(contains('oz'))); // no gold wording in BTC UI
    });

    test('close realizes pnl into the USDT balance', () {
      final s = BtcPaperState();
      s.open(prefs, 'buy', 0.01, null, null, 66900, 67000);
      final id = s.openPositions.single['id'] as String;
      s.close(prefs, id, 68000, 68050);
      expect(s.openPositions, isEmpty);
      expect(s.balance, closeTo(10000 + (68000 - 67000) * 0.01, 1e-9));
      expect(s.history.single['pnl'], closeTo(10.0, 1e-9));
      expect(s.history.single['closeReason'], 'Manual close');
    });

    test('TP/SL watchdog closes at the right side price', () {
      final s = BtcPaperState();
      s.open(prefs, 'buy', 0.01, 68000, 66000, 66900, 67000);
      // TP: buy exits at bid when bid >= tp.
      var closed = s.checkTpsl(prefs, 68010, 68060);
      expect(closed, hasLength(1));
      expect(s.history.single['exit'], 68010);
      expect(s.history.single['closeReason'], 'Take profit hit');
      // Sell SL: exits at ask when ask >= sl.
      s.open(prefs, 'sell', 0.01, 65000, 67100, 66900, 67000);
      closed = s.checkTpsl(prefs, 67150, 67200);
      expect(closed, hasLength(1));
      expect(s.history.first['exit'], 67200);
      expect(s.history.first['closeReason'], 'Stop loss hit');
    });

    test('persists and reloads under its own key only', () async {
      final s = BtcPaperState();
      s.open(prefs, 'buy', 0.01, null, null, 66900, 67000);
      await Future.delayed(Duration.zero);
      final keys = prefs.getKeys();
      expect(keys, {'sona_btc_paper_v1'});
      final s2 = BtcPaperState();
      await s2.load(prefs);
      expect(s2.openPositions, hasLength(1));
      expect(s2.balance, s.balance);
    });

    test('corrupt stored state falls back to a fresh ledger', () async {
      await prefs.setString('sona_btc_paper_v1', '{broken');
      final s = BtcPaperState();
      await s.load(prefs);
      expect(s.balance, BtcPaperState.startBalance);
      expect(s.openPositions, isEmpty);
    });
  });
}
