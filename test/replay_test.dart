import 'package:flutter_test/flutter_test.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/replay.dart';

Candle c(int m, double o, double h, double l, double cl) => Candle(
      time: DateTime.utc(2026, 10, 20, 9).add(Duration(minutes: 15 * m)),
      open: o,
      high: h,
      low: l,
      close: cl,
    );

void main() {
  test('replay reveals bars one at a time and fills at bar close', () {
    final data = [c(0, 100, 105, 98, 102), c(1, 102, 108, 101, 107)];
    final r = ReplayController(data, startIndex: 1);
    expect(r.price, 102);
    expect(r.atEnd, isFalse);
    r.openMarket(true);
    expect(r.open.single.entry, 102);
    r.step();
    expect(r.price, 107);
    expect(r.open.single.unrealized(107), 5);
    expect(r.atEnd, isTrue);
    r.settle();
    expect(r.closed.single.pnl, 5);
    expect(r.balance, 10005);
  });

  test('short sells profit when price falls', () {
    final data = [c(0, 100, 105, 98, 102), c(1, 102, 103, 90, 95)];
    final r = ReplayController(data, startIndex: 1);
    r.openMarket(false, size: 2);
    r.step();
    r.settle();
    expect(r.closed.single.pnl, 14); // (102-95)*2
  });

  test('SL and TP execute at their prices; SL wins when both in one bar', () {
    final data = [
      c(0, 100, 101, 99, 100),
      c(1, 100, 130, 80, 110), // sweeps both SL 90 and TP 120
    ];
    final r = ReplayController(data, startIndex: 1);
    r.openMarket(true, sl: 90, tp: 120);
    r.step();
    expect(r.closed.single.reason, 'SL');
    expect(r.closed.single.exit, 90);
    expect(r.balance, 10000 - 10);
  });

  test('TP fills at target for shorts', () {
    final data = [c(0, 100, 101, 99, 100), c(1, 100, 102, 88, 92)];
    final r = ReplayController(data, startIndex: 1);
    r.openMarket(false, tp: 90, sl: 105);
    r.step();
    expect(r.closed.single.reason, 'TP');
    expect(r.closed.single.exit, 90);
  });

  test('cannot open after the last bar; equity tracks unrealized', () {
    final data = [c(0, 100, 101, 99, 100), c(1, 100, 106, 99, 104)];
    final r = ReplayController(data, startIndex: 1);
    r.openMarket(true);
    r.step();
    expect(r.equity, 10004);
    expect(r.openMarket(true), isNotNull);
    r.step(); // no-op at end
    expect(r.index, 2);
  });

  test('default start reveals the full history', () {
    final data = [c(0, 1, 2, 0, 1), c(1, 1, 2, 0, 1)];
    final r = ReplayController(data);
    expect(r.atEnd, isTrue);
  });
}
