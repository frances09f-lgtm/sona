import 'market_data/models.dart';
import 'strategy.dart';

/// Backtest result for one strategy run over historical candles.
/// Display-only: never touches the paper account or the journal.
class BacktestTrade {
  final bool long;
  final DateTime entryTime;
  final double entry;
  final DateTime exitTime;
  final double exit;
  final String exitReason; // 'SL', 'TP' or 'end of data'
  const BacktestTrade({
    required this.long,
    required this.entryTime,
    required this.entry,
    required this.exitTime,
    required this.exit,
    required this.exitReason,
  });
  double get pnlPoints => (exit - entry) * (long ? 1 : -1);
}

class BacktestResult {
  final List<BacktestTrade> trades;
  final DateTime from;
  final DateTime to;
  const BacktestResult(this.trades, this.from, this.to);

  int get wins => trades.where((t) => t.pnlPoints > 0).length;
  int get losses => trades.where((t) => t.pnlPoints <= 0).length;
  double get netPoints =>
      trades.fold(0.0, (a, t) => a + t.pnlPoints);
  double get winRate => trades.isEmpty ? 0 : wins / trades.length;
  List<double> get pnlSeries => trades.map((t) => t.pnlPoints).toList();

  /// Gross winning points divided by gross losing points. Null when there
  /// are no losing trades (or no trades) - shown as a dash, never
  /// "Infinity", so the number is never invented.
  double? get profitFactor {
    var grossWin = 0.0, grossLoss = 0.0;
    for (final t in trades) {
      if (t.pnlPoints > 0) grossWin += t.pnlPoints;
      if (t.pnlPoints < 0) grossLoss -= t.pnlPoints;
    }
    if (grossLoss <= 0) return null;
    return grossWin / grossLoss;
  }

  /// Deepest peak-to-trough drop of the running points total, in points.
  /// 0 when the equity line never dips below a prior peak.
  double get maxDrawdownPoints {
    var peak = 0.0, equity = 0.0, worst = 0.0;
    for (final t in trades) {
      equity += t.pnlPoints;
      if (equity > peak) peak = equity;
      final dd = peak - equity;
      if (dd > worst) worst = dd;
    }
    return worst;
  }
}

/// Runs the "1H high/low break" strategy over [candles] (any interval
/// <= 1h), newest-closed-hour rules:
///
/// - After each 1H candle closes, its high/low become the active levels.
/// - Long entry when a candle CLOSES above the active hour high
///   (short: closes below the active hour low), at that candle's close.
/// - Stop loss at the opposite side of the signal hour candle.
/// - Take profit at [strategy.rrMultiple] x the SL distance.
/// - One position at a time; still-open trades close at the last close.
BacktestResult runBacktest(
    List<Candle> candles, PriceActionStrategy strategy) {
  final trades = <BacktestTrade>[];
  if (candles.length < 3) {
    return BacktestResult(
        trades,
        candles.isEmpty ? DateTime.now() : candles.first.time,
        candles.isEmpty ? DateTime.now() : candles.last.time);
  }
  final hours = completedHourBars(candles);
  if (hours.isEmpty) {
    return BacktestResult(trades, candles.first.time, candles.last.time);
  }
  // Active levels = the most recent hour closed strictly before the candle.
  var hi = 0; // index into hours of the active hour
  BacktestTrade? open;
  double sl = 0, tp = 0;
  double activeHigh = 0, activeLow = 0;

  for (final c in candles) {
    // Advance the active hour: newest hour that closed at or before now.
    while (hi + 1 < hours.length &&
        !hours[hi + 1].hourStart.add(const Duration(hours: 1)).isAfter(c.time)) {
      hi++;
    }
    if (hours[hi].hourStart.add(const Duration(hours: 1)).isAfter(c.time)) {
      continue; // first hour still forming - no levels yet
    }
    activeHigh = hours[hi].high;
    activeLow = hours[hi].low;

    if (open != null) {
      // Conservative same-candle rule: if both SL and TP are inside this
      // candle's range, count it as a stop-loss hit.
      final hitSl = open.long ? c.low <= sl : c.high >= sl;
      final hitTp = open.long ? c.high >= tp : c.low <= tp;
      if (hitSl || hitTp) {
        final stopFirst = hitSl;
        trades.add(BacktestTrade(
          long: open.long,
          entryTime: open.entryTime,
          entry: open.entry,
          exitTime: c.time,
          exit: stopFirst ? sl : tp,
          exitReason: stopFirst ? 'SL' : 'TP',
        ));
        open = null;
        continue;
      }
    } else {
      if (strategy.allowLong && c.close > activeHigh) {
        final entry = c.close;
        sl = hours[hi].low;
        tp = entry + (entry - sl) * strategy.rrMultiple;
        open = BacktestTrade(
            long: true,
            entryTime: c.time,
            entry: entry,
            exitTime: c.time,
            exit: entry,
            exitReason: '');
        continue;
      }
      if (strategy.allowShort && c.close < activeLow) {
        final entry = c.close;
        sl = hours[hi].high;
        tp = entry - (sl - entry) * strategy.rrMultiple;
        open = BacktestTrade(
            long: false,
            entryTime: c.time,
            entry: entry,
            exitTime: c.time,
            exit: entry,
            exitReason: '');
        continue;
      }
    }
  }
  if (open != null) {
    trades.add(BacktestTrade(
      long: open.long,
      entryTime: open.entryTime,
      entry: open.entry,
      exitTime: candles.last.time,
      exit: candles.last.close,
      exitReason: 'end of data',
    ));
  }
  return BacktestResult(trades, candles.first.time, candles.last.time);
}
