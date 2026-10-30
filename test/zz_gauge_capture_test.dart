import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/technical_gauge.dart';
import 'package:sona/technical_summary.dart';

/// Visual-capture aid, NOT a release gate: renders the gauge at all five
/// ratings so the build pipeline can upload the PNGs for pixel inspection.
/// Runs only with GAUGE_CAPTURE=1 (a CI step passes --update-goldens);
/// in the normal suite every test here is a no-op so nothing gates on
/// golden files.
void main() {
  final capture = Platform.environment['GAUGE_CAPTURE'] == '1';
  final cases = <(String, TechRating, double)>[
    ('strong-sell', TechRating.strongSell, -0.8),
    ('sell', TechRating.sell, -0.3),
    ('neutral', TechRating.neutral, 0.0),
    ('buy', TechRating.buy, 0.3),
    ('strong-buy', TechRating.strongBuy, 0.8),
  ];
  for (final (name, rating, score) in cases) {
    testWidgets('gauge capture $name', (tester) async {
      if (!capture) return;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(
            backgroundColor: Colors.black,
            body: Center(
              child: TechnicalGauge(rating: rating, score: score),
            ),
          ),
        ),
      );
      await expectLater(
        find.byType(TechnicalGauge),
        matchesGoldenFile('goldens/gauge-$name.png'),
      );
    });
  }
}
