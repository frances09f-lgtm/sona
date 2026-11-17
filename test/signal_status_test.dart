import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/candle_debug.dart';
import 'package:sona/signal_pass.dart';
import 'package:sona/signal_status.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    CandleDebugSink.clear();
  });

  test('status records fixed codes only and describes next-call wait',
      () async {
    final prefs = await SharedPreferences.getInstance();
    const now = 1700000000000;
    await SignalStatus.record(prefs,
        path: 'worker',
        outcome: 'ai_no_reply',
        candidates: 2,
        buyCandidates: 1,
        sellCandidates: 1,
        groqKeyPresent: false,
        nowMs: now);
    await SignalPass.stampQualified(prefs, now - 5 * 60000);
    final lines = SignalStatus.describe(prefs,
        nowMs: now + 60000, minGap: SignalPass.minQualGap);
    final text = lines.join('\n');
    expect(text, contains('path worker'));
    expect(text, contains('outcome: ai_no_reply'));
    expect(text, contains('candidates: 2 (buy 1, sell 1)'));
    expect(text, contains('Groq key present at that check: no'));
    expect(text, contains('next allowed in 9 min'));
  });

  test('unknown outcome text is stored as other (no free text leaks)',
      () async {
    final prefs = await SharedPreferences.getInstance();
    await SignalStatus.record(prefs,
        path: 'foreground', outcome: 'Bearer abc https://x');
    final text = SignalStatus.describe(prefs,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            minGap: SignalPass.minQualGap)
        .join('\n');
    expect(text, contains('outcome: other'));
    expect(text, isNot(contains('Bearer')));
  });

  test('raw gap lines are computed from received values, unaltered', () {
    CandleDebugSink.recordFetch(sourceName: 'twelvedata', values: [
      {
        'datetime': '2026-11-16 19:25:00',
        'open': '3862.10313',
        'close': '3864.35044'
      },
      {
        'datetime': '2026-11-16 19:20:00',
        'open': '3860.46673',
        'close': '3863.00986'
      },
      {
        'datetime': '2026-11-16 19:15:00',
        'open': '3857.54503',
        'close': '3861.00606'
      },
    ]);
    final lines = CandleDebugSink.openVsPrevCloseLines();
    expect(lines.length, 2);
    expect(lines.join('\n'), contains('= -0.90673'));
    expect(lines.join('\n'), contains('= -0.53933'));
    expect(CandleDebugSink.newestRawClose()!.$2, 3864.35044);
    // No interval recorded: nothing is assumed.
    expect(CandleDebugSink.barStatusLines().single, contains('unknown'));
  });

  test('bar status uses the requested interval, not a hardcoded 5 minutes',
      () {
    final vals = [
      {'datetime': '2026-11-16 19:25:00', 'open': '1', 'close': '2'},
      {'datetime': '2026-11-16 19:20:00', 'open': '1', 'close': '2'},
    ];
    CandleDebugSink.recordFetch(
        sourceName: 'twelvedata', values: vals, interval: '5min');
    // Pin the fetch clock to 19:26:59Z, as in the real dump.
    CandleDebugSink.fetchAtUtc = DateTime.utc(2026, 11, 16, 19, 26, 59);
    var t = CandleDebugSink.barStatusLines().join('\n');
    expect(t, contains('2026-11-16T19:25:00.000Z FORMING'));
    expect(t, contains('2026-11-16T19:20:00.000Z closed'));
    CandleDebugSink.recordFetch(
        sourceName: 'twelvedata', values: vals, interval: '15min');
    CandleDebugSink.fetchAtUtc = DateTime.utc(2026, 11, 16, 19, 26, 59);
    t = CandleDebugSink.barStatusLines().join('\n');
    // With a 15min request the 19:20 bar is still forming too.
    expect(t, contains('2026-11-16T19:20:00.000Z FORMING'));
    expect(CandleDebugSink.intervalDuration('1h'), const Duration(hours: 1));
    expect(CandleDebugSink.intervalDuration('weird'), isNull);
  });
}
