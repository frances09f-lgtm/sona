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
  }) async {
    if (apiKey.isEmpty) {
      throw MarketDataException(
          'Add your Twelve Data key in API settings to load candle history.');
    }
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
    CandleDebugSink.recordFetch(sourceName: name, values: values, secret: apiKey);
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
      final filtered = dropClosedMarketPlaceholders(out);
      final dropped = out.length - filtered.length;
      if (dropped > 0) {
        CandleDebugSink.recordError(name,
            'dropped $dropped closed-market placeholder bars '
            '(last kept: ${filtered.isEmpty ? 'none' : filtered.last.time.toUtc()})');
      }
      if (filtered.isEmpty) {
        throw MarketDataException('zero usable candles from $name');
      }
      return filtered;
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
/// Detection is deliberately data-driven, not clock-driven: the weekly
/// close window shifts an hour with US DST, but a run of 8+ CONSECUTIVE
/// bars with the open frozen to 0.02 USD and sub-1-USD ranges does not
/// occur in a live market - quiet weekday sessions still move. A short
/// quiet stretch therefore survives, and so does the one transition bar
/// where the feed freezes mid-step.
List<Candle> dropClosedMarketPlaceholders(List<Candle> candles) {
  bool frozen(Candle c, Candle prev) =>
      (c.open - prev.open).abs() <= 0.02 && (c.high - c.low) <= 1.0;
  final keep = List<bool>.filled(candles.length, true);
  var runStart = -1;
  for (var i = 1; i <= candles.length; i++) {
    final isFrozen = i < candles.length && frozen(candles[i], candles[i - 1]);
    if (isFrozen && runStart < 0) runStart = i;
    if (!isFrozen && runStart >= 0) {
      if (i - runStart >= 8) {
        // A run that starts at bar 1 leaves bar 0 untestable (no
        // predecessor). If it freezes the same open the same way, it is
        // the head of the same placeholder run, not a live bar: a 60-bar
        // Saturday fetch is otherwise returned as one synthetic candle.
        if (runStart == 1 &&
            (candles[0].open - candles[1].open).abs() <= 0.02 &&
            (candles[0].high - candles[0].low) <= 1.0) {
          keep[0] = false;
        }
        for (var j = runStart; j < i; j++) {
          keep[j] = false;
        }
      }
      runStart = -1;
    }
  }
  return [for (var i = 0; i < candles.length; i++) if (keep[i]) candles[i]];
}
