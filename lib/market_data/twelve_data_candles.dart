import 'dart:convert';
import 'package:http/http.dart' as http;
import 'candle_debug.dart';
import 'market_data_provider.dart';
import 'swissquote_provider.dart';
import 'models.dart';

/// Twelve Data time_series - real Gold Spot / US Dollar (XAU/USD) OHLC
/// candles. Free tier: 8 credits/min, 800/day. Requires an API key that
/// MUST come from config (dart-define / env), never hard-coded.
/// https://api.twelvedata.com/time_series?symbol=XAU/USD&interval=15min
class TwelveDataCandleService implements HistoricalCandleService {
  final http.Client client;
  final String apiKey;

  TwelveDataCandleService({required this.apiKey, http.Client? client})
      : client = client ?? http.Client();

  @override
  String get name => 'twelvedata';

  // Weekend backfill cache. With the market closed the first fetch
  // comes back empty (all synthetic bars dropped) and the bounded widen
  // in fetchCandles costs up to 3 extra requests. The chart reloads on
  // a timer, so without a cache a 5min chart left open on a weekend
  // would burn ~48 requests/hour against the free tier's 800/day.
  // The closed market produces no new real bars, so a 15-minute reuse
  // is safe; after the Sunday reopen the entry expires at most 15
  // minutes late and the live fold keeps the last candle current
  // meanwhile. Keyed by interval+limit.
  static final Map<String, (DateTime, List<Candle>)> _closedBackfillCache =
      {};

  /// Test hook: the cache is process-wide; suites clear it in setUp so
  /// fixtures cannot bleed across tests. Production callers never need
  /// this (the 15-minute TTL is the session boundary).
  static void clearClosedBackfillCache() => _closedBackfillCache.clear();

  @override
  Future<List<Candle>> fetchCandles(
    Instrument instrument, {
    String interval = '15min',
    int limit = 200,
    bool backfillWhenClosed = false,
  }) async {
    if (apiKey.isEmpty) {
      throw MarketDataException(
          'Add your Twelve Data key in API settings to load candle history.');
    }
    // Isolation: keyed by instrument, interval, window size AND the
    // credential in use, so different symbols, timeframes or accounts
    // can never be served each other's weekend bars. Entries only ever
    // come from an all-closed (weekend) first fetch and expire after 15
    // minutes, so a session boundary is bounded by that TTL.
    final cacheKey = '${instrument.symbol}/$interval/$limit/${apiKey.hashCode}';
    if (backfillWhenClosed) {
      final hit = _closedBackfillCache[cacheKey];
      if (hit != null &&
          DateTime.now().difference(hit.$1) < const Duration(minutes: 15)) {
        return List.of(hit.$2);
      }
    }
    var candles = await _fetchOnce(instrument, interval, limit);
    if (candles.isEmpty && backfillWhenClosed) {
      // The whole window was confirmed-closed synthetic bars (a weekend
      // fetch). Widen in bounded steps so the chart keeps the last real
      // session instead of going blank: from at least 300 bars, x4 each
      // step, capped at the provider's 5000-bar maximum. Worst case 3
      // extra requests (1min: 120 -> 300 -> 1200 -> 4800, ~83 hours,
      // reaching Friday's session from anywhere in the weekend); the
      // cache above keeps timer refreshes from repeating them.
      // AutoTrade and advice keep the default throw so their
      // closed-market skip is untouched.
      var size = limit;
      while (candles.isEmpty && size < 5000) {
        size = size < 300 ? 300 : (size * 4 > 5000 ? 5000 : size * 4);
        candles = await _fetchOnce(instrument, interval, size);
      }
      if (candles.isNotEmpty) {
        _closedBackfillCache[cacheKey] = (DateTime.now(), candles);
      }
    }
    if (candles.isEmpty) {
      throw MarketDataException('zero usable candles from $name');
    }
    return candles;
  }

  Future<List<Candle>> _fetchOnce(
      Instrument instrument, String interval, int limit) async {
    // timezone=UTC is load-bearing: without it TwelveData returns naive
    // datetimes in the exchange timezone (Australia/Sydney for XAU/USD),
    // which read as ~8 hours in the FUTURE for an IST user. The forming-
    // candle fold then refuses to touch the "future" last bar, the live
    // price line floats away from the candles and the axis clock is wrong.
    final uri = Uri.https('api.twelvedata.com', '/time_series', {
      'symbol': instrument.symbol,
      'interval': interval,
      'outputsize': '$limit',
      'timezone': 'UTC',
      'apikey': apiKey,
    });
    final res = await client.get(uri).timeout(const Duration(seconds: 15));
    if (res.statusCode != 200) {
      CandleDebugSink.recordError(name, 'HTTP ${res.statusCode}', secret: apiKey);
      throw MarketDataException('HTTP ${res.statusCode} from $name');
    }
    final body = jsonDecode(res.body);
    if (body is! Map<String, dynamic>) {
      throw MarketDataException('unexpected candle payload from $name');
    }
    if (body['status'] == 'error') {
      CandleDebugSink.recordError(
          name, '${body['message'] ?? 'unknown'}', secret: apiKey);
      throw MarketDataException(
          '$name error: ${body['message'] ?? 'unknown'}');
    }
    final values = body['values'];
    if (values is! List) {
      CandleDebugSink.recordError(name, 'no candle values', secret: apiKey);
      throw MarketDataException('no candle values from $name');
    }
    CandleDebugSink.recordFetch(
        sourceName: name,
        values: values,
        secret: apiKey,
        interval: interval);
    final out = <Candle>[];
    for (final v in values) {
      if (v is! Map<String, dynamic>) continue;
      // Requested timezone=UTC, so datetimes are naive UTC
      // ("2026-10-19 12:54:00"). Parse them AS UTC (a bare parse would read
      // them as device-local), then toLocal() so axis labels read in the
      // user's clock and now-vs-candle comparisons stay correct.
      final raw = v['datetime']?.toString() ?? '';
      var norm = raw.contains('T') ? raw : raw.replaceFirst(' ', 'T');
      // Daily and weekly intervals come back date-only ("2026-10-25");
      // anchor them to UTC midnight like Twelve Data's own widgets do.
      if (!norm.contains('T')) norm = '${norm}T00:00:00';
      final time = DateTime.tryParse(
        norm.endsWith('Z') ? norm : '${norm}Z',
      )?.toLocal();
      final o = double.tryParse(v['open']?.toString() ?? '');
      final h = double.tryParse(v['high']?.toString() ?? '');
      final l = double.tryParse(v['low']?.toString() ?? '');
      final c = double.tryParse(v['close']?.toString() ?? '');
      if (time == null || o == null || h == null || l == null || c == null) {
        continue;
      }
      out.add(Candle(
        time: time,
        open: o,
        high: h,
        low: l,
        close: c,
        volume: double.tryParse(v['volume']?.toString() ?? ''),
      ));
    }
    if (out.isEmpty) {
      throw MarketDataException('zero usable candles from $name');
    }
    out.sort((a, b) => a.time.compareTo(b.time)); // oldest-first
    // Twelve Data emits synthetic XAU/USD bars straight through the
    // weekend close (its own symbol page classifies the exchange as
    // 24/7): Nov 14-15 a frozen ~0.2 USD stream, Nov 21-22 sparse
    // real-range indicative bars (user report). No tradable session
    // exists in the confirmed-closed window, so those bars are dropped
    // by clock - see dropClosedMarketPlaceholders.
    if (interval.endsWith('min') || interval.endsWith('h')) {
      // Possibly empty: the caller decides whether an all-closed window
      // is an error (default) or triggers the bounded backfill fetch.
      return dropClosedMarketPlaceholders(out);
    }
    return out;
  }
}

/// Drops Twelve Data's synthetic closed-market XAU/USD bars BY CLOCK.
///
/// Why the clock alone is the right test (revised Nov 22, 2026): Twelve
/// Data's own XAU/USD symbol page classifies the exchange as 24/7
/// (Australia/Sydney), so the feed emits bars straight through the
/// weekend and their SHAPE is not a reliable discriminator. Nov 14-15
/// they were a frozen ~0.2 USD stream (the "wall of slivers" bug); on
/// Nov 21-22 they arrived as sparse bars with multi-dollar ranges (user
/// report: the 5m chart showed 3 candles, one blown to full height by
/// auto-scale) that no frozen/flat signature can ever catch.
///
/// What makes clock-only deletion safe: no TRADABLE XAU/USD session
/// exists inside the confirmed-closed window, verified at the owning
/// sources Nov 22, 2026 - CME gold futures trade Sunday 6:00 p.m. to
/// Friday 5:00 p.m. ET (cmegroup.com GC fact card); Swissquote FX and
/// precious metals close Friday 23:00 CET and resume Sunday 23:00 CET
/// (swissquote.com trading-hours notices); both are 22:00 UTC in
/// November standard time. Bars emitted there are upstream indicative
/// quotes, not tradable session bars: dropping them loses nothing real,
/// and the bounded backfill in fetchCandles restores Friday's actual
/// session so the weekend chart shows real candles with their real
/// timestamps instead of 3 synthetic stragglers.
///
/// The window is the intersection of every cited closure (unchanged
/// from the Nov 15 version): all of Saturday UTC, Friday from 22:00
/// UTC (the latest cited close), and Sunday before 21:00 UTC (the
/// earliest cited open). The DST-ambiguous edges (Fri 21:00-22:00,
/// Sun 21:00-23:05 UTC) are NEVER dropped: sources disagree there, so
/// bars at those edges are always kept. Weekday bars are never dropped;
/// the weekday settlement break is not filtered at all.
///
/// Dropped bars are reported to [CandleDebugSink] with their UTC window
/// and count, so the raw provider behavior stays diagnosable.
List<Candle> dropClosedMarketPlaceholders(List<Candle> candles) {
  // The conservative intersection described above. It is the region no
  // cited source - futures, broker OTC, or the provider's own observed
  // behavior - treats as open, so DST shifts of any single schedule
  // cannot reach it.
  bool closedBar(Candle c) {
    final u = c.time.toUtc();
    if (u.weekday == DateTime.saturday) return true;
    if (u.weekday == DateTime.sunday && u.hour < 21) return true;
    if (u.weekday == DateTime.friday && u.hour >= 22) return true;
    return false;
  }

  final dropped = <int>[];
  final keep = <Candle>[];
  for (var i = 0; i < candles.length; i++) {
    if (closedBar(candles[i])) {
      dropped.add(i);
    } else {
      keep.add(candles[i]);
    }
  }
  if (dropped.isNotEmpty) {
    CandleDebugSink.recordError(
        'TwelveDataCandleService',
        'dropped ${dropped.length} closed-market synthetic bars '
        '${candles[dropped.first].time.toUtc()} .. '
        '${candles[dropped.last].time.toUtc()}');
  }
  return keep;
}
