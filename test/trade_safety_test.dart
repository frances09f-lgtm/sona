import 'package:flutter_test/flutter_test.dart';
import 'package:sona/trade_safety.dart';
import 'package:sona/analytics.dart';

void main() {
  test('sizes dollars and percent risk without rounding above cap', () {
    expect(quantityForRisk(100, 'buy', 4000, 3990), 10);
    expect(quantityForRisk(100, 'sell', 4000, 4010), 10);
    final q = quantityForRisk(10, 'buy', 4000, 3997)!;
    expect(q * 3, lessThanOrEqualTo(10));
  });

  test('unusable risk inputs fail closed', () {
    for (final amount in [double.nan, double.infinity, -1.0, 0.0]) {
      expect(quantityForRisk(amount, 'buy', 4000, 3990), isNull);
    }
    expect(quantityForRisk(10, 'buy', 4000, 4010), isNull);
    expect(quantityForRisk(10, 'sell', 4000, 3990), isNull);
    expect(quantityForRisk(10, 'buy', 4000, 4000), isNull);
    expect(quantityForRisk(10, 'buy', 4000, null), isNull);
    expect(riskQty(double.nan, 4000, 3990), isNull);
  });

  test('directional limits finite and positive', () {
    expect(validateProtection('buy', 4000, 4010, 3990), isNull);
    expect(validateProtection('sell', 4000, 3990, 4010), isNull);
    for (final level in [0.0, -1.0, double.nan, double.infinity, 4000.0]) {
      expect(validateProtection('buy', 4000, level, null), isNotNull);
      expect(validateProtection('sell', 4000, null, level), isNotNull);
    }
  });

  test('preview loss/gain/exposure are quantity aware', () {
    final p = OrderPreview('buy', 4000, 2, 3990, 4020);
    expect(p.loss, 20);
    expect(p.gain, 40);
    expect(p.exposure, 8000);
    expect(p.rewardRisk, 2);
    expect(p.lossPercent, closeTo(0.25, 0.001));
    expect(p.gainPercent, closeTo(0.5, 0.001));
  });

  test('quotes missing timestamp stale crossed non-finite future rejected', () {
    const now = 1000000;
    expect(freshExecutionQuote(4000, 4001, now, now), isTrue);
    expect(freshExecutionQuote(4000, 4001, 0, now), isFalse);
    expect(freshExecutionQuote(4000, 4001, now - 60001, now), isFalse);
    expect(freshExecutionQuote(4000, 4001, now + 5001, now), isFalse);
    expect(freshExecutionQuote(4002, 4001, now, now), isFalse);
    expect(freshExecutionQuote(double.nan, 4001, now, now), isFalse);
  });

  test('exit side hit and adverse conflict choose stop', () {
    expect(protectionTrigger('buy', 3990, 4020, 3990), 'SL hit');
    expect(protectionTrigger('sell', 3990, 3990, 4020), 'TP hit');
    expect(protectionTrigger('buy', 4000, 3999, 4001), 'SL hit');
    expect(protectionTrigger('buy', double.nan, 3999, 4001), isNull);
    expect(protectionTrigger('buy', 4000, 4020, 3990), isNull);
  });
}
