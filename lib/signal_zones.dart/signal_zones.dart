library;

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'market_data/models.dart';

/// Automatic chart signal boxes (user request Nov 13): the app draws BUY
/// boxes at strong support and SELL boxes at strong resistance found in the
/// real chart candles, searches a FRESH setup after a level breaks (a box
/// never flips direction), and keeps a daily correct/wrong count.
///
/// Counting rule (approved by the user on WhatsApp, Nov 13):
///   - a box can win or lose only after price first ENTERS its range;
///     moves before that touch never count
///   - BUY: correct at $3.00 above the box top, wrong at $1.50 below the
///     box bottom; SELL mirrored; whichever is hit first decides
///   - when the data cannot prove which came first (the touch candle also
///     reaches a scoring boundary, or one candle spans both), the signal is
///     UNCLEAR and is not counted either way
///   - no decision within 4 hours of the touch: expired, not counted
///   - a box still untouched 4 hours after being drawn: expired, not
///     counted
///   - each box counts once, on the IST day it was decided, and its record
///     is never edited afterwards
///
/// This counts price reactions at the level, NOT trading profit.

const double kSignalTargetOffset = 3.0;
const double kSignalInvalidationOffset = 1.5;
const Duration kSignalExpiry = Duration(hours: 4);

/// A drawn zone is level +/- this much (total height $1.50).
const double kZoneHalfHeight = 0.75;

enum SignalBoxState { pending, active, correct, wrong, unclear, expired }

class SignalBox {
  final String id;
  final bool isBuy;
  final double low;
  final double high;
  final int createdAtMs;
  final SignalBoxState state;
  final int? touchedAtMs;
  final int? decidedAtMs;

  /// Cursor for candle catch-up: bars at or before this time were already
  /// considered, so history is never re-scored.
  final int evaluatedUpToMs;

  const SignalBox({
    required this.id,
    required this.isBuy,
    required this.low,
    required this.high,
    required this.createdAtMs,
    required this.state,
    this.touchedAtMs,
    this.decidedAtMs,
    required this.evaluatedUpToMs,
  });

  double get target =>
      isBuy ? high + kSignalTargetOffset : low - kSignalTargetOffset;
  double get invalidation =>
      isBuy ? low - kSignalInvalidationOffset : high + kSignalInvalidationOffset;

  bool get decided =>
      state == SignalBoxState.correct ||
      state == SignalBoxState.wrong ||
      state == SignalBoxState.unclear ||
      state == SignalBoxState.expired;

  bool get countsCorrect => state == SignalBoxState.correct;
  bool get countsWrong => state == SignalBoxState.wrong;

  SignalBox copyWith({
    SignalBoxState? state,
    int? touchedAtMs,
    int? decidedAtMs,
    int? evaluatedUpToMs,
  }) =>
      SignalBox(
        id: id,
        isBuy: isBuy,
        low: low,
        high: high,
        createdAtMs: createdAtMs,
        state: state ?? this.state,
        touchedAtMs: touchedAtMs ?? this.touchedAtMs,
        decidedAtMs: decidedAtMs ?? this.decidedAtMs,
        evaluatedUpToMs: evaluatedUpToMs ?? this.evaluatedUpToMs,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'isBuy': isBuy,
        'low': low,
        'high': high,
        'createdAtMs': createdAtMs,
        'state': state.name,
        'touchedAtMs': touchedAtMs,
        'decidedAtMs': decidedAtMs,
        'evaluatedUpToMs': evaluatedUpToMs,
      };

  static SignalBox? fromJson(Map<String, dynamic> j) {
    final id = j['id']?.toString();
    final low = (j['low'] as num?)?.toDouble();
    final high = (j['high'] as num?)?.toDouble();
    final created = (j['createdAtMs'] as num?)?.toInt();
    final stateName = j['state']?.toString();
    final state = SignalBoxState.values
        .where((s) => s.name == stateName)
        .firstOrNull;
    if (id == null ||
        id.isEmpty ||
        low == null ||
        high == null ||
        created == null ||
        state == null) {
      return null;
    }
    return SignalBox(
      id: id,
      isBuy: j['isBuy'] == true,
      low: low,
      high: high,
      createdAtMs: created,
      state: state,
      touchedAtMs: (j['touchedAtMs'] as num?)?.toInt(),
      decidedAtMs: (j['decidedAtMs'] as num?)?.toInt(),
      evaluatedUpToMs:
          (j['evaluatedUpToMs'] as num?)?.toInt() ?? created,
    );
  }
}

/// IST calendar day (yyyy-mm-dd) for a millisecond timestamp. The daily
/// counter attributes an outcome to the IST day it was decided on.
String istDay(int ms) {
  final ist = DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true)
      .add(const Duration(hours: 5, minutes: 30));
  final m = ist.month.toString().padLeft(2, '0');
  final d = ist.day.toString().padLeft(2, '0');
  return '${ist.year}-$m-$d';
}

/// One chronological tick: exact ordering, so no OHLC ambiguity exists.
/// [prevPrice] is the tick immediately before, used to detect gaps that
/// jump over the whole zone (no provable trade inside it).
SignalBox evaluateSignalTick(SignalBox b, int tsMs, double price,
    double? prevPrice) {
  switch (b.state) {
    case SignalBoxState.pending:
      final pendingDeadline =
          b.createdAtMs + kSignalExpiry.inMilliseconds;
      if (tsMs > pendingDeadline) {
        return b.copyWith(
            state: SignalBoxState.expired, decidedAtMs: tsMs);
      }
      final inside = price >= b.low && price <= b.high;
      if (inside) {
        return b.copyWith(
            state: SignalBoxState.active, touchedAtMs: tsMs);
      }
      if (prevPrice != null) {
        final wasAbove = prevPrice > b.high;
        final wasBelow = prevPrice < b.low;
        final nowAbove = price > b.high;
        final nowBelow = price < b.low;
        // A single jump across the whole zone: no tick traded inside it,
        // so the touch (and any outcome) cannot be proven. Not counted.
        if ((wasAbove && nowBelow) || (wasBelow && nowAbove)) {
          return b.copyWith(
              state: SignalBoxState.unclear, decidedAtMs: tsMs);
        }
      }
      return b;
    case SignalBoxState.active:
      final touchedAt = b.touchedAtMs ?? b.createdAtMs;
      final deadline = touchedAt + kSignalExpiry.inMilliseconds;
      if (tsMs > deadline) {
        return b.copyWith(
            state: SignalBoxState.expired, decidedAtMs: tsMs);
      }
      final hitTarget =
          b.isBuy ? price >= b.target : price <= b.target;
      final hitInv =
          b.isBuy ? price <= b.invalidation : price >= b.invalidation;
      // A tick is a single price and target/invalidation are disjoint, so
      // at most one can be hit; when both register (a jump), the ordering
      // is unprovable.
      if (hitTarget && hitInv) {
        return b.copyWith(
            state: SignalBoxState.unclear, decidedAtMs: tsMs);
      }
      if (hitTarget) {
        return b.copyWith(
            state: SignalBoxState.correct, decidedAtMs: tsMs);
      }
      if (hitInv) {
        return b.copyWith(state: SignalBoxState.wrong, decidedAtMs: tsMs);
      }
      return b;
    default:
      return b; // decided records are immutable
  }
}

/// One completed OHLC bar during catch-up. The approved uncertainty
/// handling: if the bar that first enters the zone also reaches either
/// scoring boundary, or any later bar spans both, the outcome cannot be
/// proven from OHLC and the signal is UNCLEAR (recorded, not counted).
SignalBox evaluateSignalCandle(SignalBox b, Candle c) {
  final candleMs = c.time.millisecondsSinceEpoch;
  switch (b.state) {
    case SignalBoxState.pending:
      final pendingDeadline =
          b.createdAtMs + kSignalExpiry.inMilliseconds;
      final enters = c.low <= b.high && c.high >= b.low;
      if (!enters) {
        if (candleMs > pendingDeadline) {
          return b.copyWith(
              state: SignalBoxState.expired,
              decidedAtMs: candleMs,
              evaluatedUpToMs: candleMs);
        }
        return b.copyWith(evaluatedUpToMs: candleMs);
      }
      if (candleMs > pendingDeadline) {
        return b.copyWith(
            state: SignalBoxState.expired,
            decidedAtMs: candleMs,
            evaluatedUpToMs: candleMs);
      }
      final reachesTarget =
          b.isBuy ? c.high >= b.target : c.low <= b.target;
      final reachesInv =
          b.isBuy ? c.low <= b.invalidation : c.high >= b.invalidation;
      if (reachesTarget || reachesInv) {
        // The touch bar reached a scoring boundary: which came first
        // inside the bar is unknowable from OHLC.
        return b.copyWith(
            state: SignalBoxState.unclear,
            decidedAtMs: candleMs,
            evaluatedUpToMs: candleMs);
      }
      return b.copyWith(
          state: SignalBoxState.active,
          touchedAtMs: candleMs,
          evaluatedUpToMs: candleMs);
    case SignalBoxState.active:
      final touchedAt = b.touchedAtMs ?? b.createdAtMs;
      final deadline = touchedAt + kSignalExpiry.inMilliseconds;
      if (candleMs > deadline) {
        return b.copyWith(
            state: SignalBoxState.expired,
            decidedAtMs: candleMs,
            evaluatedUpToMs: candleMs);
      }
      final reachesTarget =
          b.isBuy ? c.high >= b.target : c.low <= b.target;
      final reachesInv =
          b.isBuy ? c.low <= b.invalidation : c.high >= b.invalidation;
      if (reachesTarget && reachesInv) {
        return b.copyWith(
            state: SignalBoxState.unclear,
            decidedAtMs: candleMs,
            evaluatedUpToMs: candleMs);
      }
      if (reachesTarget) {
        return b.copyWith(
            state: SignalBoxState.correct,
            decidedAtMs: candleMs,
            evaluatedUpToMs: candleMs);
      }
      if (reachesInv) {
        return b.copyWith(
            state: SignalBoxState.wrong,
            decidedAtMs: candleMs,
            evaluatedUpToMs: candleMs);
      }
      return b.copyWith(evaluatedUpToMs: candleMs);
    default:
      return b;
  }
}

class DetectedZone {
  final bool isBuy;
  final double level;
  final int strength;
  const DetectedZone(this.isBuy, this.level, this.strength);
  double get low => level - kZoneHalfHeight;
  double get high => level + kZoneHalfHeight;
}

/// Finds the strongest support below and resistance above [price] from
/// swing pivots in [candles] (oldest-first, real chart data only).
///
/// A level is "strong" when its pivot is re-tested: at least
/// [minStrength] bars (including the pivot itself) come within
/// [touchTolerance] of it. Zones whose [minStrength] is not met produce
/// no box at all - nothing is forced.
List<DetectedZone> detectSignalZones(
  List<Candle> candles,
  double price, {
  int lookback = 120,
  int wing = 3,
  double touchTolerance = 1.0,
  int minStrength = 2,
}) {
  if (candles.length < (wing * 2 + 10)) return const [];
  final start =
      candles.length > lookback ? candles.length - lookback : wing;
  final end = candles.length - wing;
  final pivots = <({bool high, double level, int index})>[];
  for (var i = start; i < end; i++) {
    final c = candles[i];
    var swingHigh = true;
    var swingLow = true;
    for (var k = 1; k <= wing; k++) {
      if (candles[i - k].high >= c.high || candles[i + k].high >= c.high) {
        swingHigh = false;
      }
      if (candles[i - k].low <= c.low || candles[i + k].low <= c.low) {
        swingLow = false;
      }
    }
    if (swingHigh) pivots.add((high: true, level: c.high, index: i));
    if (swingLow) pivots.add((high: false, level: c.low, index: i));
  }

  int strengthOf(double level) {
    var n = 0;
    for (final c in candles.sublist(start)) {
      if ((c.high >= level - touchTolerance &&
              c.low <= level + touchTolerance)) {
        n++;
      }
    }
    return n;
  }

  DetectedZone? best(bool wantHigh) {
    final candidates = pivots
        .where((p) =>
            p.high == wantHigh &&
            (wantHigh
                ? p.level - kZoneHalfHeight > price
                : p.level + kZoneHalfHeight < price))
        .map((p) => DetectedZone(!p.high, p.level, strengthOf(p.level)))
        .where((z) => z.strength >= minStrength)
        .toList();
    if (candidates.isEmpty) return null;
    candidates.sort((a, b) {
      final s = b.strength.compareTo(a.strength);
      if (s != 0) return s;
      return (a.level - price).abs().compareTo((b.level - price).abs());
    });
    return candidates.first;
  }

  final out = <DetectedZone>[];
  final support = best(false);
  if (support != null) out.add(support);
  final resistance = best(true);
  if (resistance != null) out.add(resistance);
  return out;
}

/// Holds the full immutable box history, evaluates ticks/candles, searches
/// fresh setups and persists everything to SharedPreferences (device-local,
/// like alerts and drawings).
/// Human-readable zone summary for the Groq prompt (levels + touches).
String describeZone(DetectedZone z) =>
    '${z.low.toStringAsFixed(2)} - ${z.high.toStringAsFixed(2)} '
    '(level ${z.level.toStringAsFixed(1)}, ${z.strength} touches)';

class SignalBoxManager {
  static const _prefsKey = 'sona_signal_boxes_v1';

  final List<SignalBox> boxes = [];
  double? _lastTickPrice;
  int _seq = 0;

  /// Boxes drawn on the chart right now: pending or active, undecided.
  List<SignalBox> get displayBoxes => boxes
      .where((b) =>
          b.state == SignalBoxState.pending ||
          b.state == SignalBoxState.active)
      .toList(growable: false);

  /// (correct, wrong) decided on the IST day containing [nowMs]. Unclear
  /// and expired outcomes stay in history but are never counted.
  (int, int) todayStats(int nowMs) {
    final today = istDay(nowMs);
    var correct = 0;
    var wrong = 0;
    for (final b in boxes) {
      final at = b.decidedAtMs;
      if (at == null || istDay(at) != today) continue;
      if (b.countsCorrect) correct++;
      if (b.countsWrong) wrong++;
    }
    return (correct, wrong);
  }

  /// Show the chip while there is anything to report: a live box or an
  /// outcome counted today.
  bool hasAnythingToday(int nowMs) {
    if (displayBoxes.isNotEmpty) return true;
    final s = todayStats(nowMs);
    return s.$1 > 0 || s.$2 > 0;
  }

  Future<void> load(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsKey);
    if (raw == null) return;
    try {
      final list = (jsonDecode(raw) as List)
          .whereType<Map<String, dynamic>>()
          .map(SignalBox.fromJson)
          .whereType<SignalBox>()
          .toList();
      boxes
        ..clear()
        ..addAll(list);
      _seq = boxes.length;
    } catch (_) {}
  }

  Future<void> save(SharedPreferences prefs) async {
    await prefs.setString(
        _prefsKey, jsonEncode(boxes.map((b) => b.toJson()).toList()));
  }

  /// Live-tick evaluation (1s quote cadence). Returns true when any box
  /// changed, so callers can persist and repaint. Detection does NOT run
  /// here - fresh setups are searched on candle refreshes instead.
  bool onTick(int tsMs, double price) {
    var changed = false;
    for (var i = 0; i < boxes.length; i++) {
      final b = boxes[i];
      if (b.decided) continue;
      final next = evaluateSignalTick(b, tsMs, price, _lastTickPrice);
      if (!identical(next, b) && next != b) {
        boxes[i] = next;
        changed = true;
      }
    }
    _lastTickPrice = price;
    return changed;
  }

  /// Candle refresh evaluation + fresh-setup search. [candles] are the
  /// real chart candles (oldest-first); bars that are still forming are
  /// ignored so a partial bar never decides an outcome.
  /// Returns true when anything changed.
  bool onCandles(List<Candle> candles, double price, int nowMs) {
    if (candles.length < 2) return false;
    var changed = false;

    // Completed bars only: a bar whose close time is still in the future
    // is forming and its extremes are partial.
    final spanMs = (candles[1].time.millisecondsSinceEpoch -
            candles[0].time.millisecondsSinceEpoch)
        .abs();
    final completed = candles
        .where((c) => c.time.millisecondsSinceEpoch + spanMs <= nowMs)
        .toList();

    for (var i = 0; i < boxes.length; i++) {
      var b = boxes[i];
      if (b.decided) continue;
      for (final c in completed) {
        final candleMs = c.time.millisecondsSinceEpoch;
        // Never score a bar from before the box existed or one already
        // evaluated - history is processed once, in order.
        if (candleMs <= b.evaluatedUpToMs) continue;
        b = evaluateSignalCandle(b, c);
        if (b.decided) break;
      }
      if (b != boxes[i]) {
        boxes[i] = b;
        changed = true;
      }
    }

    return changed;
  }

  /// True while a direction slot is free (no live BUY or no live SELL
  /// box) and a fresh setup could be searched.
  bool get needsSetup =>
      !displayBoxes.any((b) => b.isBuy) ||
      !displayBoxes.any((b) => !b.isBuy);

  /// Candidate zones for new boxes: on-device swing S/R detection, only
  /// for free direction slots, skipping any level that overlaps a live box
  /// or one decided within the last expiry window (a just-broken level is
  /// not instantly redrawn as a "new" signal). The caller qualifies these
  /// with the Groq brain before drawing anything.
  List<DetectedZone> candidates(
      List<Candle> candles, double price, int nowMs) {
    final recentCutoff = nowMs - kSignalExpiry.inMilliseconds;
    bool overlapsRecentOrLive(double low, double high) {
      for (final b in boxes) {
        final live = !b.decided;
        final recent = b.decided && (b.decidedAtMs ?? 0) >= recentCutoff;
        if (!live && !recent) continue;
        if (low <= b.high && high >= b.low) return true;
      }
      return false;
    }

    final hasBuy = displayBoxes.any((b) => b.isBuy);
    final hasSell = displayBoxes.any((b) => !b.isBuy);
    final out = <DetectedZone>[];
    for (final z in detectSignalZones(candles, price)) {
      if (z.isBuy && hasBuy) continue;
      if (!z.isBuy && hasSell) continue;
      if (overlapsRecentOrLive(z.low, z.high)) continue;
      out.add(z);
    }
    return out;
  }

  /// Draws a qualified zone as a new pending box.
  void addBox(DetectedZone z, int nowMs) {
    _seq++;
    boxes.add(SignalBox(
      id: 'sz_${nowMs}_$_seq',
      isBuy: z.isBuy,
      low: z.low,
      high: z.high,
      createdAtMs: nowMs,
      state: SignalBoxState.pending,
      evaluatedUpToMs: nowMs,
    ));
  }
}
