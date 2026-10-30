import 'package:flutter_test/flutter_test.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/technical_summary.dart';

List<Candle> series(List<double> closes) {
  final base = DateTime.utc(2026, 10, 30, 8, 0);
  return [
    for (int i = 0; i < closes.length; i++)
      Candle(
        time: base.add(Duration(minutes: 15 * i)),
        open: closes[i],
        high: closes[i] + 0.5,
        low: closes[i] - 0.5,
        close: closes[i],
      ),
  ];
}

void main() {
  group('computeTechnicalSummary', () {
    test('steady uptrend reads strong buy', () {
      final s = computeTechnicalSummary(
        series([for (int i = 0; i < 250; i++) 3000.0 + i]),
      );
      expect(s.insufficientReason, isNull);
      expect(s.rating, TechRating.strongBuy);
      expect(s.buyCount, greaterThan(s.sellCount));
    });

    test('steady downtrend reads strong sell', () {
      final s = computeTechnicalSummary(
        series([for (int i = 0; i < 250; i++) 3300.0 - i]),
      );
      expect(s.insufficientReason, isNull);
      expect(s.rating, TechRating.strongSell);
      expect(s.sellCount, greaterThan(s.buyCount));
    });

    test('flat market reads neutral, never invents direction', () {
      final s = computeTechnicalSummary(
        series([for (int i = 0; i < 250; i++) 3200.0]),
      );
      expect(s.insufficientReason, isNull);
      expect(s.rating, TechRating.neutral);
    });

    test('too few candles reports insufficiency instead of guessing', () {
      final s = computeTechnicalSummary(
        series([for (int i = 0; i < 30; i++) 3000.0 + i]),
      );
      expect(s.insufficientReason, isNotNull);
      expect(s.rating, TechRating.neutral);
      expect(s.buyCount + s.sellCount + s.neutralCount, 0);
    });

    test('is deterministic over the same candles', () {
      final candles = series([
        for (int i = 0; i < 250; i++) 3000.0 + (i % 7) * 2 - i * 0.1,
      ]);
      final a = computeTechnicalSummary(candles);
      final b = computeTechnicalSummary(candles);
      expect(a.rating, b.rating);
      expect(a.score, b.score);
    });
  });

  group('techBucketForScore', () {
    test('maps the five buckets at their boundaries', () {
      expect(techBucketForScore(1.0), TechRating.strongBuy);
      expect(techBucketForScore(0.5), TechRating.strongBuy);
      expect(techBucketForScore(0.1), TechRating.buy);
      expect(techBucketForScore(0.0), TechRating.neutral);
      expect(techBucketForScore(-0.09), TechRating.neutral);
      expect(techBucketForScore(-0.1), TechRating.sell);
      expect(techBucketForScore(-0.49), TechRating.sell);
      expect(techBucketForScore(-0.5), TechRating.strongSell);
      expect(techBucketForScore(-1.0), TechRating.strongSell);
    });
  });
}
