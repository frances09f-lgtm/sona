import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/technical_gauge.dart';
import 'package:sona/technical_summary.dart';
import 'package:sona/technical_summary_card.dart';

/// Visual-capture aid, NOT a release gate: renders the gauge and the full
/// technical-summary card (as placed in the AI tab: cCard container, 14
/// padding) across its real states so the build pipeline can upload the
/// PNGs for pixel inspection and user preview. Runs only with
/// GAUGE_CAPTURE=1 (a CI step passes --update-goldens); in the normal
/// suite every test here is a no-op so nothing gates on golden files.
void main() {
  final capture = Platform.environment['GAUGE_CAPTURE'] == '1';
  final fixedNow = DateTime(2026, 10, 30, 19, 25);

  TechnicalSummary fixture(TechRating r, double score,
      {int buy = 9, int neutral = 3, int sell = 5, int skipped = 0}) {
    final votes = <IndicatorVote>[
      for (int i = 0; i < buy; i++) IndicatorVote('B$i', 1, 'd'),
      for (int i = 0; i < neutral; i++) IndicatorVote('N$i', 0, 'd'),
      for (int i = 0; i < sell; i++) IndicatorVote('S$i', -1, 'd'),
    ];
    final half = (votes.length / 2).ceil();
    return TechnicalSummary(
      rating: r,
      score: score,
      oscillators: votes.sublist(0, half),
      movingAverages: votes.sublist(half),
      skippedCount: skipped,
    );
  }

  Widget cardShell(TechnicalSummaryCardView view) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: 360,
            child: Card(
              color: const Color(0xFF171A21),
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: view,
              ),
            ),
          ),
        ),
      ),
    );
  }

  final cardCases = <String, TechnicalSummaryCardView>{
    'card-buy-forming': TechnicalSummaryCardView(
      chip: '15m',
      summary: fixture(TechRating.buy, 0.3),
      asOf: DateTime(2026, 10, 30, 19, 15),
      now: () => fixedNow,
    ),
    'card-strong-sell-completed': TechnicalSummaryCardView(
      chip: '15m',
      summary: fixture(TechRating.strongSell, -0.8, buy: 2, sell: 13),
      asOf: DateTime(2026, 10, 30, 18, 45),
      now: () => fixedNow,
    ),
    'card-neutral-low-data': TechnicalSummaryCardView(
      chip: '15m',
      summary: fixture(TechRating.neutral, 0.0,
          buy: 6, neutral: 5, sell: 4, skipped: 4),
      asOf: DateTime(2026, 10, 30, 19, 15),
      now: () => fixedNow,
    ),
    'card-market-quiet': TechnicalSummaryCardView(
      chip: '15m',
      summary: fixture(TechRating.sell, -0.3, buy: 4, sell: 10),
      asOf: DateTime(2026, 10, 30, 21, 45),
      marketQuiet: true,
      now: () => DateTime(2026, 10, 31, 10, 0), // Saturday
    ),
    'card-disconnected': TechnicalSummaryCardView(
      chip: '15m',
      error: 'DISCONNECTED - twelvedata error: API credits exhausted for the day. Showing the last read.',
      summary: fixture(TechRating.buy, 0.2),
      asOf: DateTime(2026, 10, 30, 19, 0),
      now: () => fixedNow,
    ),
    'card-insufficient': TechnicalSummaryCardView(
      chip: '15m',
      summary: const TechnicalSummary(
        rating: TechRating.neutral,
        score: 0,
        oscillators: [],
        movingAverages: [],
        insufficientReason: 'Need at least 60 candles, have 30',
      ),
      asOf: DateTime(2026, 10, 30, 19, 15),
      now: () => fixedNow,
    ),
    'card-key-missing': const TechnicalSummaryCardView(
      chip: '15m',
      keyMissing: true,
    ),
  };

  for (final entry in cardCases.entries) {
    testWidgets('capture ${entry.key}', (tester) async {
      if (!capture) return;
      // Taller than the default 800x600 surface so tall states (error +
      // as-of + quiet note) lay out fully; the golden frames the card view
      // itself, so surface size does not change the image.
      await tester.binding.setSurfaceSize(const Size(420, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(cardShell(entry.value));
      await expectLater(
        find.byType(TechnicalSummaryCardView),
        matchesGoldenFile('goldens/${entry.key}.png'),
      );
    });
  }

  // Isolated arcs at all five ratings (needle positions).
  final gaugeCases = <(String, TechRating, double)>[
    ('gauge-strong-sell', TechRating.strongSell, -0.8),
    ('gauge-sell', TechRating.sell, -0.3),
    ('gauge-neutral', TechRating.neutral, 0.0),
    ('gauge-buy', TechRating.buy, 0.3),
    ('gauge-strong-buy', TechRating.strongBuy, 0.8),
  ];
  for (final (name, rating, score) in gaugeCases) {
    testWidgets('capture $name', (tester) async {
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
        matchesGoldenFile('goldens/$name.png'),
      );
    });
  }
}
