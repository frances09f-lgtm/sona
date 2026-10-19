/// Read paper-position numbers without rewriting server/cache records or guessing
/// a legacy size. Numeric strings are accepted for decimal-valued RPC fields.
double? paperNumber(Object? value) {
  final n = value is num
      ? value.toDouble()
      : value is String
      ? double.tryParse(value.trim())
      : null;
  return n != null && n.isFinite ? n : null;
}

double? paperPositive(Object? value) {
  final n = paperNumber(value);
  return n != null && n > 0 ? n : null;
}

/// Ounces are not dollars: retain small sizes instead of rounding to cents.
/// At least two fractional digits for familiar sizes, up to eight for small
/// fractions; scientific notation keeps even smaller nonzero sizes visible.
String formatOz(Object? value) {
  final n = paperPositive(value);
  if (n == null) return 'Unknown size';
  if (n < .00000001 || n >= 1e12) return n.toStringAsExponential(5);
  var text = n.toStringAsFixed(8);
  while (text.endsWith('0') && text.length - text.indexOf('.') - 1 > 2) {
    text = text.substring(0, text.length - 1);
  }
  return text;
}

/// No invented break-even: a nonzero sub-cent result retains its sign and a
/// truthful bound. Exact zero remains $0.00. Values are never rounded in storage.
String formatPaperMoney(num? value, {bool sign = false}) {
  if (value == null || !value.isFinite) return '-';
  final prefix = value < 0 ? '-' : (sign && value > 0 ? '+' : '');
  if (value != 0 && value.abs() < .01) return '$prefix<\$0.01';
  return '$prefix\$${value.abs().toStringAsFixed(2)}';
}

double? paperPositionPnl(Map<String, dynamic> record, double? mark) {
  final qty = paperPositive(record['qty']);
  final entry = paperPositive(record['entry']);
  final side = record['direction'];
  if (qty == null ||
      entry == null ||
      paperPositive(mark) == null ||
      !['buy', 'sell'].contains(side)) {
    return null;
  }
  final pnl = (mark! - entry) * (side == 'buy' ? 1 : -1) * qty;
  return pnl.isFinite ? pnl : null;
}
