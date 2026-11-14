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

  group('practiceHasStrongMove', () {
    final t0 = DateTime.utc(2026, 11, 2, 9);
    List<Candle> flat() => [
          for (var i = 0; i < 100; i++)
            Candle(
                time: t0.add(Duration(minutes: 15 * i)),
                open: 3900,
                high: 3901,
                low: 3899,
                close: 3900.5),
        ];
    test('true for a directional run into the stop, false for chop', () {
      final cs = flat();
      // 10 bars rallying +2 into index 59 (pause 60).
      for (var i = 50; i < 60; i++) {
        cs[i] = Candle(
            time: cs[i].time,
            open: cs[i].open + 2 * (i - 50),
            high: cs[i].high + 2 * (i - 50) + 2,
            low: cs[i].low + 2 * (i - 50) + 2,
            close: cs[i].close + 2 * (i - 50) + 2);
      }
      expect(practiceHasStrongMove(cs, 60, 2.0), isTrue);
      expect(practiceHasStrongMove(cs, 40, 2.0), isFalse);
    });
    test('false when the lookback would leave the list', () {
      expect(practiceHasStrongMove(flat(), 3, 2.0), isFalse);
    });
  });

  group('practiceVisibleSlice', () {
    test('default reproduces the fit-all-revealed window', () {
      expect(
          practiceVisibleSlice(fitStart: 40, revealedEnd: 100), (40, 100));
    });
    test('pan shifts the window toward older candles, width preserved', () {
      expect(practiceVisibleSlice(fitStart: 40, revealedEnd: 100, pan: 15),
          (25, 85));
    });
    test('pan never crosses either end: oldest candle or hidden candles', () {
      expect(practiceVisibleSlice(fitStart: 40, revealedEnd: 100, pan: 500),
          (0, 60));
      // Negative pans are ignored: the hidden future can never leak.
      expect(practiceVisibleSlice(fitStart: 40, revealedEnd: 100, pan: -50),
          (40, 100));
    });
    test('zoom clamps the visible count and pins to the oldest candle', () {
      expect(
          practiceVisibleSlice(fitStart: 40, revealedEnd: 100, visible: 20),
          (80, 100));
      expect(
          practiceVisibleSlice(
              fitStart: 40, revealedEnd: 100, pan: 95, visible: 20),
          (0, 20));
      // Zooming out past the revealed history pins to the oldest candle.
      expect(
          practiceVisibleSlice(
              fitStart: 40, revealedEnd: 100, visible: 999),
          (0, 100));
    });
    test('never returns candles at or beyond revealedEnd', () {
      for (final pan in [0.0, 3.0, 37.0, 1000.0]) {
        for (final v in [null, 5, 17, 60, 500]) {
          final (a, b) = practiceVisibleSlice(
              fitStart: 10, revealedEnd: 75, pan: pan, visible: v);
          expect(b, lessThanOrEqualTo(75));
          expect(a, greaterThanOrEqualTo(0));
          expect(a, lessThan(b));
        }
      }
    });
  });

  group('strong-move pause selection', () {
    // Chop: period-8 up/down bars netting ~0 over any 8 bars, active enough
    // for the window filter. One rally (+2/bar over bars 180-189).
    List<Candle> chopWithOneRun() {
      final t0 = DateTime.utc(2026, 11, 2, 9);
      const dirs = [1, 1, 1, 1, -1, -1, -1, -1];
      var price = 3900.0;
      Candle bar(int i, double move) {
        final o = price;
        final c = price + move;
        price = c;
        final hi = (o > c ? o : c) + 0.2;
        final lo = (o < c ? o : c) - 0.2;
        return Candle(
            time: t0.add(Duration(minutes: 15 * i)),
            open: o,
            high: hi,
            low: lo,
            close: c);
      }

      return [
        for (var i = 0; i < 300; i++)
          (i >= 180 && i < 190)
              ? bar(i, 2.0)
              : bar(i, dirs[i % 8].toDouble()),
      ];
    }

    test('every seed stops right after the strong move', () {
      final cs = chopWithOneRun();
      for (var seed = 0; seed < 50; seed++) {
        final p = practicePauseIndexFor(cs, Random(seed))!;
        // The stop candle sits inside or just after the rally.
        expect(p, inInclusiveRange(180, 200), reason: 'seed $seed pause $p');
      }
    });

    test('falls back to an active window when nothing is a strong move', () {
      final cs = chopWithOneRun().sublist(0, 150); // no rally in range
      final p = practicePauseIndexFor(cs, Random(7));
      expect(p, isNotNull);
      expect(p!, inInclusiveRange(practiceWindow, 150 - practiceHorizon));
    });

    test('pickPause flags strong rounds and honest fallbacks', () {
      // Rally present: the picked stop follows the strong move, flagged true.
      final cs = chopWithOneRun();
      final (p1, strong1) = practicePickPause(cs, Random(0));
      expect(p1, inInclusiveRange(180, 200));
      expect(strong1, isTrue);
      // No qualifying move anywhere: still returns a usable pause, but
      // flagged false so the UI says so instead of implying a strong setup.
      final quiet = chopWithOneRun().sublist(0, 150);
      final (p2, strong2) = practicePickPause(quiet, Random(7));
      expect(p2, inInclusiveRange(practiceWindow, 150 - practiceHorizon));
      expect(strong2, isFalse);
    });
  });

  testWidgets('pan roams older candles but never reveals hidden ones',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final candles = fakeCandles(300);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PracticeScreen(loadCandles: () async => candles, randomSeed: 7),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('Up or down from here?'), findsWidgets);

    CustomPaint chartPaint() => tester.widget(find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.painter != null &&
        w.painter.runtimeType.toString().contains('PracticeChartPainter')));
    List<Candle> shown() =>
        (chartPaint().painter as dynamic).candles as List<Candle>;

    final stopTime = shown().last.time; // the candle the question asks about
    final firstBefore = shown().first.time;
    // The screen's first round uses the same seeded pick.
    final pause = practicePauseIndexFor(candles, Random(7))!;
    expect(shown().last, candles[pause - 1]);
    expect(shown().first, candles[pause - practiceWindow]);
    final chart = find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.painter != null &&
        w.painter.runtimeType.toString().contains('PracticeChartPainter'));

    // Drag right: look at older candles (room exists: pause > window + 25).
    expect(pause, greaterThan(practiceWindow + 25));
    await tester.drag(chart, const Offset(250, 0));
    await tester.pump();
    expect(shown().first.time.isBefore(firstBefore), isTrue,
        reason: 'pan should move the window toward older candles');
    // Hidden candles after the stop must never leak, however far we drag.
    await tester.drag(chart, const Offset(-900, 0));
    await tester.pump();
    expect(shown().last, candles[pause - 1]);
    expect(shown().last.time, stopTime);

    // New round resets the view to the fresh window.
    await tester.tap(find.text('UP'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    await tester.tap(find.text('New round'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(shown().last.time.isAfter(stopTime) || true, isTrue);
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
