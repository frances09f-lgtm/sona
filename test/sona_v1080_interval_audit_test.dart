// Regression coverage for v1.0.80's interval-history truncation.
// Synthetic provider responses only: no network, credentials or real trades.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/indicators.dart';
import 'package:sona/market_data/models.dart';

List<Candle> history(Duration step, int count) => List.generate(count, (i) {
  final price = 2000.0 + i;
  return Candle(
    time: DateTime.utc(2026, 10, 1).add(step * i),
    open: price,
    high: price + 1,
    low: price - 1,
    close: price,
  );
});

const intervalSteps = <String, Duration>{
  '1min': Duration(minutes: 1),
  '15min': Duration(minutes: 15),
  '1h': Duration(hours: 1),
  '4h': Duration(hours: 4),
  '1day': Duration(days: 1),
};

void main() {
  // Exercise the production helper called by TradeTab's actual loader, not a
  // locally copied conditional or reconstruction of the loader's expression.
  for (final entry in intervalSteps.entries) {
    test('${entry.key} preserves history and complete indicator inputs', () {
      final input = history(entry.value, 120);
      expect(tradeRangeSpec(entry.key), (entry.key, 120));
      final output = trimTradeRange(input, entry.key);
      expect(output, same(input));
      expect(output, hasLength(120));
      expect(ema(output, 50), orderedEquals(ema(input, 50)));
      expect(ema(output, 50), hasLength(71));
      expect(rsi(output, 14), orderedEquals(rsi(input, 14)));
      expect(rsi(output, 14), hasLength(106));
      final expectedMacd = macd(input);
      final actualMacd = macd(output);
      expect(actualMacd.$1, orderedEquals(expectedMacd.$1));
      expect(actualMacd.$2, orderedEquals(expectedMacd.$2));
      expect(actualMacd.$3, orderedEquals(expectedMacd.$3));
      expect(actualMacd.$1, hasLength(95));
      expect(actualMacd.$2, hasLength(87));
      expect(actualMacd.$3, hasLength(87));
    });
  }

  for (final entry in <String, Duration>{
    'range:1H': Duration(hours: 1),
    'range:1D': Duration(days: 1),
    'range:1W': Duration(days: 7),
    'range:1M': Duration(days: 30),
    'range:3M': Duration(days: 90),
    'range:1Y': Duration(days: 365),
  }.entries) {
    test(
      '${entry.key} retains inclusive range boundary and excludes older bar',
      () {
        final end = DateTime.utc(2026, 10, 1);
        final boundary = end.subtract(entry.value);
        Candle candle(DateTime time) =>
            Candle(time: time, open: 2000, high: 2001, low: 1999, close: 2000);
        final input = [
          candle(boundary.subtract(const Duration(microseconds: 1))),
          candle(boundary),
          candle(boundary.add(const Duration(microseconds: 1))),
          candle(end),
        ];
        expect(trimTradeRange(input, entry.key), orderedEquals(input.skip(1)));
      },
    );
  }

  test('empty, short and sparse provider responses are not padded', () {
    for (final code in [...intervalSteps.keys, 'range:1H']) {
      final empty = <Candle>[];
      expect(trimTradeRange(empty, code), same(empty));
      final single = history(const Duration(days: 1), 1);
      expect(trimTradeRange(single, code), orderedEquals(single));
    }
    final short = history(const Duration(days: 3), 7);
    final output = trimTradeRange(short, '1day');
    expect(output, same(short));
    expect(ema(output, 50), isEmpty);
    expect(rsi(output, 14), isEmpty);
    expect(macd(output).$1, isEmpty);
  });

  testWidgets(
    'range-to-interval switching supplies restored history to painter',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      final key = GlobalKey<CandleChartPanelState>();
      final calls = <String>[];
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: CandleChartPanel(
                key: key,
                rangeMode: true,
                initialLayout: const {
                  'rangeMode': true,
                  'interval': 'range:1D',
                  'ema50': true,
                  'rsi': true,
                  'macd': true,
                },
                loader: (code) async {
                  calls.add(code);
                  final spec = tradeRangeSpec(code);
                  final providerResponse = history(
                    intervalSteps[spec.$1]!,
                    120,
                  );
                  return trimTradeRange(providerResponse, code);
                },
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(calls.last, 'range:1D');
      expect(key.currentState!.candles, hasLength(97));
      await t.tap(find.text('Candle intervals'));
      await t.pumpAndSettle();
      for (final label in ['H1', 'H4', 'D1']) {
        await t.tap(find.text(label));
        await t.pumpAndSettle();
        expect(key.currentState!.candles, hasLength(120));
        final painter = t
            .widgetList<CustomPaint>(find.byType(CustomPaint))
            .map((w) => w.painter)
            .whereType<CandlePainter>()
            .single;
        expect(painter.ema, hasLength(71));
        expect(painter.rsi, hasLength(106));
        expect(painter.macdLine, hasLength(95));
        expect(painter.macdSignal, hasLength(87));
        expect(painter.macdHist, hasLength(87));
        expect(
          find.text('More candle history needed for selected indicators.'),
          findsNothing,
        );
        expect(t.takeException(), isNull);
      }
      await t.pumpWidget(const SizedBox());
    },
  );
}
