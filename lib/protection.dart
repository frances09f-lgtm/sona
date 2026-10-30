import 'dart:math' as math;

import 'package:shared_preferences/shared_preferences.dart';

/// How Sona sizes the stop loss for trades it places itself (AI auto-trade
/// and a "sure" Advice trade). Manual tickets always use the prices the
/// user types.
enum StopMode {
  /// Stop = ATR multiple x ATR(14) of the 15-minute candles the AI reads.
  atr,

  /// Stop = a fixed percent of the entry price.
  percent,
}

/// User-editable SL/TP rules (Settings > Stop loss & take profit).
///
/// v1.2.12 (user report "Sona is placing sl and tp too high"): the old
/// rule floored every stop at 0.3% of price and defaulted to 0.6% - on
/// gold at 4,038 that is $12-24 of stop and $18-36 of target, 2-4x a
/// 15-minute ATR of $6-8. Defaults below keep the stop near one candle
/// range: 1.2x ATR, never beyond 0.5% of price, TP at 1.5R.
class ProtectionSettings {
  final StopMode mode;

  /// Stop distance in ATRs (ATR mode). 1.0-1.5 is a normal intraday stop.
  final double atrMultiple;

  /// Stop distance as % of entry (percent mode, and the fallback when
  /// there are too few candles for an ATR).
  final double stopPct;

  /// Hard cap on the stop distance as % of entry, whatever the mode.
  final double maxStopPct;

  /// Take profit = riskReward x the stop distance.
  final double riskReward;

  /// Use a tighter stop the AI picked at a chart level (between half an ATR
  /// and the rule above) instead of the rule distance.
  final bool useAiStop;

  const ProtectionSettings({
    this.mode = StopMode.atr,
    this.atrMultiple = 1.2,
    this.stopPct = 0.25,
    this.maxStopPct = 0.5,
    this.riskReward = 1.5,
    this.useAiStop = true,
  });

  static const defaults = ProtectionSettings();

  // Allowed ranges - also used by the settings editor.
  static const atrMultipleRange = (0.5, 3.0);
  static const stopPctRange = (0.05, 2.0);
  static const maxStopPctRange = (0.1, 3.0);
  static const riskRewardRange = (0.5, 5.0);

  static double _clamp(double? v, (double, double) r, double fallback) {
    if (v == null || !v.isFinite) return fallback;
    return v.clamp(r.$1, r.$2).toDouble();
  }

  /// Returns a copy with every number inside its allowed range.
  ProtectionSettings sanitized() => ProtectionSettings(
    mode: mode,
    atrMultiple: _clamp(atrMultiple, atrMultipleRange, defaults.atrMultiple),
    stopPct: _clamp(stopPct, stopPctRange, defaults.stopPct),
    maxStopPct: _clamp(maxStopPct, maxStopPctRange, defaults.maxStopPct),
    riskReward: _clamp(riskReward, riskRewardRange, defaults.riskReward),
    useAiStop: useAiStop,
  );

  ProtectionSettings copyWith({
    StopMode? mode,
    double? atrMultiple,
    double? stopPct,
    double? maxStopPct,
    double? riskReward,
    bool? useAiStop,
  }) => ProtectionSettings(
    mode: mode ?? this.mode,
    atrMultiple: atrMultiple ?? this.atrMultiple,
    stopPct: stopPct ?? this.stopPct,
    maxStopPct: maxStopPct ?? this.maxStopPct,
    riskReward: riskReward ?? this.riskReward,
    useAiStop: useAiStop ?? this.useAiStop,
  );

  static const _kMode = 'sona_prot_mode';
  static const _kAtr = 'sona_prot_atr_mult';
  static const _kPct = 'sona_prot_stop_pct';
  static const _kMax = 'sona_prot_max_stop_pct';
  static const _kRr = 'sona_prot_rr';
  static const _kAi = 'sona_prot_use_ai_stop';

  /// Background-safe (shared_preferences only).
  static ProtectionSettings read(SharedPreferences prefs) => ProtectionSettings(
    mode: prefs.getString(_kMode) == 'percent' ? StopMode.percent : StopMode.atr,
    atrMultiple: prefs.getDouble(_kAtr) ?? defaults.atrMultiple,
    stopPct: prefs.getDouble(_kPct) ?? defaults.stopPct,
    maxStopPct: prefs.getDouble(_kMax) ?? defaults.maxStopPct,
    riskReward: prefs.getDouble(_kRr) ?? defaults.riskReward,
    useAiStop: prefs.getBool(_kAi) ?? defaults.useAiStop,
  ).sanitized();

  static Future<ProtectionSettings> load() async {
    try {
      return read(await SharedPreferences.getInstance());
    } catch (_) {
      return defaults; // no prefs plugin (tests) - defaults
    }
  }

  Future<void> save(SharedPreferences prefs) async {
    final s = sanitized();
    await prefs.setString(_kMode, s.mode == StopMode.percent ? 'percent' : 'atr');
    await prefs.setDouble(_kAtr, s.atrMultiple);
    await prefs.setDouble(_kPct, s.stopPct);
    await prefs.setDouble(_kMax, s.maxStopPct);
    await prefs.setDouble(_kRr, s.riskReward);
    await prefs.setBool(_kAi, s.useAiStop);
  }

  /// One-line summary for Settings and the AI log.
  String describe() {
    final m = mode == StopMode.atr
        ? 'SL ${_n(atrMultiple)}x ATR(15m)'
        : 'SL ${_n(stopPct)}% of price';
    return '$m, max ${_n(maxStopPct)}% · TP ${_n(riskReward)}R';
  }

  static String _n(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2).replaceFirst(RegExp(r'0$'), '');
}

/// Stop/target prices for one trade.
class Protection {
  final double sl;
  final double tp;

  /// Stop distance actually used (price units).
  final double risk;

  /// Where the stop distance came from: 'atr', 'percent', 'ai' (the AI's
  /// own chart level, accepted because it was within the rule), plus
  /// '+cap' when the max-% cap shortened it.
  final String source;
  const Protection(this.sl, this.tp, this.risk, this.source);
}

/// Price step for rounding SL/TP. Sona trades XAU/USD (0.01); the others
/// are here so the rule is correct for any symbol it might show later.
double tickSizeFor(String symbol, {double? price}) {
  final s = symbol.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  if (s.startsWith('XAU') || s.startsWith('GOLD')) return 0.01;
  if (s.startsWith('XAG') || s.startsWith('SILVER')) return 0.001;
  if (s.length == 6 && RegExp(r'^[A-Z]{6}$').hasMatch(s)) {
    return s.endsWith('JPY') ? 0.001 : 0.00001; // forex: 5-digit pricing
  }
  if (price != null && price > 0) {
    if (price >= 1000) return 0.1; // indices (US30, NAS100, GER40...)
    if (price >= 10) return 0.01;
    return 0.0001;
  }
  return 0.01;
}

double _roundToTick(double v, double tick) {
  if (tick <= 0) return v;
  final r = (v / tick).round() * tick;
  // Kill float noise (4038.1200000001) by rounding to the tick's decimals.
  final decimals = math.max(0, (-math.log(tick) / math.ln10).ceil());
  return double.parse(r.toStringAsFixed(decimals));
}

/// SL/TP for a market trade at [entry] (a real side price: ask for a buy,
/// bid for a sell).
///
/// - Stop distance: [settings] rule (ATR multiple x [atr], or % of entry;
///   % is also the fallback when [atr] is unknown), capped at
///   maxStopPct of entry.
/// - An [aiStop] on the correct side is used instead when it is TIGHTER
///   than the rule but at least half an ATR (or a quarter of the rule
///   distance without ATR) away - a stop just past a chart level. A wider
///   AI stop never widens the trade.
/// - TP = riskReward x the stop distance, on the profit side.
/// - Buy: SL below entry, TP above. Sell: SL above entry, TP below.
/// - Prices rounded to [tick] without crossing the entry.
Protection computeProtection({
  required bool buy,
  required double entry,
  double? atr,
  double? aiStop,
  ProtectionSettings settings = ProtectionSettings.defaults,
  double tick = 0.01,
}) {
  if (!entry.isFinite || entry <= 0) {
    throw ArgumentError.value(entry, 'entry', 'must be a positive price');
  }
  final s = settings.sanitized();
  final atrOk = atr != null && atr.isFinite && atr > 0;
  var source = 'percent';
  double dist;
  if (s.mode == StopMode.atr && atrOk) {
    // Sanity floor (from the Instinct ATR-band work): a near-zero ATR from
    // a frozen feed never yields a stop inside the spread - at least 0.02%
    // of price ($0.80 on gold at 4,000).
    dist = math.max(s.atrMultiple * atr, entry * 0.0002);
    source = 'atr';
  } else {
    dist = entry * s.stopPct / 100;
  }
  final minDist = atrOk ? 0.5 * atr : dist * 0.25;
  if (s.useAiStop && aiStop != null && aiStop.isFinite && aiStop > 0) {
    final aiDist = buy ? entry - aiStop : aiStop - entry; // >0 = right side
    if (aiDist > 0 && aiDist < dist && aiDist >= minDist) {
      dist = aiDist;
      source = 'ai';
    }
  }
  final cap = entry * s.maxStopPct / 100;
  if (dist > cap) {
    dist = cap;
    source = '$source+cap';
  }
  // Never closer than 2 ticks.
  dist = math.max(dist, 2 * tick);
  final dir = buy ? 1.0 : -1.0;
  var sl = _roundToTick(entry - dir * dist, tick);
  var tp = _roundToTick(entry + dir * dist * s.riskReward, tick);
  // Rounding must never put a level on the wrong side of entry.
  if (buy ? sl >= entry : sl <= entry) sl = _roundToTick(entry - dir * tick, tick);
  if (buy ? tp <= entry : tp >= entry) tp = _roundToTick(entry + dir * tick, tick);
  return Protection(sl, tp, (entry - sl).abs(), source);
}
