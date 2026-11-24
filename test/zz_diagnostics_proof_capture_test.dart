import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart_diagnostics.dart';
import 'package:sona/main.dart';
import 'package:sona/signal_status.dart';
import 'package:sona/signal_zones.dart';

import 'screens_test.dart' show loadFonts;

// Delivery proof for the Nov 24 diagnostics repair: the Chart
// diagnostics screen must visibly show the separate AI-call outcome and
// the last box actually added. Seeded fixture records, synthetic; the
// screen only reads prefs, nothing here changes app behavior.
void main() {
  testWidgets('diagnostics shows AI outcome and last box added (capture)',
      (t) async {
    await loadFonts();
    final now = DateTime.now().millisecondsSinceEpoch;
    final aiAt = now - 32 * 60000;
    final boxAt = now - 25 * 60000;
    SharedPreferences.setMockInitialValues({
      SignalStatus.prefsKey: jsonEncode({
        'at': now - 2 * 60000,
        'path': 'foreground',
        'outcome': 'gap_wait',
        'cand': 2,
        'buy': 1,
        'sell': 1,
        'key': true,
      }),
      SignalStatus.aiKey: jsonEncode({
        'at': aiAt,
        'path': 'foreground',
        'outcome': 'asked_ai_added',
        'cand': 2,
        'buy': 1,
        'sell': 1,
        'key': true,
      }),
      'tj_signal_qual_last_ms': aiAt,
      SignalBoxManager.defaultPrefsKey: jsonEncode([
        {
          'id': 'bx-proof-1',
          'isBuy': false,
          'low': 3631.04,
          'high': 3632.54,
          'createdAtMs': boxAt,
          'state': 'active',
          'touchedAtMs': null,
          'decidedAtMs': null,
          'evaluatedUpToMs': boxAt,
          'targetOffset': 3.0,
          'invalidationOffset': 1.5,
        },
      ]),
    });
    final key = GlobalKey();
    await t.binding.setSurfaceSize(const Size(412, 915));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      RepaintBoundary(
        key: key,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: buildAppTheme(),
          home: const ChartDiagnosticsScreen(snapshot: null),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.pump(const Duration(milliseconds: 500));
    await t.pumpAndSettle();
    // The new lines must actually be on screen, not only in the report.
    await t.scrollUntilVisible(
      find.textContaining('last AI call result'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.textContaining('last AI call result: asked_ai_added'),
        findsWidgets);
    expect(find.textContaining('last box added:'), findsWidgets);
    expect(find.textContaining('sell, state active'), findsWidgets);
    await t.runAsync(() async {
      final im = await (key.currentContext!.findRenderObject()
              as RenderRepaintBoundary)
          .toImage();
      final b = await im.toByteData(format: ui.ImageByteFormat.png);
      await File('/tmp/sona-diagnostics-proof-synthetic.png')
          .writeAsBytes(b!.buffer.asUint8List());
    });
    expect(t.takeException(), isNull);
  });
}
