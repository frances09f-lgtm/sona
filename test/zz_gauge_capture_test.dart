import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/technical_gauge.dart';
import 'package:sona/technical_summary.dart';
import 'package:sona/technical_summary_card.dart';

/// Visual-capture aid, NOT a release gate: renders the gauge and the full
/// technical-summary card across its real states so the build pipeline can
/// upload the PNGs for pixel inspection and user preview. Runs only with
/// GAUGE_CAPTURE=1 (a CI step passes --update-goldens); in the normal
/// suite every test here is a no-op so nothing gates on golden files.
///
/// The card shell reproduces the AI tab in lib/main.dart exactly: a
/// ListView with padding 16 (scrollable, so tall error/quiet states are
/// never clipped - they scroll), a cCard Card with padding 14. The
/// surface is 390x844 logical px, a common Android size, so the content
/// width is the real app width: 390 - 32 - 8 - 28 = 322 px.
const Color cCard = Color(0xFF171A21);
const Color cDim = Color(0xFF8A93A5);

void main() {
  final capture = Platform.environment['GAUGE_CAPTURE'] == '1';
  final fixedNow = DateTime(2026, 10, 30, 19, 25);

  setUpAll(() async {
    if (!capture) return;
    // Real Roboto + MaterialIcons from the SDK; without these, flutter
    // test renders every glyph as an unreadable Ahem block. Load whatever
    // the SDK ships (names differ across versions, so scan the dir).
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root == null) return;
    final dir = Directory('$root/bin/cache/artifacts/material_fonts');
    if (!dir.existsSync()) return;
    final roboto = FontLoader('Roboto');
    final icons = FontLoader('MaterialIcons');
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final data = ByteData.view(f.readAsBytesSync().buffer);
      if (name.startsWith('Roboto')) roboto.addFont(Future.value(data));
      if (name.startsWith('MaterialIcons')) {
        icons.addFont(Future.value(data));
      }
    }
    await roboto.load();
    await icons.load();
  });

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

  Widget phoneShell(List<Widget> children) {
    return MaterialApp(
      theme: ThemeData.dark(),
      home: Scaffold(
        backgroundColor: Colors.black,
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: children,
        ),
      ),
    );
  }

  Widget gaugeCardContainer(Widget child) {
    return Card(
      color: cCard,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: child,
      ),
    );
  }

  Future<void> pumpPhone(
      WidgetTester tester, List<Widget> children) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(phoneShell(children));
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
      error:
          'DISCONNECTED - twelvedata error: API credits exhausted for the day. Showing the last read.',
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
      await pumpPhone(tester, [gaugeCardContainer(entry.value)]);
      await expectLater(
        find.byType(TechnicalSummaryCardView),
        matchesGoldenFile('goldens/${entry.key}.png'),
      );
    });
  }

  // The card in its real AI-section context: the production card widget
  // above the 'AI chart advice' card (same colors, paddings and title as
  // lib/main.dart), framed exactly as a 390x844 phone shows the tab top.
  testWidgets('capture ai-section-context', (tester) async {
    if (!capture) return;
    await pumpPhone(tester, [
      gaugeCardContainer(cardCases['card-buy-forming']!),
      const SizedBox(height: 14),
      const Card(
        color: cCard,
        child: Padding(
          padding: EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.lightbulb_outline, color: cDim, size: 20),
                  SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'AI chart advice',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                  ),
                ],
              ),
              SizedBox(height: 4),
              Text(
                'Reads support/resistance and recent structure, then advises buy, sell or wait. Possibilities from the chart data - not financial advice.',
                style: TextStyle(color: cDim, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    ]);
    await expectLater(
      find.byType(ListView),
      matchesGoldenFile('goldens/ai-section-context.png'),
    );
  });

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
