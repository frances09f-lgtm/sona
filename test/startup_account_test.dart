import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'screens_test.dart' show loadFonts;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';

void main() {
  testWidgets(
    'disconnected startup opens trade not PIN and account writes fail honestly',
    (t) async {
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
      await loadFonts();
      final app = AppState();
      final key = GlobalKey();
      await t.binding.setSurfaceSize(const Size(412, 915));
      await t.pumpWidget(
        RepaintBoundary(
          key: key,
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: buildAppTheme(),
            home: Root(testApp: app),
          ),
        ),
      );
      await t.pump(const Duration(milliseconds: 500));
      expect(find.text('Enter your PIN'), findsNothing);
      expect(find.text('SELL'), findsOneWidget);
      expect(
        find.textContaining('Paper account not connected'),
        findsOneWidget,
      );
      expect(
        await app.openPaper('buy', .01, null, null),
        contains('not connected'),
      );
      await t.runAsync(() async {
        final image =
            await (key.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage();
        final d = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/oro-no-startup-pin.png')
            .writeAsBytes(d!.buffer.asUint8List());
      });
      // TEMP-DIAG: capture why the Connect tap misses (revert after diagnosis).
      final diagEl = find.text('Connect').evaluate().single;
      final diagChain = <String>[];
      diagEl.visitAncestorElements((a) {
        diagChain.add(a.widget.toStringShort());
        return true;
      });
      debugPrint('CONNECT_ANCESTORS ' + diagChain.join(' <- '));
      final diagCenter = t.getCenter(find.text('Connect'));
      debugPrint('CONNECT_CENTER ' + diagCenter.toString());
      final diagRoot =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      final diagHit = HitTestResult();
      diagRoot.hitTest(diagHit, position: diagCenter);
      debugPrint('CONNECT_HIT ' +
          diagHit.path.map((e) => e.target.runtimeType.toString()).join(' > '));
      debugDumpApp();
      await t.tap(find.text('Connect'), warnIfMissed: false);
      await t.pump();
      await t.pump(const Duration(milliseconds: 500));
      debugPrint('CONNECT_AFTER_TAP sheet=' +
          find.text('Connect existing paper account').evaluate().length.toString());
      expect(find.text('Connect existing paper account'), findsOneWidget);
    },
  );
}
