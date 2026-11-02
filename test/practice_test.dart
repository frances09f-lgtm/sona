import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/practice_screen.dart';

List<Candle> fakeCandles(int n, {double start = 3900}) {
  final t0 = DateTime.utc(2026, 10, 26, 9);
  var price = start;
  return [
    for (var i = 0; i < n; i++)
      () {
        final drift = (i % 5) + 1; // always rising: no flat windows
        final o = price;
        final c = price + drift;
        price = c;
        return Candle(
          time: t0.add(Duration(minutes: 15 * i)),
          open: o,
          high: o > c ? o + 1.5 : c + 1.5,
          low: o < c ? o - 1.5 : c - 1.5,
          close: c,
        );
      }(),
  ];
}

void main() {
  group('practiceOutcome', () {
    test('up pick wins on a rise, loses on a fall', () {
      expect(practiceOutcome('up', 100, 101), PracticeOutcome.correct);
      expect(practiceOutcome('up', 100, 99), PracticeOutcome.wrong);
    });
    test('down pick wins on a fall, loses on a rise', () {
      expect(practiceOutcome('down', 100, 99), PracticeOutcome.correct);
      expect(practiceOutcome('down', 100, 101), PracticeOutcome.wrong);
    });
    test('flat close is not a loss for either pick', () {
      expect(practiceOutcome('up', 100, 100), PracticeOutcome.flat);
      expect(practiceOutcome('down', 100, 100), PracticeOutcome.flat);
    });
  });

  group('practicePauseIndex', () {
    test('stays inside window/horizon bounds', () {
      final rng = Random(42);
      for (var i = 0; i < 200; i++) {
        final p = practicePauseIndex(300, rng)!;
        expect(p, greaterThanOrEqualTo(practiceWindow));
        expect(p, lessThanOrEqualTo(300 - practiceHorizon));
      }
    });
    test('null when history is too short', () {
      expect(practicePauseIndex(60, Random(1)), isNull);
      expect(practicePauseIndex(64, Random(1)), isNull);
      expect(practicePauseIndex(65, Random(1)), isNotNull);
    });
  });


  group('practicePauseIndexFor', () {
    List<Candle> mixed() {
      // Mirrors the real Twelve Data XAU/USD fetch: active Friday bars
      // (span ~5-30) followed by flat weekend placeholder bars (~0.23).
      final t0 = DateTime.utc(2026, 10, 30, 0, 0);
      return [
        for (var i = 0; i < 300; i++)
          i < 100
              ? Candle(
                  time: t0.add(Duration(minutes: 15 * i)),
                  open: 3900 + (i % 7).toDouble(),
                  high: 3908 + (i % 9).toDouble(),
                  low: 3896 - (i % 5).toDouble(),
                  close: 3902 + (i % 6).toDouble())
              : Candle(
                  time: t0.add(Duration(minutes: 15 * i)),
                  open: 3875.35,
                  high: 3875.53,
                  low: 3875.30,
                  close: 3875.41),
      ];
    }

    test('never picks a pause whose window is flat feed bars', () {
      final cs = mixed();
      for (var seed = 0; seed < 50; seed++) {
        final p = practicePauseIndexFor(cs, Random(seed))!;
        var lo = double.infinity, hi = -double.infinity;
        for (var i = p - practiceWindow; i < p; i++) {
          if (cs[i].low < lo) lo = cs[i].low;
          if (cs[i].high > hi) hi = cs[i].high;
        }
        expect(hi - lo, greaterThan(1.0), reason: 'seed $seed pause $p');
      }
    });

    test('falls back to any valid index when the whole fetch is flat', () {
      final t0 = DateTime.utc(2026, 10, 31);
      final flat = [
        for (var i = 0; i < 200; i++)
          Candle(
              time: t0.add(Duration(minutes: 15 * i)),
              open: 3875.35,
              high: 3875.53,
              low: 3875.30,
              close: 3875.41),
      ];
      final p = practicePauseIndexFor(flat, Random(3));
      expect(p, isNotNull);
      expect(p!, greaterThanOrEqualTo(practiceWindow));
      expect(p, lessThanOrEqualTo(200 - practiceHorizon));
    });

    test('null when history is too short', () {
      expect(practicePauseIndexFor(const [], Random(1)), isNull);
      final short = [
        for (var i = 0; i < 60; i++)
          Candle(
              time: DateTime.utc(2026, 10, 30).add(Duration(minutes: 15 * i)),
              open: 1, high: 2, low: 0.5, close: 1.5),
      ];
      expect(practicePauseIndexFor(short, Random(1)), isNull);
    });
  });

  testWidgets('round replays, stops, answers and scores', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final candles = fakeCandles(120);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PracticeScreen(loadCandles: () async => candles),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Start replay'), findsOneWidget);

    await tester.tap(find.text('Start replay'));
    await tester.pump();
    // 60 candles at the 5x default = 12 seconds of replay
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Up or down from here?'), findsWidgets);
    expect(find.text('UP'), findsOneWidget);
    expect(find.text('DOWN'), findsOneWidget);

    await tester.tap(find.text('UP'));
    await tester.pump();
    // 5 reveal ticks at 350ms
    await tester.pump(const Duration(seconds: 5));
    // fixture always rises, so UP is always Correct and scores 1/1
    expect(find.textContaining('Correct - it moved'), findsOneWidget);
    expect(find.textContaining('USD/oz over the next 5 candles'), findsOneWidget);
    expect(find.text('New round'), findsOneWidget);
    expect(find.textContaining('Score 1/1'), findsOneWidget);
  });

  testWidgets('error state shows service message and retry', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PracticeScreen(
        loadCandles: () async =>
            throw Exception('Add your Twelve Data key in API settings'),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Twelve Data key'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  testWidgets('speed choices 1x 2x 5x are all shown', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PracticeScreen(loadCandles: () async => fakeCandles(120)),
    ));
    await tester.pumpAndSettle();
    for (final s in ['1x', '2x', '5x']) {
      expect(find.text(s), findsOneWidget, reason: '$s chip missing');
    }
  });
}
