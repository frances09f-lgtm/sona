import 'package:flutter_test/flutter_test.dart';
import 'package:sona/backtest.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/strategy.dart';

Candle c(DateTime t, double o, double h, double l, double cl) =>
    Candle(time: t, open: o, high: h, low: l, close: cl);

/// 15-minute candles for two hours plus a bit: hour 1 ranges 90..110,
/// hour 2 ranges 95..115, then price closes above hour-2 high.
List<Candle> sample() {
  final t0 = DateTime.utc(2026, 10, 20, 9, 0);
  final out = <Candle>[];
  // hour 1: 09:00-09:45, range 90..110
  for (var i = 0; i < 4; i++) {
    out.add(c(t0.add(Duration(minutes: 15 * i)), 100, i == 1 ? 110 : 105,
        i == 2 ? 90 : 95, 100));
  }
  // hour 2: 10:00-10:45, range 95..115
  for (var i = 0; i < 4; i++) {
    out.add(c(t0.add(Duration(hours: 1, minutes: 15 * i)), 105,
        i == 1 ? 115 : 110, i == 2 ? 95 : 100, 105));
  }
  // 11:00 candle closes above hour-2 high (115) -> long entry
  out.add(c(t0.add(const Duration(hours: 2)), 114, 120, 113, 118));
  // 11:15 runs to TP (entry 118, SL 95, TP = 118 + 23*2 = 164) - not hit;
  // instead drops below SL 95 -> stopped out
  out.add(c(t0.add(const Duration(hours: 2, minutes: 15)), 100, 101, 94, 96));
  return out;
}

void main() {
  test('completedHourBars groups into closed wall-clock hours only', () {
    final hours = completedHourBars(sample());
    expect(hours.length, 2);
    expect(hours[0].high, 110);
    expect(hours[0].low, 90);
    expect(hours[1].high, 115);
    expect(hours[1].low, 95);
    expect(hours[0].hourStart.millisecondsSinceEpoch,
      DateTime.utc(2026, 10, 20, 9, 0).millisecondsSinceEpoch);
  });

  test('strategySegments mark every closed hour and stop at the break', () {
    final s = PriceActionStrategy(id: 'a', name: 'T');
    final segs = strategySegments(sample(), s);
    // 2 hours x 2 levels
    expect(segs.length, 4);
    final h1High = segs.firstWhere((x) => x.isHigh && x.price == 110);
    final h2High = segs.firstWhere((x) => x.isHigh && x.price == 115);
    // hour-1 high (110): broken by the 11:00 close at 118
    expect(h1High.broken, isTrue);
    expect(h1High.end, DateTime.utc(2026, 10, 20, 11, 0));
    // hour-2 high (115): also broken by the same close at 118
    expect(h2High.broken, isTrue);
    // lows never broken (no close below them)
    expect(segs.firstWhere((x) => !x.isHigh && x.price == 90).broken, isFalse);
  });

  test('backtest enters long on hour-high break, SL at hour low', () {
    final s = PriceActionStrategy(id: 'a', name: 'T');
    final r = runBacktest(sample(), s);
    expect(r.trades.length, 1);
    final t = r.trades.single;
    expect(t.long, isTrue);
    expect(t.entry, 118); // close of the 11:00 breakout candle
    expect(t.exit, 95); // SL = signal hour low
    expect(t.exitReason, 'SL');
    expect(t.pnlPoints, -23);
    expect(r.netPoints, -23);
  });

  test('TP hits at rrMultiple x risk', () {
    final t0 = DateTime.utc(2026, 10, 20, 9, 0);
    final out = <Candle>[];
    for (var i = 0; i < 4; i++) {
      out.add(c(t0.add(Duration(minutes: 15 * i)), 100, 110, 90, 100));
    }
    for (var i = 0; i < 4; i++) {
      out.add(c(t0.add(Duration(hours: 1, minutes: 15 * i)), 105, 115, 95, 105));
    }
    out.add(c(t0.add(const Duration(hours: 2)), 114, 118, 113, 116)); // long 116
    // SL 95, risk 21, TP = 116 + 42 = 158; 11:15 hits 160
    out.add(c(t0.add(const Duration(hours: 2, minutes: 15)), 130, 160, 129, 150));
    final r = runBacktest(out, PriceActionStrategy(id: 'a', name: 'T'));
    expect(r.trades.single.exitReason, 'TP');
    expect(r.trades.single.exit, 158);
    expect(r.trades.single.pnlPoints, 42);
  });

  test('short side mirrors: close below hour low enters short', () {
    final t0 = DateTime.utc(2026, 10, 20, 9, 0);
    final out = <Candle>[];
    for (var i = 0; i < 4; i++) {
      out.add(c(t0.add(Duration(minutes: 15 * i)), 100, 110, 90, 100));
    }
    for (var i = 0; i < 4; i++) {
      out.add(c(t0.add(Duration(hours: 1, minutes: 15 * i)), 105, 115, 95, 105));
    }
    out.add(c(t0.add(const Duration(hours: 2)), 96, 97, 90, 92)); // short 92
    // SL = hour high 115, risk 23, TP = 92 - 46 = 46; next candle drops to 40
    out.add(c(t0.add(const Duration(hours: 2, minutes: 15)), 80, 85, 40, 50));
    final r = runBacktest(out, PriceActionStrategy(id: 'a', name: 'T'));
    expect(r.trades.single.long, isFalse);
    expect(r.trades.single.exitReason, 'TP');
    expect(r.trades.single.pnlPoints, 46);
  });

  test('one trade at a time and open trade closes at end of data', () {
    final t0 = DateTime.utc(2026, 10, 20, 9, 0);
    final out = <Candle>[];
    for (var i = 0; i < 4; i++) {
      out.add(c(t0.add(Duration(minutes: 15 * i)), 100, 110, 90, 100));
    }
    for (var i = 0; i < 4; i++) {
      out.add(c(t0.add(Duration(hours: 1, minutes: 15 * i)), 105, 115, 95, 105));
    }
    out.add(c(t0.add(const Duration(hours: 2)), 114, 118, 113, 116));
    out.add(c(t0.add(const Duration(hours: 2, minutes: 15)), 116, 119, 114, 117));
    final r = runBacktest(out, PriceActionStrategy(id: 'a', name: 'T'));
    expect(r.trades.single.exitReason, 'end of data');
    expect(r.trades.single.exit, 117);
  });

  group('BacktestResult stats', () {
    BacktestTrade tr(double entry, double exit, bool long) => BacktestTrade(
        long: long,
        entryTime: DateTime.utc(2026, 10, 20, 9),
        entry: entry,
        exitTime: DateTime.utc(2026, 10, 20, 10),
        exit: exit,
        exitReason: 'TP');
    BacktestResult res(List<BacktestTrade> ts) =>
        BacktestResult(ts, DateTime.utc(2026, 10, 20), DateTime.utc(2026, 10, 21));

    test('profitFactor divides gross wins by gross losses', () {
      // +20 and +10 win, 15 loss -> 30 / 15 = 2.0
      final r = res([tr(100, 120, true), tr(100, 110, true), tr(100, 85, true)]);
      expect(r.profitFactor, closeTo(2.0, 1e-9));
    });

    test('profitFactor is null with no losing trades', () {
      expect(res([tr(100, 120, true)]).profitFactor, isNull);
      expect(res(const []).profitFactor, isNull);
    });

    test('maxDrawdownPoints is the deepest peak-to-trough drop', () {
      // equity: +10 -> 10 (peak), -25 -> -15 (dd 25), +5 -> -10 (dd 20)
      final r = res([tr(100, 110, true), tr(100, 75, true), tr(100, 105, true)]);
      expect(r.maxDrawdownPoints, closeTo(25.0, 1e-9));
    });

    test('maxDrawdownPoints is 0 for a monotone winner and no trades', () {
      expect(res([tr(100, 110, true), tr(100, 120, true)]).maxDrawdownPoints, 0);
      expect(res(const []).maxDrawdownPoints, 0);
    });
  });
}
