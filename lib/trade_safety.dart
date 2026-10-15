/// Shared validation and full-precision calculations for simulated orders.
String? validateProtection(String side, double entry, double? tp, double? sl) {
  if (!['buy', 'sell'].contains(side) || !entry.isFinite || entry <= 0) {
    return 'A valid side and positive entry price are required.';
  }
  for (final value in [tp, sl]) {
    if (value != null && (!value.isFinite || value <= 0)) {
      return 'TP and SL must be finite, positive prices.';
    }
  }
  if (tp != null && (side == 'buy' ? tp <= entry : tp >= entry)) {
    return 'Take profit must be ${side == 'buy' ? 'above' : 'below'} entry.';
  }
  if (sl != null && (side == 'buy' ? sl >= entry : sl <= entry)) {
    return 'Stop loss must be ${side == 'buy' ? 'below' : 'above'} entry.';
  }
  return null;
}

bool freshExecutionQuote(double? bid, double? ask, int at, int now) =>
    bid != null &&
    ask != null &&
    bid.isFinite &&
    ask.isFinite &&
    bid > 0 &&
    ask >= bid &&
    at > 0 &&
    at <= now + 5000 &&
    now - at <= 60000;

String? protectionTrigger(String side, double mark, double? tp, double? sl) {
  if (!mark.isFinite || mark <= 0 || !['buy', 'sell'].contains(side))
    return null;
  // Stop first when corrupt/conflicting limits would trigger both.
  if (sl != null &&
      sl.isFinite &&
      sl > 0 &&
      (side == 'buy' ? mark <= sl : mark >= sl))
    return 'SL hit';
  if (tp != null &&
      tp.isFinite &&
      tp > 0 &&
      (side == 'buy' ? mark >= tp : mark <= tp))
    return 'TP hit';
  return null;
}

double? quantityForRisk(
  double amount,
  String side,
  double entry,
  double? stop,
) {
  if (!amount.isFinite ||
      amount <= 0 ||
      stop == null ||
      validateProtection(side, entry, null, stop) != null)
    return null;
  final raw = amount / (entry - stop).abs();
  if (!raw.isFinite || raw <= 0 || raw > 100000000) return null;
  // Round down, never silently exceed the requested risk by rounding up.
  final quantity = (raw * 1000000).floorToDouble() / 1000000;
  return quantity > 0 ? quantity : null;
}

class OrderPreview {
  final double exposure;
  final double? loss;
  final double? gain;
  OrderPreview(
    String side,
    double entry,
    double qty,
    double? stop,
    double? target,
  ) : exposure = entry * qty,
      loss = stop == null ? null : (entry - stop).abs() * qty,
      gain = target == null ? null : (target - entry).abs() * qty;
  double? get rewardRisk =>
      loss != null && loss! > 0 && gain != null ? gain! / loss! : null;
}
