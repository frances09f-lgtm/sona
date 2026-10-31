import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/practice_screen.dart';

/// Visual-capture aid, NOT a release gate: renders the practice screen in
/// its question and result states at real phone metrics so the PNGs can be
/// pixel-inspected. No-op unless PRACTICE_CAPTURE=1 (mirrors the gauge
/// capture pattern).
List<Candle> fixture() {
  final t0 = DateTime.utc(2026, 10, 26, 9);
  var price = 3900.0;
  return [
    for (var i = 0; i < 120; i++)
      () {
        final drift = ((i * 7) % 11 - 5) * 0.9 + 1.2;
        final o = price;
        final c = price + drift;
        price = c;
        return Candle(
          time: t0.add(Duration(minutes: 15 * i)),
          open: o,
          high: (o > c ? o : c) + 1.2,
          low: (o < c ? o : c) - 1.2,
          close: c,
        );
      }(),
  ];
}

void main() {
  final capture = Platform.environment['PRACTICE_CAPTURE'] == '1';

  setUpAll(() async {
    if (!capture) return;
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

  Future<void> pumpScreen(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PracticeScreen(loadCandles: () async => fixture(), randomSeed: 7),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('capture question state', (tester) async {
    if (!capture) return;
    await pumpScreen(tester);
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('UP'), findsOneWidget);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_question.png'));
  });

  testWidgets('capture result state', (tester) async {
    if (!capture) return;
    await pumpScreen(tester);
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    await tester.tap(find.text('UP'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('New round'), findsOneWidget);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_result.png'));
  });
}
