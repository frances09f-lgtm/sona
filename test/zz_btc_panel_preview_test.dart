import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/btc_feed.dart';
import 'package:sona/btc_practice_panel.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'btc_signals_test.dart' show qualBrain, signalFixtureCandles;
import 'package:sona/user_api_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('btc panel preview', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
    await fonts.load();
    await icons.load();
    final feed = BinanceBtcFeed(
      hostOverride: 'test.local',
      client: MockClient((req) async {
        if (req.url.path.contains('24hr')) {
          return http.Response('{"priceChangePercent":"1.40"}', 200);
        }
        return http.Response(
            '{"symbol":"BTCUSDT","bidPrice":"66938.33","bidQty":"1","askPrice":"66963.33","askQty":"1"}',
            200);
      }),
    );
    // Deterministic fixture with re-tested support/resistance, so the
    // preview shows the real BUY + SELL signal boxes and count chip.
    final candles = signalFixtureCandles();
    await tester.binding.setSurfaceSize(const Size(393, 852));
    await tester.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(fontFamily: 'Roboto', brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF10182A),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            BtcPracticePanel(
              feedOverride: feed,
              candleLoaderOverride: (iv) async => candles,
              brainOverride: qualBrain(reason: 'strong level'),
            ),
          ],
        ),
      ),
    ));
        UserApiKeys.groq = 'test-key';
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(seconds: 1));
    // Drive the production candle path so signal boxes + chip render.
    final state = tester
        .state<BtcPracticePanelState>(find.byType(BtcPracticePanel));
    await state.debugSignalCandles(candles);
    await tester.pump();
    await expectLater(find.byType(Scaffold),
        matchesGoldenFile('goldens/zz_btc_panel_preview.png'));
  });
}
