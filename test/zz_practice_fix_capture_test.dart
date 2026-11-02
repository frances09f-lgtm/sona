import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/practice_screen.dart';

/// Practice-fix capture: renders the practice screen mid-replay using the
/// ACTUAL Twelve Data XAU/USD 15-minute payload retrieved from the user's
/// own account on Nov 2 2026 (test/fixtures/xau_15m_real.json - market
/// OHLC data only, no credentials).
///
/// BEFORE: the screen receives only the flat Saturday bars that make up
/// 192 of the 300 fetched bars (what a random window lands in ~55% of the
/// time) - this is the user's screenshot state.
/// AFTER: the screen receives the full 300-bar payload and the fixed
/// activity-aware pause selection picks a window with real movement.
/// No-op unless PRACTICE_FIX_CAPTURE=1.

List<Candle> loadRealPayload() {
  final raw = jsonDecode(
      File('test/fixtures/xau_15m_real.json').readAsStringSync());
  final values = (raw['values'] as List).cast<Map<String, dynamic>>();
  final out = <Candle>[
    for (final v in values)
      Candle(
        time: DateTime.parse(v['datetime'] as String),
        open: double.parse(v['open'] as String),
        high: double.parse(v['high'] as String),
        low: double.parse(v['low'] as String),
        close: double.parse(v['close'] as String),
      ),
  ]..sort((a, b) => a.time.compareTo(b.time));
  return out;
}

void main() {
  final capture = Platform.environment['PRACTICE_FIX_CAPTURE'] == '1';

  setUpAll(() async {
    if (!capture) return;
    final roboto = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
    await roboto.load();
    await icons.load();
  });

  Future<void> pumpReplay(WidgetTester tester, List<Candle> cs) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final screen = PracticeScreen(loadCandles: () async => cs, randomSeed: 7);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
      home: Builder(
        builder: (ctx) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => screen));
          });
          return const Scaffold(backgroundColor: Color(0xFF0F1115));
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1x'));
    await tester.pump();
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    for (var i = 0; i < 14; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  testWidgets('BEFORE: random window lands in flat weekend feed bars',
      (tester) async {
    if (!capture) return;
    final sat = loadRealPayload()
        .where((c) =>
            c.time.isAfter(DateTime.utc(2026, 10, 30, 21, 30)) &&
            c.time.isBefore(DateTime.utc(2026, 11, 1, 22, 0)))
        .toList();
    expect(sat.length, greaterThan(100));
    await pumpReplay(tester, sat);
    expect(find.text('Replaying...'), findsOneWidget);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_before.png'));
  });

  testWidgets('AFTER: full real payload, activity-aware window', (tester) async {
    if (!capture) return;
    final all = loadRealPayload();
    expect(all.length, 300);
    await pumpReplay(tester, all);
    expect(find.text('Replaying...'), findsOneWidget);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_after.png'));
  });

  testWidgets('QUESTION: replay stops after 60 candles and asks up/down',
      (tester) async {
    if (!capture) return;
    final all = loadRealPayload();
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final screen = PracticeScreen(loadCandles: () async => all, randomSeed: 7);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
      home: Builder(
        builder: (ctx) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Navigator.of(ctx).push(MaterialPageRoute(builder: (_) => screen));
          });
          return const Scaffold(backgroundColor: Color(0xFF0F1115));
        },
      ),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1x'));
    await tester.pump();
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    // 1x = 1 candle per second; the round stops after practiceWindow (60).
    for (var i = 0; i < 62; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('Up or down from here?'), findsOneWidget);
    expect(find.text('UP'), findsOneWidget);
    expect(find.text('DOWN'), findsOneWidget);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_question_real.png'));
  });
}
