import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/chart_diagnostics.dart';
import 'package:sona/market_data/candle_debug.dart';

/// Visual-capture aid, NOT a release gate: renders the diagnostics panel
/// with a seeded weekend-style sink at real phone metrics so the shipped
/// panel can be pixel-inspected. No-op unless DIAG_CAPTURE=1.
void main() {
  final capture = Platform.environment['DIAG_CAPTURE'] == '1';

  setUpAll(() async {
    if (!capture) return;
    final root = Platform.environment['FLUTTER_ROOT'];
    if (root == null) return;
    final dir = Directory('$root/bin/cache/artifacts/material_fonts');
    if (!dir.existsSync()) return;
    final roboto = FontLoader('Roboto');
    final mono = FontLoader('monospace');
    final icons = FontLoader('MaterialIcons');
    for (final f in dir.listSync().whereType<File>()) {
      final name = f.uri.pathSegments.last;
      final data = ByteData.view(f.readAsBytesSync().buffer);
      if (name.startsWith('Roboto')) roboto.addFont(Future.value(data));
      if (name == 'Roboto-Regular.ttf') mono.addFont(Future.value(data));
      if (name.startsWith('MaterialIcons')) icons.addFont(Future.value(data));
    }
    await roboto.load();
    await mono.load();
    await icons.load();
  });

  testWidgets('capture diagnostics panel', (tester) async {
    if (!capture) return;
    PackageInfo.setMockInitialValues(
      appName: 'Sona',
      packageName: 'com.ambi.gold_paper_trading',
      version: '1.2.15',
      buildNumber: '116',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({
      'oro_bridge_snapshot':
          '{"bid":3876.396,"ask":3877.054,"quoteAt":1793397300208}',
    });
    CandleDebugSink.recordFetch(
      sourceName: 'twelvedata',
      secret: '',
      values: [
        for (var i = 0; i < 59; i++)
          {
            'datetime': '2026-10-31 ${(4 + i ~/ 4).toString().padLeft(2, '0')}:${((i % 4) * 15).toString().padLeft(2, '0')}:00',
            'open': i.isEven ? '3875.31' : '3875.44',
            'high': '3875.50',
            'low': '3875.28',
            'close': i.isEven ? '3875.44' : '3875.31',
          },
      ],
    );
    addTearDown(CandleDebugSink.clear);
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: ChartDiagnosticsScreen(
        snapshot: ChartMarketSnapshot(
          price: 3876.396,
          fresh: false,
          bid: 3876.396,
          ask: 3877.054,
          liveTicks: [],
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Chart diagnostics'), findsWidgets);
    await expectLater(find.byType(ChartDiagnosticsScreen),
        matchesGoldenFile('goldens/diagnostics_panel.png'));
  });
}
