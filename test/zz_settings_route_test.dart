import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sona/main.dart';
import 'package:sona/market_data/candle_debug.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/market_data/twelve_data_candles.dart';
import 'package:sona/practice_screen.dart';
import 'package:sona/chart_diagnostics.dart';

import 'screens_test.dart' show loadFonts, demoState, testCandles;

/// Production-route gate: the entries must be reachable from the real root
/// widget (chromeless chart configuration), not only from the desktop-chrome
/// toolbar that release builds tree-shake. Pumps the actual Root, opens the
/// actual settings screen via the trade-tab gear, and taps the entry.
Future<void> _openSettings(WidgetTester t) async {
  FlutterSecureStorage.setMockInitialValues({});
  SharedPreferences.setMockInitialValues({});
  PackageInfo.setMockInitialValues(
    appName: 'Sona',
    packageName: 'com.ambi.gold_paper_trading',
    version: '1.2.15',
    buildNumber: '117',
    buildSignature: '',
  );
  await loadFonts();
  await t.binding.setSurfaceSize(const Size(390, 844));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: Root(testApp: demoState(), candleLoaderOverride: testCandles),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 300));
  expect(find.byIcon(Icons.settings_outlined), findsWidgets);
  await t.tap(find.byIcon(Icons.settings_outlined).first);
  await t.pumpAndSettle();
  expect(find.byType(SonaSettingsScreen), findsOneWidget);
}

void main() {
  testWidgets('settings routes to practice replay', (t) async {
    await _openSettings(t);
    await t.scrollUntilVisible(
      find.text('Practice replay'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('Practice replay'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(PracticeScreen), findsOneWidget);
  });

  testWidgets('settings routes to chart diagnostics', (t) async {
    await _openSettings(t);
    await t.scrollUntilVisible(
      find.text('Chart diagnostics'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('Chart diagnostics'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChartDiagnosticsScreen), findsOneWidget);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.text('Chart diagnostics'), findsWidgets);
    // Missing live state must read as unknown, never as a false
    // "provider bars untouched" or a numeric zero.
    expect(find.textContaining('unknown from this screen'), findsWidgets);
  });

  testWidgets('panel shows the shared sink fed by the real service, redacted',
      (t) async {
    const fakeKey = 'FAKEKEY1234567890ABCDEF';
    final service = TwelveDataCandleService(
      apiKey: fakeKey,
      client: MockClient((req) async => http.Response(
          '{"status":"ok","values":[{"datetime":"2026-10-31 04:30:00","open":"3875.31","high":"3875.50","low":"3875.20","close":"3875.44","note":"$fakeKey"},{"datetime":"2026-10-31 04:45:00","open":"3875.44","high":"3875.60","low":"3875.30","close":"3875.52"}]}',
          200)),
    );
    await service.fetchCandles(Instrument.xauUsd);
    expect(CandleDebugSink.source, 'twelvedata');
    expect(CandleDebugSink.totalValues, 2);

    await _openSettings(t);
    await t.scrollUntilVisible(
      find.text('Chart diagnostics'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.tap(find.text('Chart diagnostics'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(ChartDiagnosticsScreen), findsOneWidget);
    expect(find.text('twelvedata'), findsWidgets);
    expect(find.text('2'), findsWidgets);
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('3875.31'), findsWidgets);
    expect(find.textContaining(fakeKey), findsNothing);
    expect(find.textContaining('[redacted]'), findsWidgets);
  });
}
