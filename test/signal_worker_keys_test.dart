import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/signal_pass.dart';
import 'package:sona/signal_status.dart';
import 'package:sona/user_api_keys.dart';

void main() {
  test('fresh worker isolate: SignalPass.run loads keys before any fetch',
      () async {
    SharedPreferences.setMockInitialValues({});
    // Saved keys exist in secure storage, but the in-memory statics are
    // empty exactly like a freshly started worker isolate.
    FlutterSecureStorage.setMockInitialValues({
      'oro_groq_key': 'groq-test',
      'oro_twelve_data_key': 'td-test',
    });
    UserApiKeys.groq = '';
    UserApiKeys.candles = '';
    final prefs = await SharedPreferences.getInstance();
    String? candlesSeen, groqSeen;
    // Calls SignalPass.run directly: AutoTrade.status is never reached,
    // so only run() itself can have loaded the keys.
    final out = await SignalPass.run(
      prefs,
      midFetcher: () async => 3885.0,
      candleFetcher: () async {
        candlesSeen = UserApiKeys.candles;
        groqSeen = UserApiKeys.groq;
        return <Candle>[];
      },
    );
    expect(candlesSeen, 'td-test');
    expect(groqSeen, 'groq-test');
    expect(out, 'No candle data - skipped');
    final text = SignalStatus.describe(prefs,
            nowMs: DateTime.now().millisecondsSinceEpoch,
            minGap: SignalPass.minQualGap)
        .join('\n');
    expect(text, contains('outcome: no_candles'));
    expect(text, isNot(contains('td-test')));
    expect(text, isNot(contains('groq-test')));
  });
}
