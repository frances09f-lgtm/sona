import 'market_data/models.dart';

/// Bar Replay: practice paper trading over historical candles.
///
/// The controller is pure Dart: the UI slices `candles[0..index)` for the
/// chart, calls [step] to reveal the next bar, and routes orders here.
/// Replay positions are LOCAL to the replay session: they never touch the
/// real paper account, the execution ledger, or the backend.
class ReplayPosition {
  final bool buy;
  final double entry;
  final double size; // units (oz of gold)
  final double? stop;
  final double? target;
  final DateTime entryTime;

  const ReplayPosition({
    required this.buy,
    required this.entry,
    required this.size,
    required this.entryTime,
    this.stop,
    this.target,
  });

  double unrealized(double price) =>
      (price - entry) * (buy ? 1 : -1) * size;
}

class ReplayTrade {
  final bool buy;
  final double entry;
  final double exit;
  final double size;
  final DateTime entryTime;
  final DateTime exitTime;
  final String reason; // 'manual', 'SL', 'TP', 'end of data'

  const ReplayTrade({
    required this.buy,
    required this.entry,
    required this.exit,
    required this.size,
    required this.entryTime,
    required this.exitTime,
    required this.reason,
  });

  double get pnl => (exit - entry) * (buy ? 1 : -1) * size;
}

class ReplayEvent {
  final String kind; // 'bar', 'close', 'end'
  final String detail;
  const ReplayEvent(this.kind, this.detail);
}

class ReplayController {
  final List<Candle> candles; // full snapshot; only [0, index) is visible
  int index; // count of visible candles (>= 1)
  double balance;
  double startBalance;
  final List<ReplayPosition> open = [];
  final List<ReplayTrade> closed = [];

  ReplayController(this.candles, {int? startIndex, this.balance = 10000})
      : index = (startIndex ?? candles.length).clamp(1, candles.length),
        startBalance = balance;

  /// The practice price: close of the last visible bar. Orders fill at this
  /// price (bar-close fills - no intra-bar tick simulation).
  double get price => candles[index - 1].close;
  DateTime get time => candles[index - 1].time;
  bool get atEnd => index >= candles.length;
  double get progress => candles.isEmpty ? 0 : index / candles.length;

  double get equity =>
      balance + open.fold(0.0, (s, p) => s + p.unrealized(price));
  double get realizedPnl => closed.fold(0.0, (s, t) => s + t.pnl);

  String? openMarket(bool buy, {double size = 1, double? sl, double? tp}) {
    if (atEnd) return 'Replay finished - exit or restart.';
    if (size <= 0) return 'Size must be positive.';
    open.add(
      ReplayPosition(
        buy: buy,
        entry: price,
        size: size,
        entryTime: time,
        stop: sl,
        target: tp,
      ),
    );
    return null;
  }

  /// Close one open position at the current bar close.
  String? closePosition(int i, {String reason = 'manual'}) {
    if (i < 0 || i >= open.length) return 'No such position.';
    final p = open.removeAt(i);
    final t = ReplayTrade(
      buy: p.buy,
      entry: p.entry,
      exit: price,
      size: p.size,
      entryTime: p.entryTime,
      exitTime: time,
      reason: reason,
    );
    closed.add(t);
    balance += t.pnl;
    return null;
  }

  void closeAll({String reason = 'manual'}) {
    while (open.isNotEmpty) {
      closePosition(0, reason: reason);
    }
  }

  /// Reveal the next bar. Open positions are checked against the new bar's
  /// range; when BOTH stop and target sit inside one bar the stop is taken
  /// first (conservative - the intra-bar path is unknowable).
  List<ReplayEvent> step() {
    if (atEnd) return [const ReplayEvent('end', 'No more bars')];
    final bar = candles[index];
    index++;
    final events = <ReplayEvent>[ReplayEvent('bar', 'Advanced to ${bar.time}')];
    for (var i = open.length - 1; i >= 0; i--) {
      final p = open[i];
      if (p.buy) {
        final slHit = p.stop != null && bar.low <= p.stop!;
        final tpHit = p.target != null && bar.high >= p.target!;
        if (slHit) {
          _closeAtPrice(i, p.stop!, 'SL');
        } else if (tpHit) {
          _closeAtPrice(i, p.target!, 'TP');
        }
      } else {
        final slHit = p.stop != null && bar.high >= p.stop!;
        final tpHit = p.target != null && bar.low <= p.target!;
        if (slHit) {
          _closeAtPrice(i, p.stop!, 'SL');
        } else if (tpHit) {
          _closeAtPrice(i, p.target!, 'TP');
        }
      }
    }
    return events;
  }

  void _closeAtPrice(int i, double exit, String reason) {
    final p = open.removeAt(i);
    final t = ReplayTrade(
      buy: p.buy,
      entry: p.entry,
      exit: exit,
      size: p.size,
      entryTime: p.entryTime,
      exitTime: time,
      reason: reason,
    );
    closed.add(t);
    balance += t.pnl;
  }

  /// End-of-data settlement: everything still open closes at the last close.
  void settle() => closeAll(reason: 'end of data');
}
