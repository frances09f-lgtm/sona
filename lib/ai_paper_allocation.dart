import 'dart:math' as math;

import 'paper_margin.dart';

/// A paper-only notional allocation. Never multiplies the budget by leverage
/// and never interprets the percentage as the amount to lose at the stop.
class AiPaperAllocation {
  final double quantity, budget, spreadReserve;
  const AiPaperAllocation(this.quantity, this.budget, this.spreadReserve);
}

AiPaperAllocation? sizeAiPaperTrade({
  required double balance,
  required double bid,
  required double ask,
  required double entryPrice,
  required double percent,
  required List<Map<String, dynamic>> positions,
  double fixedCosts = 0,
  double extraCostPerOz = 0,
}) {
  if (![
        balance,
        bid,
        ask,
        entryPrice,
        percent,
        fixedCosts,
        extraCostPerOz,
      ].every((v) => v.isFinite) ||
      balance <= 0 ||
      bid <= 0 ||
      ask < bid ||
      entryPrice <= 0 ||
      percent <= 0 ||
      percent > 100 ||
      fixedCosts < 0 ||
      extraCostPerOz < 0 ||
      positions.any((p) => p['status'] == 'open')) {
    return null;
  }
  // Preserve the existing one-open-position AI rail. Do not use borrowed
  // margin capacity to turn "100%" into 500x notional exposure.
  final free = PaperMargin.estimate(
    balance: balance,
    bid: bid,
    ask: ask,
    positions: positions,
  );
  if (free == null || !free.isFinite || free <= 0) return null;
  final budget = math.min(balance, free) * percent / 100;
  if (budget <= fixedCosts) return null;
  // Ask is the conservative notional price for both sides. Reserve the
  // current spread and configured extra fill costs inside the budget.
  // This is a sizing cushion, NOT an extra charge/subtraction from PnL.
  final spread = ask - bid;
  final price = math.max(entryPrice, ask);
  final perOz = price + spread + extraCostPerOz;
  final quantity = (budget - fixedCosts) / perOz;
  if (!quantity.isFinite ||
      quantity <= 0 ||
      PaperMargin.guard(free: free, price: price, qty: quantity) != null) {
    return null;
  }
  return AiPaperAllocation(quantity, budget, quantity * spread);
}

/// Only a server-declared quantity minimum is translated. No minimum is
/// inferred from a tiny balance, and rejected allocations are never enlarged.
String? fullBalanceMinimumRejection(String message) {
  final text = message.toLowerCase();
  if ((text.contains('minimum') || text.contains('min_qty')) &&
      (text.contains('quantity') ||
          text.contains('size') ||
          text.contains('oz') ||
          text.contains('min_qty'))) {
    return 'Skipped: the paper backend rejected the budgeted size at its minimum quantity. Available cash cannot cover that minimum without exceeding this allocation. Size was not increased; no fallback order submitted.';
  }
  return null;
}
