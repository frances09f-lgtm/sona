import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/practice_screen.dart';

import 'zz_practice_capture_test.dart' show fixture;

/// Visual-capture aid, NOT a release gate: renders the practice chart in
/// its question state on the fixed 5-minute timeframe (user request
/// Nov 15: "Just do 5 min as default remove others"), so the final screen
/// can be pixel-inspected. No-op unless PRACTICE_CAPTURE=1.
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

  testWidgets('capture question state with timeframe chips', (tester) async {
    if (!capture) return;
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PracticeScreen(loadCandles: (iv) async => fixture(), randomSeed: 7),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('UP'), findsOneWidget);
    expect(find.text('XAU/USD · 5m'), findsOneWidget);
    expect(find.text('15m'), findsNothing);
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_5min.png'));
  });
}
