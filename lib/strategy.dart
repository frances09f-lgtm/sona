import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'market_data/models.dart';

/// Custom price-action strategies (user request Oct 21): a named, noted
/// rule set he defines for backtesting. Device-local (SharedPreferences),
/// like alerts and drawings - never on the server.
///
/// v1 rule: "1H high/low break" - every completed 1-hour candle marks a
/// high and a low; a later break of the high is a long signal, a break of
/// the low is a short signal. Chart lines stop at the break.
class PriceActionStrategy {
  final String id;
  String name;
  String notes;
  bool showOnChart;

  /// Mark the high/low of the N most recent completed 1H candles.
  int lookbackHours;

  /// Trade both directions (long on high break, short on low break).
  bool allowLong;
  bool allowShort;

  /// Stop loss at the opposite side of the broken hour candle
  /// (long -> that hour's low, short -> that hour's high).
  /// Take profit = rrMultiple x the SL distance.
  double rrMultiple;

  PriceActionStrategy({
    required this.id,
    required this.name,
    this.notes = '',
    this.showOnChart = true,
    this.lookbackHours = 24,
    this.allowLong = true,
    this.allowShort = true,
    this.rrMultiple = 2.0,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'notes': notes,
        'showOnChart': showOnChart,
        'lookbackHours': lookbackHours,
        'allowLong': allowLong,
        'allowShort': allowShort,
        'rrMultiple': rrMultiple,
      };

  static PriceActionStrategy? fromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString();
    final name = j['name']?.toString();
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    return PriceActionStrategy(
      id: id,
      name: name,
      notes: j['notes']?.toString() ?? '',
      showOnChart: j['showOnChart'] != false,
      lookbackHours: (j['lookbackHours'] as num?)?.toInt() ?? 24,
      allowLong: j['allowLong'] != false,
      allowShort: j['allowShort'] != false,
      rrMultiple: (j['rrMultiple'] as num?)?.toDouble() ?? 2.0,
    );
  }
}

class StrategyStore {
  static const _key = 'sona_strategies_v1';

  static Future<List<PriceActionStrategy>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      return (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(PriceActionStrategy.fromJson)
          .whereType<PriceActionStrategy>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<void> save(List<PriceActionStrategy> strategies) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode(strategies.map((s) => s.toJson()).toList()),
    );
  }
}

/// One completed 1-hour candle derived from finer candles.
class HourBar {
  final DateTime hourStart;
  final double high;
  final double low;
  const HourBar(this.hourStart, this.high, this.low);
}

/// Groups candles (any interval <= 1h) into completed 1-hour bars, aligned
/// to wall-clock hours. The final, possibly still-forming hour is dropped:
/// signals only ever come from CLOSED hours.
List<HourBar> completedHourBars(List<Candle> candles) {
  if (candles.isEmpty) return [];
  final byHour = <int, List<Candle>>{};
  for (final c in candles) {
    final h = DateTime(c.time.year, c.time.month, c.time.day, c.time.hour)
        .millisecondsSinceEpoch;
    byHour.putIfAbsent(h, () => []).add(c);
  }
  final keys = byHour.keys.toList()..sort();
  final out = <HourBar>[];
  for (var i = 0; i < keys.length; i++) {
    final cs = byHour[keys[i]]!;
    // An hour bar is complete when a later hour's candles exist.
    final complete = i < keys.length - 1;
    if (!complete) continue;
    out.add(HourBar(
      DateTime.fromMillisecondsSinceEpoch(keys[i]),
      cs.map((c) => c.high).reduce((a, b) => a > b ? a : b),
      cs.map((c) => c.low).reduce((a, b) => a < b ? a : b),
    ));
  }
  return out;
}

/// One strategy level segment: starts when its hour closes, ends when the
/// level breaks (a candle CLOSE beyond it) or at the data end.
class LevelSegment {
  final double price;
  final bool isHigh;
  final DateTime start;
  DateTime end;
  bool broken;
  LevelSegment(this.price, this.isHigh, this.start, this.end,
      {this.broken = false});
}

/// Chart markers for a strategy: for each of the most recent
/// [strategy.lookbackHours] completed hours, the high and low segments,
/// each ending where a later candle CLOSE broke the level.
List<LevelSegment> strategySegments(
    List<Candle> candles, PriceActionStrategy strategy) {
  final hours = completedHourBars(candles);
  if (hours.isEmpty) return [];
  final recent = hours.length > strategy.lookbackHours
      ? hours.sublist(hours.length - strategy.lookbackHours)
      : hours;
  final firstStart =
      recent.first.hourStart.add(const Duration(hours: 1));
  final segs = <LevelSegment>[];
  final lastTime = candles.last.time;
  for (final h in recent) {
    final start = h.hourStart.add(const Duration(hours: 1));
    for (final isHigh in [true, false]) {
      final price = isHigh ? h.high : h.low;
      final seg = LevelSegment(price, isHigh, start, lastTime);
      for (final c in candles) {
        if (c.time.isBefore(start)) continue;
        final broke = isHigh ? c.close > price : c.close < price;
        if (broke) {
          seg.broken = true;
          seg.end = c.time;
          break;
        }
      }
      segs.add(seg);
    }
  }
  segs.removeWhere((s) => s.end.isBefore(firstStart));
  return segs;
}
