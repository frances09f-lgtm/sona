import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';
import 'package:sona/trade_card.dart';

import 'screens_test.dart' show demoState, loadFonts;

class CompactAccount extends AppState {
  int closes = 0;
  @override
  Future<String?> closePaper(
    Map<String, dynamic> position, {
    String? reason,
  }) async {
    closes++;
    return null;
  }
}

Future<void> capture(WidgetTester t, GlobalKey key, String name) async {
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
  testWidgets(
    'open cards start compact, expand independently and retain close confirmation',
    (t) async {
      t.view.physicalSize = const Size(780, 1688);
      t.view.devicePixelRatio = 2;
      addTearDown(t.view.reset);
      await loadFonts();
      final fixture = demoState();
      final app = CompactAccount()
        ..price = fixture.price
        ..bid = fixture.bid
        ..ask = fixture.ask
        ..priceAt = DateTime.now().millisecondsSinceEpoch
        ..priceOk = true
        ..positions = fixture.positions;
      final key = GlobalKey();
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            home: Scaffold(
              body: SafeArea(child: PositionsTab(app: app)),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();
      final first = find.byKey(
        ValueKey('open-position-${app.positions.first['id']}'),
      );
      expect(t.getSize(first).height, lessThan(70));
      expect(find.text('GOLD'), findsNWidgets(3));
      expect(find.byType(TradeExplanationCard), findsNothing);
      expect(find.textContaining('Close Trade:'), findsNothing);
      expect(
        find.textContaining('always-on server protection is not deployed'),
        findsOneWidget,
      );
      await capture(t, key, 'compact');
      await t.tap(first);
      await t.pumpAndSettle();
      expect(app.expanded.length, 1);
      expect(find.byType(TradeExplanationCard), findsOneWidget);
      expect(find.textContaining('Close Trade:'), findsOneWidget);
      expect(find.text('Order ID'), findsOneWidget);
      await capture(t, key, 'expanded');
      await t.tap(find.textContaining('Close Trade:'));
      await t.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(app.closes, 0);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(app.closes, 0);
      await t.tap(first);
      await t.pumpAndSettle();
      expect(find.byType(TradeExplanationCard), findsNothing);
      expect(find.textContaining('Close Trade:'), findsNothing);
      // Narrow phone must remain usable without overflows.
      t.view.physicalSize = const Size(640, 1280);
      await t.pumpAndSettle();
      expect(t.takeException(), isNull);
      await capture(t, key, 'compact-narrow');
      app.dispose();
    },
  );
}
