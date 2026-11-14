import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/ai_brain.dart';
import 'package:sona/btc_practice_panel.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/user_api_keys.dart';

import 'btc_signals_test.dart';

/// BTC AI zone filtering (user request Nov 14 evening): boxes are drawn
/// only when the Groq brain qualifies the proposed level, and the
/// verdict is visible in the panel's notice line.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserApiKeys.groq = 'test-key';
  });

  tearDown(() {
    UserApiKeys.groq = '';
  });

  Future<BtcPracticePanelState> pumpPanel(
    WidgetTester tester,
    List<Candle> candles,
    GroqBrain Function() brain,
  ) async {
    await loadFonts();
    await tester.binding.setSurfaceSize(const Size(393, 852));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto', brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF10182A),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            BtcPracticePanel(
              feedOverride: fixtureFeed(),
              candleLoaderOverride: (iv) async => candles,
              brainOverride: brain,
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    return tester.state<BtcPracticePanelState>(find.byType(BtcPracticePanel));
  }

  testWidgets('AI rejection draws no box and says why', (tester) async {
    final candles = signalFixtureCandles();
    final state = await pumpPanel(
        tester, candles, qualBrain(buyOk: false, sellOk: false, reason: 'choppy'));
    await state.debugSignalCandles(candles);
    await tester.pump();
    expect(state.signals.displayBoxes, isEmpty);
    expect(state.notice, contains('BTC AI skipped'));
    expect(state.notice, contains('choppy'));
  });

  testWidgets('AI approval draws only the approved direction', (tester) async {
    final candles = signalFixtureCandles();
    final state = await pumpPanel(
        tester, candles, qualBrain(buyOk: true, sellOk: false));
    await state.debugSignalCandles(candles);
    await tester.pump();
    final boxes = state.signals.displayBoxes;
    expect(boxes, hasLength(1));
    expect(boxes.single.isBuy, isTrue);
    expect(state.notice, contains('BTC AI approved a BUY setup'));
  });

  testWidgets('brain failure draws nothing, stays pending, backs off retry',
      (tester) async {
    var calls = 0;
    final candles = signalFixtureCandles();
    final state = await pumpPanel(tester, candles, () {
      calls++;
      return failingQualBrain()();
    });
    await state.debugSignalCandles(candles);
    await tester.pump();
    expect(state.signals.displayBoxes, isEmpty);
    expect(state.notice, contains('BTC AI unavailable'));
    // A refresh inside the 5-minute failure backoff must not hammer the
    // brain again; the candidates stay pending for a later retry.
    await state.debugSignalCandles(candles);
    await tester.pump();
    expect(calls, 1);
    expect(state.signals.displayBoxes, isEmpty);
  });

  testWidgets('a rejected level is not re-asked inside the cooldown',
      (tester) async {
    var calls = 0;
    final candles = signalFixtureCandles();
    await loadFonts();
    await tester.binding.setSurfaceSize(const Size(393, 852));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto', brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF10182A),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            BtcPracticePanel(
              feedOverride: fixtureFeed(),
              candleLoaderOverride: (iv) async => candles,
              brainOverride: () {
                calls++;
                return qualBrain(buyOk: false, sellOk: false)();
              },
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    final state =
        tester.state<BtcPracticePanelState>(find.byType(BtcPracticePanel));
    await state.debugSignalCandles(candles);
    await tester.pump();
    expect(state.signals.displayBoxes, isEmpty);
    // Second refresh with the same candles: the rejected levels are in
    // cooldown, so no new qualification request is made.
    await state.debugSignalCandles(candles);
    await tester.pump();
    expect(calls, 1);
  });
}
