import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sona/auto_trade.dart';
import 'package:sona/ai_brain.dart';

class FixedBrain extends GroqBrain {
  final Future<void> Function()? during;
  FixedBrain(this.during);
  @override
  Future<AiDecision> decide(MarketSnapshot s) async {
    await during?.call();
    return const AiDecision(
      action: 'buy',
      confidence: 'high',
      sl: 4170,
      tp: 4200,
      sizePct: 10,
      reason: 'synthetic fixture',
      raw: '',
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final mode in [
    'full',
    'default',
    'new-position',
    'disabled',
    'rejected',
    'uncertain',
  ]) {
    test(
      'actual background AI cycle $mode obeys refreshed budget and execution constraints',
      () async {
        SharedPreferences.setMockInitialValues({
          'tj_ai_enabled': true,
          'tj_ai_full_balance': mode != 'default',
          'tj_ai_size_pct': 10.0,
          'tj_pin': 'synthetic-not-a-real-account',
        });
        FlutterSecureStorage.setMockInitialValues({
          'oro_groq_key': 'synthetic',
          'oro_twelve_data_key': 'synthetic',
        });
        final prefs = await SharedPreferences.getInstance();
        var stateReads = 0;
        final orders = <Map<String, dynamic>>[];
        final client = MockClient((r) async {
          if (r.url.host == 'forex-data-feed.swissquote.com') {
            return http.Response(
              jsonEncode([
                {
                  'ts': DateTime.now().millisecondsSinceEpoch,
                  'spreadProfilePrices': [
                    {'bid': 4185.0, 'ask': 4186.0},
                  ],
                },
              ]),
              200,
            );
          }
          if (r.url.host == 'api.twelvedata.com') {
            return http.Response(
              jsonEncode({
                'values': [
                  {
                    'datetime': '2026-10-19 07:00:00',
                    'open': '4180',
                    'high': '4190',
                    'low': '4175',
                    'close': '4186',
                  },
                ],
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/paper_state')) {
            stateReads++;
            return http.Response(
              jsonEncode({
                'balance': stateReads == 1 ? 10.0 : 20.0,
                'positions': orders.isNotEmpty && mode != 'rejected'
                    ? [
                        {'id': 'synthetic-position', 'status': 'open'},
                      ]
                    : mode == 'new-position' && stateReads >= 2
                    ? [
                        {'id': 'another-position', 'status': 'open'},
                      ]
                    : [],
              }),
              200,
            );
          }
          if (r.url.path.endsWith('/paper_open')) {
            orders.add(Map<String, dynamic>.from(jsonDecode(r.body) as Map));
            return http.Response(
              mode == 'rejected' ? 'minimum quantity rejected' : '{}',
              mode == 'rejected'
                  ? 400
                  : mode == 'uncertain'
                  ? 500
                  : 200,
            );
          }
          if (r.url.path.endsWith('/app_usage')) {
            return http.Response('{}', 201);
          }
          fail('Unmocked request: ${r.url.host}${r.url.path}');
        });
        final result = await http.runWithClient(
          () => AutoTrade.think(
            prefs,
            manual: true,
            brain: FixedBrain(
              mode == 'disabled'
                  ? () async {
                      await prefs.setBool('tj_ai_enabled', false);
                    }
                  : null,
            ),
          ),
          () => client,
        );
        if (mode == 'new-position' || mode == 'disabled') {
          expect(orders, isEmpty);
        } else {
          expect(orders.length, 1);
          final q = (orders.single['q'] as num).toDouble();
          if (mode == 'default') {
            expect(
              q,
              0.01,
            ); // preserve released 1.0.83 client minimum, unchanged default
          } else {
            expect(q, closeTo(20 / (4186 + 1), 1e-12));
            expect(q * 4187, lessThanOrEqualTo(20.0));
            expect(
              q,
              lessThan(.01),
            ); // never round full-cash mode beyond its budget
          }
          expect(orders.single['stop'], 4170);
          expect(orders.single['target'], 4200);
          if (mode == 'rejected') {
            expect(result, contains('minimum quantity'));
            expect(result, contains('Size was not increased'));
            expect(prefs.getInt('tj_ai_count'), 0);
            expect(prefs.getString('tj_ai_open_id'), isNull);
          }
          if (mode == 'uncertain') {
            expect(result, contains('outcome unknown'));
            expect(prefs.getString('tj_ai_pause'), isNotNull);
            expect(prefs.getInt('tj_ai_count'), 0);
            expect(prefs.getString('tj_ai_open_id'), isNull);
          }
        }
        expect(prefs.getBool('tj_ai_full_balance'), mode != 'default');
      },
    );
  }
}
