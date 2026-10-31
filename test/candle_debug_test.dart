import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sona/market_data/candle_debug.dart';
import 'package:sona/market_data/twelve_data_candles.dart';
import 'package:sona/market_data/models.dart';

void main() {
  tearDown(CandleDebugSink.clear);

  http.Client fakeClient(Object body, {int status = 200}) => MockClient(
        (req) async => http.Response(jsonEncode(body), status),
      );

  test('records raw first/last payload bars before parsing', () async {
    final values = [
      for (var i = 0; i < 8; i++)
        {
          'datetime': '2026-10-31 0$i:00:00',
          'open': '3875.3$i',
          'high': '3875.50',
          'low': '3875.28',
          'close': '3875.44',
        },
    ];
    final svc = TwelveDataCandleService(
      apiKey: 'testkey',
      client: fakeClient({'status': 'ok', 'values': values}),
    );
    await svc.fetchCandles(Instrument.xauUsd);

    expect(CandleDebugSink.source, 'twelvedata');
    expect(CandleDebugSink.totalValues, 8);
    expect(CandleDebugSink.fetchAtUtc, isNotNull);
    expect(CandleDebugSink.lastError, isNull);
    // Raw entries are pre-parse JSON of the provider's own values.
    expect(CandleDebugSink.rawHead.length, 3);
    expect(CandleDebugSink.rawHead.first, contains('2026-10-31 00:00:00'));
    expect(CandleDebugSink.rawTail.length, 3);
    expect(CandleDebugSink.rawTail.last, contains('2026-10-31 07:00:00'));
  });

  test('records sanitized errors, never the API key or URLs', () async {
    final svc = TwelveDataCandleService(
      apiKey: 'secretkey1234567890123456789012345',
      client: fakeClient(
        {
          'status': 'error',
          'message':
              'bad key secretkey1234567890123456789012345 see https://api.twelvedata.com/x?apikey=abc',
        },
      ),
    );
    await expectLater(
      svc.fetchCandles(Instrument.xauUsd),
      throwsA(isA<Exception>()),
    );
    final err = CandleDebugSink.lastError!;
    expect(err.contains('secretkey1234567890123456789012345'), isFalse);
    expect(err.contains('https://'), isFalse);
    expect(err.contains('[redacted]'), isTrue);
    expect(CandleDebugSink.rawHead, isEmpty);
  });

  test('http failure records error without key material', () async {
    final svc = TwelveDataCandleService(
      apiKey: 'k',
      client: fakeClient({'x': 1}, status: 429),
    );
    await expectLater(
      svc.fetchCandles(Instrument.xauUsd),
      throwsA(isA<Exception>()),
    );
    expect(CandleDebugSink.lastError, contains('429'));
  });
}
