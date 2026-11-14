import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'market_data/models.dart';

/// Error raised when every Binance public-data host fails.
class BtcFeedException implements Exception {
  final String message;
  BtcFeedException(this.message);
  @override
  String toString() => message;
}

/// BTC/USDT spot market data from Binance's public, key-free REST API.
///
/// Used only by the BTC practice panel. Gold data keeps flowing through the
/// existing Swissquote/Twelve Data providers; nothing here is shared with
/// the gold path.
///
/// Host fallback: api.binance.com is geo-blocked in some regions (the dev
/// sandbox is one), so requests walk a list of official mirrors and the
/// market-data-only host data-api.binance.vision (documented in
/// binance-spot-api-docs/faqs/market_data_only.md). On-device reachability
/// from India is unverified; the panel must surface feed errors, not fake
/// data.
class BinanceBtcFeed {
  static const List<String> hosts = [
    'api.binance.com',
    'api1.binance.com',
    'api2.binance.com',
    'api3.binance.com',
    'api4.binance.com',
    'data-api.binance.vision',
  ];

  static const String symbol = 'BTCUSDT';

  final http.Client client;

  /// Test hook: pin every request to one host instead of walking [hosts].
  final String? hostOverride;

  BinanceBtcFeed({http.Client? client, this.hostOverride})
    : client = client ?? http.Client();

  /// Maps the chart's interval codes (Twelve Data style) to Binance's.
  static String toBinanceInterval(String iv) => switch (iv) {
    '1min' => '1m',
    '5min' => '5m',
    '15min' => '15m',
    '30min' => '30m',
    '1h' || '1hour' => '1h',
    '4h' => '4h',
    '1day' => '1d',
    '1week' => '1w',
    _ => '15m',
  };

  Future<dynamic> _getJson(String path, Map<String, String> params) async {
    final tryHosts = hostOverride != null ? [hostOverride!] : hosts;
    Object? lastError;
    for (final host in tryHosts) {
      try {
        final r = await client
            .get(Uri.https(host, path, params))
            .timeout(const Duration(seconds: 10));
        if (r.statusCode != 200) {
          lastError = 'HTTP ${r.statusCode} from $host';
          continue;
        }
        return jsonDecode(r.body);
      } catch (e) {
        lastError = e;
      }
    }
    throw BtcFeedException(
      'BTC feed unavailable right now. Check the internet connection and try again. ($lastError)',
    );
  }

  /// Live bid/ask from the book ticker. BTC/USDT: the quote currency is the
  /// USDT stablecoin, not USD - UI must label it USDT.
  Future<Quote> fetchQuote() async {
    final j = await _getJson('/api/v3/ticker/bookTicker', {
      'symbol': symbol,
    });
    final bid = double.tryParse('${j['bidPrice']}');
    final ask = double.tryParse('${j['askPrice']}');
    if (bid == null || ask == null || bid <= 0 || ask < bid) {
      throw BtcFeedException('BTC feed returned an unusable quote.');
    }
    return Quote(
      instrument: 'BTC/USDT',
      bid: bid,
      ask: ask,
      ts: DateTime.now().toUtc(),
      source: 'binance',
    );
  }

  /// 24h change percent for the header line (polled infrequently).
  Future<double?> fetchDayChangePct() async {
    final j = await _getJson('/api/v3/ticker/24hr', {'symbol': symbol});
    return double.tryParse('${j['priceChangePercent']}');
  }

  /// Historical candles, oldest first, times in UTC.
  Future<List<Candle>> fetchCandles({
    String interval = '15m',
    int limit = 200,
  }) async {
    final j = await _getJson('/api/v3/klines', {
      'symbol': symbol,
      'interval': toBinanceInterval(interval),
      'limit': '$limit',
    });
    if (j is! List) throw BtcFeedException('BTC feed returned no candles.');
    final out = <Candle>[];
    for (final k in j) {
      if (k is! List || k.length < 6) continue;
      final t = k[0] is num ? (k[0] as num).toInt() : int.tryParse('${k[0]}');
      final o = double.tryParse('${k[1]}');
      final h = double.tryParse('${k[2]}');
      final l = double.tryParse('${k[3]}');
      final c = double.tryParse('${k[4]}');
      final v = double.tryParse('${k[5]}');
      if (t == null || o == null || h == null || l == null || c == null) {
        continue;
      }
      out.add(
        Candle(
          time: DateTime.fromMillisecondsSinceEpoch(t, isUtc: true),
          open: o,
          high: h,
          low: l,
          close: c,
          volume: v,
        ),
      );
    }
    if (out.isEmpty) {
      throw BtcFeedException('BTC feed returned no usable candles.');
    }
    return out;
  }
}
