import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/orion.dart' as zo;

import 'screens_test.dart' show loadFonts;

/// Visual-capture aid, NOT a release gate: renders the Orion bottom dock at
/// real phone metrics in three states (Trade selected, mid-slide after 100ms
/// of the 200ms pill animation, Portfolio selected) so the PNGs can be
/// pixel-inspected for bar size, pill containment and slide smoothness.
/// No-op unless DOCK_CAPTURE=1 (mirrors the portfolio-card capture pattern).
Future<void> _capture(WidgetTester t, GlobalKey key, String name) async {
  await t.runAsync(() async {
    final image =
        await (key.currentContext!.findRenderObject() as RenderRepaintBoundary)
            .toImage(pixelRatio: 2);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    await File('/tmp/sona-$name-synthetic.png')
        .writeAsBytes(data!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  final capture = Platform.environment['DOCK_CAPTURE'] == '1';

  testWidgets('orion dock sliding pill, three states', (t) async {
    if (!capture) return;
    t.view.physicalSize = const Size(780, 400);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    await loadFonts();

    const tabs = [
      (Icons.show_chart, 'Trade'),
      (Icons.work_outline, 'Portfolio'),
      (Icons.add, 'Add'),
      (Icons.bar_chart, 'Stats'),
      (Icons.smart_toy_outlined, 'AI'),
    ];

    final key = GlobalKey();
    var index = 0;
    late StateSetter setS;
    Widget frame() => RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: ThemeData.dark(),
            home: Scaffold(
              backgroundColor: zo.O.bg,
              body: StatefulBuilder(
                builder: (c, s) {
                  setS = s;
                  return Center(
                    child: zo.ODock(index: index, onChanged: (i) {}, tabs: tabs),
                  );
                },
              ),
            ),
          ),
        );

    await t.pumpWidget(frame());
    await t.pumpAndSettle();
    await _capture(t, key, 'dock-trade');

    setS(() => index = 1);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await _capture(t, key, 'dock-slide');

    await t.pumpAndSettle();
    await _capture(t, key, 'dock-portfolio');
  });
}
