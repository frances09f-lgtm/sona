import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/practice_screen.dart';

import 'zz_practice_capture_test.dart' show fixture;

/// Visual-capture aid, NOT a release gate: renders the practice chart in
/// its question state after panning back to older candles and after
/// pinch-zooming in, so the Nov 15 chart-control feature can be
/// pixel-inspected. No-op unless PRACTICE_CAPTURE=1.
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

  Future<void> pumpToQuestion(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: ThemeData.dark(),
      home: PracticeScreen(loadCandles: () async => fixture(), randomSeed: 7),
    ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start replay'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 16));
    expect(find.text('UP'), findsOneWidget);
  }

  testWidgets('capture panned-back question state', (tester) async {
    if (!capture) return;
    await pumpToQuestion(tester);
    final chart = find.byWidgetPredicate((w) =>
        w is CustomPaint &&
        w.painter != null &&
        w.painter.runtimeType.toString().contains('PracticeChartPainter'));
    // Drag right: window slides toward older candles (date label moves).
    await tester.drag(chart, const Offset(220, 0));
    await tester.pump();
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_panned.png'));
  });

  testWidgets('capture pinch-zoomed question state', (tester) async {
    if (!capture) return;
    await pumpToQuestion(tester);
    final center = tester.getCenter(find.byType(PracticeScreen));
    // Two fingers closing in: zoom out (more candles on screen).
    final g1 = await tester.startGesture(center.translate(-100, 0));
    final g2 = await tester.startGesture(center.translate(100, 0));
    await g1.moveBy(const Offset(70, 0));
    await g2.moveBy(const Offset(-70, 0));
    await tester.pump();
    await g1.up();
    await g2.up();
    await expectLater(find.byType(PracticeScreen),
        matchesGoldenFile('goldens/practice_zoomed.png'));
  });
}
