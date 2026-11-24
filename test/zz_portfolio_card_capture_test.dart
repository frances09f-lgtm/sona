import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';
import 'package:sona/orion.dart' as zo;

import 'screens_test.dart' show demoState, loadFonts;

/// Visual-capture aid, NOT a release gate: renders the expanded open-position
/// card (mint pastel) in dark and light palettes at real phone metrics so the
/// PNGs can be pixel-inspected for label/value/footnote/switch-thumb contrast.
/// No-op unless PORTFOLIO_CARD_CAPTURE=1 (mirrors the practice capture
/// pattern). Fixture data only; never shipped to the user build.
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
  final capture = Platform.environment['PORTFOLIO_CARD_CAPTURE'] == '1';

  testWidgets('expanded position card contrast, dark and light palettes',
      (t) async {
    if (!capture) return;
    // Tall viewport: the expanded card must fit WITHOUT scrolling so the
    // TP/SL switch thumbs render inside the RepaintBoundary.
    t.view.physicalSize = const Size(780, 2700);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    addTearDown(() => zo.O.applyLight(false));
    await loadFonts();

    AppState build() {
      // One open position with a TP set (switch ON) and SL unset (switch
      // OFF) so both thumb states render; expand it up front.
      final app = demoState();
      app.positions = [app.positions.first];
      app.expanded.add(app.positions.first['id'] as String);
      return app;
    }

    final key = GlobalKey();
    Widget frame(AppState app) => RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            home: Scaffold(body: SafeArea(child: PositionsTab(app: app))),
          ),
        );

    zo.O.applyLight(false);
    await t.pumpWidget(frame(build()));
    await t.pumpAndSettle();
    expect(find.text('Order ID'), findsOneWidget);
    await _capture(t, key, 'portfolio-card-dark');

    zo.O.applyLight(true);
    await t.pumpWidget(frame(build()));
    await t.pumpAndSettle();
    expect(find.text('Order ID'), findsOneWidget);
    await _capture(t, key, 'portfolio-card-light');
  });
}
