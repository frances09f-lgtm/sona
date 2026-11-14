import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Result of one pending-order submission attempt.
///
/// The distinction matters: [SubmitRetry] means the order was DEFINITELY
/// never submitted (a local pre-submit check failed), so leaving it pending
/// and trying again cannot create a duplicate position. [SubmitUnknown]
/// means the request may have reached the server - never retry those.
sealed class SubmitResult {
  const SubmitResult();
}

class SubmitFilled extends SubmitResult {
  const SubmitFilled();
}

class SubmitRetry extends SubmitResult {
  final String reason;
  const SubmitRetry(this.reason);
}

class SubmitUnknown extends SubmitResult {
  final String note;
  const SubmitUnknown(this.note);
}

/// Note prefixes that only a definitive pre-submit rejection can produce
/// (see AppState.openPaperDetailed in main.dart - keep in sync). A stuck
/// 'needsReview' order carrying one of these was never submitted, so it is
/// safe to move back to 'pending'; any other note means the outcome is
/// genuinely unknown and the order stays untouched.
const knownPreSubmitNotePrefixes = [
  'Estimated paper margin insufficient',
  'Cannot estimate paper margin',
  'Another paper order is being checked',
  'Could not refresh the paper account',
  'No fresh live price',
  'No fresh live bid/ask',
  'Paper account not connected',
  'Sona was locked or the account changed',
  'Market closed for the weekend',
  'Market on its daily 1-hour break',
];

bool isKnownPreSubmitNote(String? note) {
  if (note == null) return false;
  if (note.contains('new trades blocked (Daily limits)')) return true;
  return knownPreSubmitNotePrefixes.any((p) => note.startsWith(p));
}

class PendingPaperOrder {
  final String id, side;
  final double qty, trigger;
  final bool above, gtc;
  final double? tp, sl;
  final int createdAt, expiresAt;
  String status;
  String? note;

  /// Last submission-attempt time (evaluator clock). Backs off retries of
  /// definitive pre-submit rejections so a waiting order is not submitted
  /// on every quote tick.
  int? lastAttemptAt;
  PendingPaperOrder({
    required this.id,
    required this.side,
    required this.qty,
    required this.trigger,
    required this.above,
    required this.gtc,
    required this.createdAt,
    required this.expiresAt,
    this.tp,
    this.sl,
    this.status = 'pending',
    this.note,
    this.lastAttemptAt,
  });
  bool matches(double quote, int now) =>
      status == 'pending' &&
      (gtc || now < expiresAt) &&
      (above ? quote >= trigger : quote <= trigger);
  Map<String, dynamic> toJson() => {
    'id': id,
    'side': side,
    'qty': qty,
    'trigger': trigger,
    'above': above,
    'gtc': gtc,
    'createdAt': createdAt,
    'expiresAt': expiresAt,
    'tp': tp,
    'sl': sl,
    'status': status,
    'note': note,
    'lastAttemptAt': lastAttemptAt,
  };
  factory PendingPaperOrder.fromJson(Map j) => PendingPaperOrder(
    id: j['id'],
    side: j['side'],
    qty: (j['qty'] as num).toDouble(),
    trigger: (j['trigger'] as num).toDouble(),
    above: j['above'],
    gtc: j['gtc'],
    createdAt: j['createdAt'],
    expiresAt: j['expiresAt'],
    tp: (j['tp'] as num?)?.toDouble(),
    sl: (j['sl'] as num?)?.toDouble(),
    status: j['status'],
    note: j['note'],
    lastAttemptAt: (j['lastAttemptAt'] as num?)?.toInt(),
  );
}

class PendingPaperOrders {
  static const key = 'oro_pending_paper_orders';
  final SharedPreferences prefs;
  final List<PendingPaperOrder> orders;
  bool evaluating = false;
  PendingPaperOrders(this.prefs, this.orders);
  static PendingPaperOrders load(SharedPreferences prefs) {
    final out = <PendingPaperOrder>[];
    try {
      for (final j in jsonDecode(prefs.getString(key) ?? '[]') as List) {
        final o = PendingPaperOrder.fromJson(j as Map);
        if (o.status == 'submitting') {
          o.status = 'needsReview';
          o.note = 'App stopped during submission. Check positions before placing another order.';
        } else if (o.status == 'needsReview' && isKnownPreSubmitNote(o.note)) {
          // Recovery: older versions knocked orders out permanently for
          // rejections that definitely happened BEFORE anything was sent
          // (margin estimate, busy flag, stale quote). Those orders were
          // never submitted, so waiting again is safe and cannot duplicate
          // a position. The note stays visible under the waiting status.
          o.status = 'pending';
        }
        out.add(o);
      }
    } catch (_) {}
    return PendingPaperOrders(prefs, out);
  }

  Future<void> save() async {
    final saved = await prefs.setString(
      key,
      jsonEncode(orders.map((o) => o.toJson()).toList()),
    );
    if (!saved) throw StateError('Pending order storage failed');
  }

  Future<void> cancel(String id) async {
    final o = orders.firstWhere((o) => o.id == id);
    if (o.status == 'pending') {
      o.status = 'cancelled';
      await save();
    }
  }

  /// Delete an unsubmitted order, a cancelled record, or a terminal record
  /// (filled/expired) whose outcome already lives elsewhere: a fill opened
  /// its position in the portfolio, an expiry changed nothing. Submitting
  /// and unknown-state records stay undeletable so an uncertain submission
  /// is never lost track of. Mark the object first so an evaluator snapshot
  /// cannot submit it later.
  Future<bool> remove(String id) async {
    final index = orders.indexWhere((o) => o.id == id);
    if (index < 0) return false;
    final o = orders[index];
    if (o.status != 'pending' &&
        o.status != 'cancelled' &&
        o.status != 'filled' &&
        o.status != 'expired') return false;
    final previous = o.status;
    o.status = 'removed';
    orders.removeAt(index);
    try {
      await save();
    } catch (_) {
      o.status = previous;
      orders.insert(index.clamp(0, orders.length), o);
      rethrow;
    }
    return true;
  }

  /// Minimum time between submission attempts for one order. Only applies
  /// after a definitive pre-submit rejection ([SubmitRetry]); the first
  /// attempt and real fills are never delayed.
  static const retryBackoffMs = 15000;

  Future<void> evaluate({
    required double bid,
    required double ask,
    required bool fresh,
    required bool active,
    required int now,
    required Future<SubmitResult> Function(PendingPaperOrder) submit,
  }) async {
    if (evaluating || !fresh || !active || !bid.isFinite || !ask.isFinite)
      return;
    evaluating = true;
    try {
      for (final o in List<PendingPaperOrder>.of(orders)) {
        if (o.status != 'pending') continue;
        if (!o.gtc && now >= o.expiresAt) {
          o.status = 'expired';
          await save();
          continue;
        }
        if (!o.matches(o.side == 'buy' ? ask : bid, now)) continue;
        final last = o.lastAttemptAt;
        if (last != null && now - last >= 0 && now - last < retryBackoffMs) {
          continue;
        }
        o.status = 'submitting';
        o.lastAttemptAt = now;
        await save();
        try {
          final result = await submit(o);
          switch (result) {
            case SubmitFilled():
              o.status = 'filled';
              o.note = null;
            case SubmitRetry(:final reason):
              // Definitely never submitted: keep waiting and show why, so
              // the order can fill once the blocker (margin, busy order,
              // stale quote) clears. No duplicate-position risk.
              o.status = 'pending';
              o.note = reason;
            case SubmitUnknown(:final note):
              o.status = 'needsReview';
              o.note = note;
          }
        } catch (_) {
          o.status = 'needsReview';
          o.note = 'Submission outcome unknown. Check positions. No automatic retry.';
        }
        await save();
      }
    } finally {
      evaluating = false;
    }
  }
}
