import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/provider_day_open.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';

import 'fullscreen_editor_test.dart' show fakeCandles, loadFonts;

void main() {
  String payload(
    String date, {
    String zone = 'Australia/Sydney',
    String open = '3856.33',
  }) => jsonEncode({
    'meta': {'exchange_timezone': zone},
    'values': [
      {'datetime': date, 'open': open},
    ],
  });
  test(
    'uses provider daily open and caches across timeframe callers',
    () async {
      var calls = 0;
      final at = DateTime.utc(2026, 11, 17, 18);
      final service = ProviderDayOpenService(
        now: () => at,
        client: MockClient((r) async {
          calls++;
          expect(r.url.queryParameters['interval'], '1day');
          expect(r.url.queryParameters['outputsize'], '2');
          expect(r.url.queryParameters.containsKey('timezone'), isFalse);
          return http.Response(payload('2026-11-18'), 200);
        }),
      );
      final a = await service.load('fixture');
      final b = await service.load('fixture');
      expect(a, same(b));
      expect(calls, 1);
      expect(a!.open, 3856.33);
      expect(a.percent(3865.20, at, fresh: true), closeTo(0.2300114, .000001));
      expect(a.percent(3865.20, at, fresh: false), isNull);
    },
  );
  test(
    'Sydney session rolls before UTC midnight, no stale previous-day fallback',
    () async {
      var at = DateTime.utc(2026, 11, 17, 12, 59);
      var calls = 0;
      final service = ProviderDayOpenService(
        now: () => at,
        client: MockClient((r) async {
          calls++;
          return http.Response(payload('2026-11-17'), 200);
        }),
      );
      final old = await service.load('fixture');
      expect(old, isNotNull);
      at = DateTime.utc(2026, 11, 17, 13, 1);
      expect(old!.currentAt(at), isFalse);
      expect(await service.load('fixture'), isNull);
      expect(calls, 2);
      expect(await service.load('fixture'), isNull);
      expect(calls, 2);
    },
  );
  test('IANA timezone handles DST instead of fixed offset', () {
    expect(
      ProviderDayOpen.dateAt(
        DateTime.utc(2026, 7, 1, 13, 30),
        'Australia/Sydney',
      ),
      '2026-07-01',
    );
    expect(
      ProviderDayOpen.dateAt(
        DateTime.utc(2026, 11, 1, 13, 30),
        'Australia/Sydney',
      ),
      '2026-11-02',
    );
  });
  test('outage malformed zero future and missing timezone never use intraday fallback', () async {
    final at = DateTime.utc(2026, 11, 17, 18);
    for (final body in [
      '{}',
      payload('2026-11-19'),
      payload('2026-11-18', open: '0'),
      payload('2026-11-18', zone: 'invalid-zone'),
      '{"status":"error"}',
    ]) {
      final service = ProviderDayOpenService(
        now: () => at,
        client: MockClient((_) async => http.Response(body, 200)),
      );
      expect(await service.load('fixture'), isNull);
    }
    final service = ProviderDayOpenService(
      now: () => at,
      client: MockClient((_) async => http.Response('quota', 429)),
    );
    expect(await service.load('fixture'), isNull);
  });
  test(
    'empty key makes no request; error retries only after cooldown',
    () async {
      var calls = 0;
      var at = DateTime.utc(2026, 11, 17, 18);
      final service = ProviderDayOpenService(
        now: () => at,
        client: MockClient((_) async {
          calls++;
          return http.Response('quota', 429);
        }),
      );
      expect(await service.load(''), isNull);
      expect(calls, 0);
      await service.load('fixture');
      await service.load('fixture');
      expect(calls, 1);
      at = at.add(const Duration(minutes: 5));
      await service.load('fixture');
      expect(calls, 2);
    },
  );
  testWidgets(
    'same quote daily change independent of timeframe/history; stale hidden',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      await loadFonts();
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);
      var fresh = true;
      final at = DateTime.now();
      final day = ProviderDayOpen.dateAt(at, 'Australia/Sydney');
      final ref = ProviderDayOpen(3856.33, day, 'Australia/Sydney');
      final update = ValueNotifier(0);
      addTearDown(update.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: FullscreenChartPage(
            loader: (iv) async => fakeCandles(iv == '5min' ? 60 : 120),
            livePrice: 3865.20,
            dayOpenLoader: () async => ref,
            marketUpdates: update,
            marketSnapshot: () => ChartMarketSnapshot(
              price: 3865.20,
              fresh: fresh,
              bid: 3865.20,
              ask: 3865.46,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('TD day +8.87 (+0.23%)'), findsOneWidget);
      await tester.tap(find.text('15m'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('5m'));
      await tester.pumpAndSettle();
      expect(find.text('TD day +8.87 (+0.23%)'), findsOneWidget);
      fresh = false;
      update.value++;
      await tester.pumpAndSettle();
      expect(find.text('Day: unavailable'), findsOneWidget);
      expect(find.textContaining('+0.23%'), findsNothing);
    },
  );
}
