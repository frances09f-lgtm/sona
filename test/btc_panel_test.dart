import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/btc_feed.dart';
import 'package:sona/btc_practice_panel.dart';
import 'package:sona/market_data/models.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

List<Candle> sampleCandles() {
  final start = DateTime.utc(2026, 11, 12);
  return [
    for (var i = 0; i < 60; i++)
      Candle(
        time: start.add(Duration(minutes: 15 * i)),
        open: 66900 + i * 2.0,
        high: 66950 + i * 2.0,
        low: 66850 + i * 2.0,
        close: 66920 + i * 2.0,
      ),
  ];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('BTC panel renders header, buttons, balance and scope note',
      (tester) async {
    final fonts = FontLoader('Roboto')
      ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
    await fonts.load();
    await icons.load();

    final feed = BinanceBtcFeed(
      hostOverride: 'test.local',
      client: MockClient((req) async {
        if (req.url.path.contains('bookTicker')) {
          return http.Response(
            '{"symbol":"BTCUSDT","bidPrice":"66938.33","bidQty":"1","askPrice":"66963.33","askQty":"1"}',
            200,
          );
        }
        if (req.url.path.contains('24hr')) {
          return http.Response(
            '{"symbol":"BTCUSDT","priceChangePercent":"1.40","lastPrice":"66950.83"}',
            200,
          );
        }
        return http.Response('[]', 200);
      }),
    );

    await tester.binding.setSurfaceSize(const Size(393, 852));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto', brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF10182A),
        body: ListView(
          padding: const EdgeInsets.all(14),
          children: [
            BtcPracticePanel(
              feedOverride: feed,
              candleLoaderOverride: (iv) async => sampleCandles(),
            ),
          ],
        ),
      ),
    ));
    // Let the quote tick + prefs load land.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('BTC'), findsOneWidget);
    expect(find.text('BTC/USDT · Paper trading'), findsOneWidget);
    expect(find.text('BUY'), findsOneWidget);
    expect(find.text('SELL'), findsOneWidget);
    expect(find.text('Practice balance'), findsOneWidget);
    expect(
      find.text('Signals, alerts and AI advice stay on Gold in this version'),
      findsOneWidget,
    );
    expect(
      find.text(
          'Practice TP/SL triggers only while Sona is open with a live BTC feed.'),
      findsOneWidget,
    );
    // Quote from the mocked book ticker reached the BUY/SELL buttons.
    expect(find.text('66,963.33'), findsWidgets);
  });

  testWidgets('BTC ticket enforces minimum size and opens a local position',
      (tester) async {
    final feed = BinanceBtcFeed(
      hostOverride: 'test.local',
      client: MockClient((req) async => http.Response(
          '{"symbol":"BTCUSDT","bidPrice":"66938.33","bidQty":"1","askPrice":"66963.33","askQty":"1"}',
          200)),
    );
    await tester.binding.setSurfaceSize(const Size(393, 1200));
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData(fontFamily: 'Roboto', brightness: Brightness.dark),
      home: Scaffold(
        body: ListView(
          children: [
            BtcPracticePanel(
              feedOverride: feed,
              candleLoaderOverride: (iv) async => sampleCandles(),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('BUY'));
    await tester.pumpAndSettle();
    expect(find.text('Buy BTC/USDT (practice)'), findsOneWidget);
    expect(find.textContaining('simulated 1:500 leverage'), findsOneWidget);
    expect(find.textContaining('not broker terms'), findsOneWidget);

    // Too small: 0.0005 BTC must be refused with a BTC-worded error.
    await tester.enterText(
        find.widgetWithText(TextField, 'Size (BTC, min 0.001)'), '0.0005');
    await tester.tap(find.widgetWithText(FilledButton, 'Buy'));
    await tester.pump();
    expect(find.textContaining('Minimum size is 0.001 BTC'), findsOneWidget);

    // Valid size opens a local position shown in the panel.
    await tester.enterText(
        find.widgetWithText(TextField, 'Size (BTC, min 0.001)'), '0.01');
    await tester.tap(find.widgetWithText(FilledButton, 'Buy'));
    await tester.pumpAndSettle();
    expect(find.textContaining('0.01 BTC @ 66,963.33'), findsOneWidget);

    // Only the BTC ledger key was written - gold storage untouched.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'sona_btc_paper_v1'});
  });
}
