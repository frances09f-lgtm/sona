import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/ai_brain.dart';
import 'package:sona/btc_feed.dart';
import 'package:sona/btc_practice_panel.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/signal_zones.dart';
import 'package:sona/user_api_keys.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Deterministic candles with one re-tested support (~66800) and one
/// re-tested resistance (~67200) around a ~66950 price, so the real
/// detection path draws exactly one BUY and one SELL box.
List<Candle> signalFixtureCandles() {
  final start = DateTime.utc(2026, 11, 13, 12);
  Candle bar(int i, double o, double h, double l, double c) => Candle(
        time: start.add(Duration(minutes: 15 * i)),
        open: o,
        high: h,
        low: l,
        close: c,
      );
  return [
    for (var i = 0; i < 60; i++)
      if (i == 10 || i == 30)
        bar(i, 66950, 66980, 66800, 66850) // support touch + bounce
      else if (i == 20 || i == 40)
        bar(i, 67050, 67200, 67000, 67100) // resistance touch + reject
      else
        bar(i, 66950, 67080, 66900, 67000),
  ];
}

BinanceBtcFeed fixtureFeed() => BinanceBtcFeed(
      hostOverride: 'test.local',
      client: MockClient((req) async {
        if (req.url.path.contains('24hr')) {
          return http.Response(
              '{"symbol":"BTCUSDT","priceChangePercent":"1.40","lastPrice":"66950.83"}',
              200);
        }
        return http.Response(
            '{"symbol":"BTCUSDT","bidPrice":"66938.33","bidQty":"1","askPrice":"66963.33","askQty":"1"}',
            200);
      }),
    );

Future<void> loadFonts() async {
  final fonts = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await fonts.load();
  await icons.load();
}

/// A GroqBrain whose mock client answers the zone-qualification request
/// with the given verdicts, in the real chat-completions envelope.
GroqBrain Function() qualBrain(
        {bool buyOk = true, bool sellOk = true, String reason = 'test'}) =>
    () => GroqBrain(
          client: MockClient((req) async {
            expect(req.url.path, contains('chat/completions'));
            final inner = jsonEncode({
              'zone_buy': buyOk,
              'zone_sell': sellOk,
              'zone_reason': reason,
            });
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': inner}
                  }
                ]
              }),
              200,
            );
          }),
        );

/// A brain whose calls all fail (rate-limited / offline).
GroqBrain Function() failingQualBrain() => () => GroqBrain(
      client: MockClient((req) async => http.Response('{"error":{}}', 429)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    UserApiKeys.groq = 'test-key';
  });

  tearDown(() {
    UserApiKeys.groq = '';
  });

  testWidgets(
      'candle path draws one BUY and one SELL box with price-scaled '
      'offsets, and never touches gold keys', (tester) async {
    await loadFonts();
    final candles = signalFixtureCandles();
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
              brainOverride: qualBrain(reason: 'strong level'),
            ),
          ],
        ),
      ),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    final state = tester
        .state<BtcPracticePanelState>(find.byType(BtcPracticePanel));

    // Drive the PRODUCTION candle path (same method the chart loader
    // calls on every real refresh).
    await state.debugSignalCandles(candles);
    await tester.pump();

    final boxes = state.signals.displayBoxes;
    expect(boxes, hasLength(2));
    final buy = boxes.singleWhere((b) => b.isBuy);
    final sell = boxes.singleWhere((b) => !b.isBuy);

    // Zones sit at the fixture's support/resistance.
    final halfHeight = 66950.83 * kBtcZoneHalfHeightPct;
    expect(buy.high, closeTo(66800 + halfHeight, 0.5));
    expect(sell.low, closeTo(67200 - halfHeight, 0.5));

    // Offsets are percent of the CREATION price (~66950.83), not a
    // remembered 67,000 anchor: 0.077% / 0.038%.
    expect(buy.targetOffset, closeTo(66950.83 * kBtcSignalTargetPct, 0.01));
    expect(buy.invalidationOffset,
        closeTo(66950.83 * kBtcSignalInvalidationPct, 0.01));
    expect(sell.targetOffset, buy.targetOffset);
    // BUY target above the box, invalidation below; SELL mirrored.
    expect(buy.target, greaterThan(buy.high));
    expect(buy.invalidation, lessThan(buy.low));
    expect(sell.target, lessThan(sell.low));
    expect(sell.invalidation, greaterThan(sell.high));

    // Persisted under the BTC key; gold's key was never written.
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('sona_btc_ai_signal_boxes_v2'), isNotNull);
    expect(prefs.getString('sona_btc_signal_boxes_v1'), isNull);
    expect(prefs.getString('sona_signal_boxes_v1'), isNull);
  });

  test('pre-AI boxes persisted under the v1 key are never loaded', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    // Boxes saved by the pre-AI rule-based build under its key.
    final legacy = SignalBoxManager(
      prefsKey: 'sona_btc_signal_boxes_v1',
      targetPct: kBtcSignalTargetPct,
      invalidationPct: kBtcSignalInvalidationPct,
      zoneHalfHeightPct: kBtcZoneHalfHeightPct,
      touchTolerancePct: kBtcSignalTouchTolerancePct,
    );
    legacy.addBox(const DetectedZone(true, 60000, 3, halfHeight: 11.5), 1000,
        price: 60000);
    await legacy.save(prefs);
    expect(prefs.getString('sona_btc_signal_boxes_v1'), isNotNull);
    // The AI-qualified series reads a different key, so those unqualified
    // boxes can never resurface under the AI-checked disclosure.
    expect(kBtcSignalPrefsKey, isNot('sona_btc_signal_boxes_v1'));
    final m = SignalBoxManager(prefsKey: kBtcSignalPrefsKey);
    await m.load(prefs);
    expect(m.boxes, isEmpty);
  });

  test('offsets follow the creation price, not a fixed anchor', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final m = SignalBoxManager(
      prefsKey: kBtcSignalPrefsKey,
      targetPct: kBtcSignalTargetPct,
      invalidationPct: kBtcSignalInvalidationPct,
      zoneHalfHeightPct: kBtcZoneHalfHeightPct,
      touchTolerancePct: kBtcSignalTouchTolerancePct,
    );
    m.addBox(const DetectedZone(true, 60000, 3, halfHeight: 11.5), 1000,
        price: 60000);
    m.addBox(const DetectedZone(true, 70000, 3, halfHeight: 13.5), 2000,
        price: 70000);
    final cheap = m.boxes[0];
    final dear = m.boxes[1];
    // Same rule, different creation prices -> different stamped offsets.
    expect(cheap.targetOffset, closeTo(60000 * 3.0 / 3900.0, 0.001));
    expect(dear.targetOffset, closeTo(70000 * 3.0 / 3900.0, 0.001));
    expect(dear.targetOffset, greaterThan(cheap.targetOffset));
    // And once stamped they survive a reload unchanged.
    await m.save(prefs);
    final m2 = SignalBoxManager(prefsKey: kBtcSignalPrefsKey);
    await m2.load(prefs);
    expect(m2.boxes[0].targetOffset, cheap.targetOffset);
    expect(m2.boxes[1].invalidationOffset, dear.invalidationOffset);
  });
}
