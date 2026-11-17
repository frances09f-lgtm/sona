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
    final first = await _fetchOnce(instrument, interval, limit);
    if (first.isNotEmpty || !backfillWhenClosed || limit >= 5000) {
      if (first.isEmpty) {
        throw MarketDataException('zero usable candles from $name');
      }
      return first;
    }
    // The whole window was confirmed-closed placeholder bars (a weekend
    // 1H/1D fetch). Widen once so the chart keeps the last real session
    // instead of going blank; AutoTrade and advice keep the default
    // throw so their closed-market skip is untouched.
    final widened = await _fetchOnce(
        instrument, interval, limit < 300 ? 300 : (limit * 4 > 5000 ? 5000 : limit * 4));
    if (widened.isEmpty) {
      throw MarketDataException('zero usable candles from $name');
    }
    return widened;
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
    // Twelve Data keeps emitting synthetic XAU/USD bars after the metals
    // market closes (verified Nov 14, 2026: from Friday 22:15 UTC through
    // the weekend every bar had a frozen open and a ~0.2 USD high-low
    // wiggle while Swissquote sat at Friday's real close). Rendered raw,
    // ~90 of these fill the chart window and the auto-scale blows each
    // 0.2-range placeholder up to full height - the "wall of slivers"
    // bug. Drop intraday bars that sit inside the known closed window AND
    // match the flat signature; real bars can never exist in that window,
    // and the range check keeps the filter glued to the observed
    // placeholder shape instead of the clock alone.
    if (interval.endsWith('min') || interval.endsWith('h')) {
      // Possibly empty: the caller decides whether an all-closed window
      // is an error (default) or triggers one wider backfill fetch.
      return dropClosedMarketPlaceholders(out);
    }
    return out;
  }
}

/// Drops synthetic closed-market placeholder runs from Twelve Data's
/// XAU/USD intraday feed.
///
/// Verified against the live feed (user report Nov 15, 2026): after the
/// Friday ~22:15 UTC close until the Sunday ~22:30 UTC reopen the feed
/// keeps emitting 15-minute bars whose open is frozen to within cents of
/// the previous bar's open and whose high-low range stays around 0.2 USD,
/// while real 15-minute bars in the same fetch range 20-36 USD. Rendered
/// raw, ~90 of these fill the chart on a Saturday and the auto-scale blows
/// each placeholder up to a full-height sliver; the quote row correctly
/// shows Friday's real close as stale, so chart and header disagree by
/// dollars.
///
/// A bar is dropped only when BOTH conditions hold:
///  1. Confirmed closed: its timestamp falls in the intersection of every
///     cited closure window for the XAU/USD trading week:
///       - this app's session table (sessions.dart): Fri 21:00 - Sun 21:00
///       - CME gold futures (17:00-18:00 ET close/open): Fri 21:00 -
///         Sun 22:00 UTC during US daylight time (ET = UTC-4), Fri 22:00 -
///         Sun 23:00 UTC in standard time (ET = UTC-5)
///       - broker OTC schedules (e.g. Exness): Fri 20:58/21:58 -
///         Sun 22:05/23:05 UTC by DST half
///       - Twelve Data's own feed, observed two November 2026 weekends:
///         synthetic bars from Fri 22:15 UTC, real bars resume Sun
///         ~22:30 UTC
///     Closed in ALL of them means: all of Saturday, Friday from 22:00
///     UTC (the latest cited close), and Sunday before 21:00 UTC (the
///     earliest cited open). The one-hour DST edges (Fri 21:00-22:00,
///     Sun 21:00-23:05) are NOT treated as closed: sources disagree
///     there, so bars at those edges are always kept. The weekday
///     settlement break is not filtered at all - its cited hours vary
///     by source and it never produced the corruption.
///  2. Frozen signature: it belongs to a run of 8+ CONSECUTIVE bars each
///     with the open frozen within 0.10 USD of the previous open and a
///     high-low range of at most 1 USD. A quiet weekday stretch never
///     matches (wrong clock), and real bars at the cited edges never
///     match (wrong signature): both guards must fire together. The
///     0.10 chaining tolerance absorbs the few-cent open STEPS the
///     placeholder stream emits (observed 0.022-0.028 USD): with a
///     tighter chain a step bar survived alone and rendered as one
///     full-screen candle (user report Nov 15 2026).
///
/// The first bar of a fetch has no predecessor, so it can only be judged
/// when the run starting right after it reaches 8 bars: if it is frozen
/// the same way and also confirmed-closed, it is the head of the same
/// placeholder run (a Saturday 60-bar fetch otherwise returns one
/// synthetic candle).
///
/// Dropped runs are reported to [CandleDebugSink] with their UTC window
/// and count, so the raw provider behavior stays diagnosable.
List<Candle> dropClosedMarketPlaceholders(List<Candle> candles) {
  // The placeholder stream's frozen open occasionally STEPS by a few
  // cents (verified live Nov 15 2026: a 0.022 USD step at Sat 04:15 UTC
  // broke a 0.02-tolerance chain and left one bar alive, which the chart
  // blew up into a single full-screen candle). Chain on 0.10 USD instead:
  // 4x margin over the observed 0.022-0.028 USD steps, still far below a
  // real drifting market (0.5 USD steps stay alive, covered by test), and
  // the confirmed-closed clock window below already guarantees no real
  // bar can sit inside a dropped run.
  bool frozen(Candle c, Candle prev) =>
      (c.open - prev.open).abs() <= 0.10 && (c.high - c.low) <= 1.0;
  // The conservative intersection described above. Clock-based, but it
  // is the region no cited source - futures, broker OTC, or the
  // provider's own observed behavior - treats as open, so DST shifts of
  // any single schedule cannot reach it.
  bool closedBar(Candle c) {
    final u = c.time.toUtc();
    if (u.weekday == DateTime.saturday) return true;
    if (u.weekday == DateTime.sunday && u.hour < 21) return true;
    if (u.weekday == DateTime.friday && u.hour >= 22) return true;
    return false;
  }
  final keep = List<bool>.filled(candles.length, true);
  final dropped = <int>[];
  var runStart = -1;
  for (var i = 1; i <= candles.length; i++) {
    final isFrozen = i < candles.length && frozen(candles[i], candles[i - 1]);
    if (isFrozen && runStart < 0) runStart = i;
    if (!isFrozen && runStart >= 0) {
      if (i - runStart >= 8 &&
          [for (var j = runStart; j < i; j++) candles[j]].every(closedBar)) {
        if (runStart == 1 &&
            (candles[0].open - candles[1].open).abs() <= 0.10 &&
            (candles[0].high - candles[0].low) <= 1.0 &&
            closedBar(candles[0])) {
          keep[0] = false;
          dropped.add(0);
        }
        for (var j = runStart; j < i; j++) {
          keep[j] = false;
          dropped.add(j);
        }
      }
      runStart = -1;
    }
  }
  if (dropped.isNotEmpty) {
    CandleDebugSink.recordError(
        'TwelveDataCandleService',
        'dropped ${dropped.length} closed-market placeholder bars '
        '${candles[dropped.first].time.toUtc()} .. '
        '${candles[dropped.last].time.toUtc()}');
  }
  return [for (var i = 0; i < candles.length; i++) if (keep[i]) candles[i]];
}
