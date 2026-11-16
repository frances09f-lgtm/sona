import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/auto_trade.dart';
import 'package:sona/ai_brain.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/notifications.dart';
import 'package:sona/signal_pass.dart';
import 'package:sona/signal_zones.dart';
import 'package:sona/user_api_keys.dart';

/// Signal-pass repair (user-approved Nov 16 2026): gold BUY/SELL boxes
/// must generate independently of AutoTrade, pauses, cooldowns and open
/// positions, with at most one deduped Groq qualification call per gap.

/// 40 bars with a retested swing high (~3910) and a retested swing low
/// (~3860); price ends mid-range at 3885, so both direction slots get a
/// detected candidate.
List<Candle> swingCandles() {
  final t0 = DateTime.utc(2026, 11, 16, 8, 0);
  final highs = <int, double>{5: 3910.0, 20: 3909.8};
  final lows = <int, double>{12: 3860.0, 28: 3860.4};
  return [
    for (var i = 0; i < 40; i++)
      Candle(
        time: t0.add(Duration(minutes: 15 * i)),
        open: 3885.0,
        high: highs[i] ?? 3890.0,
        low: lows[i] ?? 3880.0,
        close: 3885.0,
      ),
  ];
}

/// Flat candles: no swing pivots, so no candidate exists.
List<Candle> flatCandles() {
  final t0 = DateTime.utc(2026, 11, 16, 8, 0);
  return [
    for (var i = 0; i < 40; i++)
      Candle(
        time: t0.add(Duration(minutes: 15 * i)),
        open: 3885.0,
        high: 3886.0,
        low: 3884.0,
        close: 3885.0,
      ),
  ];
}

class CountingBrain {
  int calls = 0;
  GroqBrain brain({bool buyOk = true, bool sellOk = true}) {
    return GroqBrain(
      client: MockClient((req) async {
        calls++;
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {
                  'content': '{"zone_buy":$buyOk,"zone_sell":$sellOk,'
                      '"zone_reason":"test"}'
                }
              }
            ]
          }),
          200,
        );
      }),
    );
  }
}

void main() {
  final now = DateTime.utc(2026, 11, 16, 20, 0).millisecondsSinceEpoch;

  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
    // Secure-storage mock carries the key so UserApiKeys.load() (called
    // inside AutoTrade paths) keeps a configured Groq key.
    FlutterSecureStorage.setMockInitialValues({'oro_groq_key': 'test-key'});
    SharedPreferences.setMockInitialValues({});
    UserApiKeys.groq = 'test-key';
  });

  test('background worker path adds qualified boxes with AutoTrade OFF',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await AutoTrade.setEnabled(prefs, false); // trade engine stays off
    final counter = CountingBrain();
    // The exact function the background worker's AI section runs.
    await oroBackgroundAi(
      prefs,
      brain: counter.brain(),
      midFetcher: () async => 3885.0,
      candleFetcher: () async => swingCandles(),
      nowMs: now,
    );
    final mgr = SignalBoxManager();
    await mgr.load(prefs);
    expect(mgr.boxes.length, 2,
        reason: 'BUY + SELL both qualified and drawn although '
            'AutoTrade is off');
    expect(counter.calls, 1);
    final st = await AutoTrade.status(prefs);
    expect(st.enabled, isFalse, reason: 'trade engine untouched');
  });

  test('trading gates (pause + cooldown) do not block the signal pass',
      () async {
    final prefs = await SharedPreferences.getInstance();
    // AutoTrade's private gate keys, set raw: the signal pass must not
    // read them at all.
    await prefs.setString('tj_ai_pause', '2 consecutive losses - paused');
    await prefs.setString('tj_ai_cooldown',
        DateTime.now().add(const Duration(hours: 1)).toIso8601String());
    final counter = CountingBrain();
    final msg = await SignalPass.run(
      prefs,
      brain: counter.brain(),
      midFetcher: () async => 3885.0,
      candleFetcher: () async => swingCandles(),
      nowMs: now,
    );
    expect(msg, 'New signal box qualified and drawn');
    final mgr = SignalBoxManager();
    await mgr.load(prefs);
    expect(mgr.boxes.length, 2);
    expect(counter.calls, 1);
  });

  test('dedupe: rejected setup costs one AI call per gap, then retries',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final counter = CountingBrain();
    final reject = counter.brain(buyOk: false, sellOk: false);
    Future<String> pass(int atMs) => SignalPass.run(
          prefs,
          brain: reject,
          midFetcher: () async => 3885.0,
          candleFetcher: () async => swingCandles(),
          nowMs: atMs,
        );
    await pass(now);
    await pass(now + const Duration(minutes: 2).inMilliseconds);
    expect(counter.calls, 1,
        reason: 'second pass inside the gap must not call the AI again');
    final mgr = SignalBoxManager();
    await mgr.load(prefs);
    expect(mgr.boxes, isEmpty, reason: 'rejected setups draw nothing');
    await pass(now + const Duration(minutes: 16).inMilliseconds);
    expect(counter.calls, 2, reason: 'retry allowed after the gap');
  });

  test('no candidate: no AI call', () async {
    final prefs = await SharedPreferences.getInstance();
    final counter = CountingBrain();
    final msg = await SignalPass.run(
      prefs,
      brain: counter.brain(),
      midFetcher: () async => 3885.0,
      candleFetcher: () async => flatCandles(),
      nowMs: now,
    );
    expect(msg, 'Checked - no new signal');
    expect(counter.calls, 0);
  });

  test('no live quote: skipped without AI call', () async {
    final prefs = await SharedPreferences.getInstance();
    final counter = CountingBrain();
    final msg = await SignalPass.run(
      prefs,
      brain: counter.brain(),
      midFetcher: () async => null,
      candleFetcher: () async => swingCandles(),
      nowMs: now,
    );
    expect(msg, 'No live quote - skipped');
    expect(counter.calls, 0);
  });

  test('standing boxes block new qualification (slots occupied)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    final counter = CountingBrain();
    // First pass draws both boxes.
    await SignalPass.run(
      prefs,
      brain: counter.brain(),
      midFetcher: () async => 3885.0,
      candleFetcher: () async => swingCandles(),
      nowMs: now,
    );
    expect(counter.calls, 1);
    // While both stand, a later pass (past the dedupe gap) asks nothing.
    final msg = await SignalPass.run(
      prefs,
      brain: counter.brain(),
      midFetcher: () async => 3885.0,
      candleFetcher: () async => swingCandles(),
      nowMs: now + const Duration(minutes: 30).inMilliseconds,
    );
    expect(msg, 'Checked - no new signal');
    expect(counter.calls, 1);
    final mgr = SignalBoxManager();
    await mgr.load(prefs);
    expect(mgr.boxes.length, 2);
  });
}
