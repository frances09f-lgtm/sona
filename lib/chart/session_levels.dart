import '../market_data/models.dart';

/// Session shading + previous day/week high-low levels for the chart.
///
/// TradingView/OANDA reference semantics:
/// - A gold "trading day" closes at 5pm New York (21:00 UTC during US
///   daylight time, 22:00 UTC in standard time) - the OANDA daily close.
/// - A trading week opens Sunday 5pm ET and closes Friday 5pm ET.
/// - Session windows (UTC, widely used spot-gold reference hours, matching
///   sessions.dart): Asia/Tokyo 00-09, London 08-17, New York 13-22.

/// US daylight-saving rule (post-2007): EDT from the second Sunday of March
/// 07:00 UTC to the first Sunday of November 06:00 UTC.
bool isUsDaylightTime(DateTime utc) {
  final u = utc.toUtc();
  int nthSunday(int year, int month, int n) {
    var d = DateTime.utc(year, month, 1);
    var count = 0;
    while (true) {
      if (d.weekday == DateTime.sunday) {
        count++;
        if (count == n) return d.day;
      }
      d = d.add(const Duration(days: 1));
    }
  }

  final start = DateTime.utc(u.year, 3, nthSunday(u.year, 3, 2), 7);
  final end = DateTime.utc(u.year, 11, nthSunday(u.year, 11, 1), 6);
  return !u.isBefore(start) && u.isBefore(end);
}

/// Hour (UTC) at which the current gold trading day closes: 5pm New York.
int nyCloseHourUtc(DateTime utc) => isUsDaylightTime(utc) ? 21 : 22;

/// Key identifying the NY-close trading day containing [utc]. Candles
/// before 5pm ET belong to the day that opened at the previous 5pm ET.
DateTime nyDayKey(DateTime utc) {
  final u = utc.toUtc();
  final shifted = u.subtract(Duration(hours: nyCloseHourUtc(u)));
  return DateTime.utc(shifted.year, shifted.month, shifted.day);
}

/// Key identifying the trading week containing [utc]: the Sunday (5pm ET
/// shifted back to midnight) on which the week opened.
DateTime nyWeekKey(DateTime utc) {
  final day = nyDayKey(utc);
  final back = day.weekday % 7; // Sunday -> 0, Monday -> 1, ...
  return day.subtract(Duration(days: back));
}

(double, double)? _hlOf(List<Candle> candles, DateTime key,
    DateTime Function(DateTime) keyOf, DateTime exclude) {
  double? hi, lo;
  for (final c in candles) {
    if (keyOf(c.time) != key) continue;
    hi = hi == null ? c.high : (c.high > hi ? c.high : hi);
    lo = lo == null ? c.low : (c.low < lo ? c.low : lo);
  }
  return hi == null ? null : (hi, lo!);
}

/// High/low of the last COMPLETE NY-close trading day before the current
/// one, or null when the history does not cover it.
(double, double)? previousDayHL(List<Candle> candles, {DateTime? now}) {
  if (candles.isEmpty) return null;
  final ref = (now ?? DateTime.now()).toUtc();
  final currentKey = nyDayKey(ref);
  final prevKey = currentKey.subtract(const Duration(days: 1));
  // Skip the weekend gap: if the "previous" day key holds no candles
  // (Saturday/Sunday), walk back to the last day that does.
  for (var k = prevKey;
      k.isAfter(prevKey.subtract(const Duration(days: 4)));
      k = k.subtract(const Duration(days: 1))) {
    final hl = _hlOf(candles, k, nyDayKey, currentKey);
    if (hl != null) return hl;
  }
  return null;
}

/// High/low of the last COMPLETE trading week (Fri 5pm ET close) before the
/// current one.
(double, double)? previousWeekHL(List<Candle> candles, {DateTime? now}) {
  if (candles.isEmpty) return null;
  final ref = (now ?? DateTime.now()).toUtc();
  final currentKey = nyWeekKey(ref);
  final prevKey = currentKey.subtract(const Duration(days: 7));
  return _hlOf(candles, prevKey, nyWeekKey, currentKey);
}

/// Which shaded session (if any) a UTC instant belongs to. Asia/Tokyo,
/// London and New York overlap - the painter layers all active bands.
enum ChartSession { asia, london, newYork }

List<ChartSession> sessionsAt(DateTime utc) {
  final u = utc.toUtc();
  if (u.weekday == DateTime.saturday || u.weekday == DateTime.sunday) {
    return const [];
  }
  final h = u.hour;
  final out = <ChartSession>[];
  if (h >= 0 && h < 9) out.add(ChartSession.asia);
  if (h >= 8 && h < 17) out.add(ChartSession.london);
  if (h >= 13 && h < 22) out.add(ChartSession.newYork);
  return out;
}
