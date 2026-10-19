import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/market_data/models.dart';

void main() {
  test('range spec maps durations to real provider intervals', () {
    expect(tradeRangeSpec('range:1H'), ('1min', 120));
    expect(tradeRangeSpec('range:1Y'), ('1day', 400));
    final end = DateTime(2026, 10, 8);
    final data = List.generate(
      400,
      (i) => Candle(
        time: end.subtract(Duration(days: 399 - i)),
        open: 100,
        high: 101,
        low: 99,
        close: 100,
      ),
    );
    expect(trimTradeRange(data, 'range:1W').length, 8);
    expect(trimTradeRange(data, 'range:1Y').length, 366);
  });
  testWidgets(
    'range selector reloads actual range and never calls interval alias',
    (t) async {
      final calls = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 550,
              child: CandleChartPanel(
                rangeMode: true,
                loader: (c) async {
                  calls.add(c);
                  return [];
                },
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(calls, ['range:1D']);
      // Interval/range selection now lives in Settings; drive it through the
      // same public entry point Settings uses.
      final state = t.state<CandleChartPanelState>(
        find.byType(CandleChartPanel),
      );
      state.applyChartSelection(range: true, code: 'range:1M');
      await t.pumpAndSettle();
      expect(calls.last, 'range:1M');
      state.applyChartSelection(range: false, code: '1min');
      await t.pumpAndSettle();
      expect(calls.last, '1min');
      expect(t.takeException(), isNull);
    },
  );
  testWidgets('old failed range request cannot overwrite newer chart', (
    t,
  ) async {
    final old = Completer<List<Candle>>();
    await t.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            height: 650,
            child: CandleChartPanel(
              rangeMode: true,
              initialLayout: const {
                'layoutV': 2,
                'rangeMode': true,
                'interval': 'range:1D',
              },
              loader: (c) async {
                if (c == 'range:1D') return old.future;
                return [];
              },
            ),
          ),
        ),
      ),
    );
    await t.pump();
    t
        .state<CandleChartPanelState>(find.byType(CandleChartPanel))
        .applyChartSelection(range: true, code: 'range:1M');
    await t.pumpAndSettle();
    old.completeError(Exception('old range failed'));
    await t.pumpAndSettle();
    expect(find.textContaining('old range failed'), findsNothing);
    expect(t.takeException(), isNull);
  });
}
