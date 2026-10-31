import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/chart_diagnostics.dart';
import 'package:sona/market_data/candle_debug.dart';

/// The diagnostics list must let the user reach the Copy action.
void main() {
  testWidgets('Copy report reachable by scrolling', (tester) async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') return null;
      return null;
    });
    PackageInfo.setMockInitialValues(
      appName: 'Sona',
      packageName: 'com.ambi.gold_paper_trading',
      version: '1.2.15',
      buildNumber: '116',
      buildSignature: '',
    );
    SharedPreferences.setMockInitialValues({});
    CandleDebugSink.recordFetch(
      sourceName: 'twelvedata',
      values: [
        for (var i = 0; i < 59; i++)
          {
            'datetime': '2026-10-31 04:00:00',
            'open': '3875.31',
            'high': '3875.50',
            'low': '3875.28',
            'close': '3875.44',
          },
      ],
    );
    addTearDown(CandleDebugSink.clear);
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: ChartDiagnosticsScreen(
        snapshot: ChartMarketSnapshot(price: 3876.396, fresh: false),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Copy report'), findsNothing); // below the fold initially
    await tester.scrollUntilVisible(find.text('Copy report'), 300,
        scrollable: find.byType(Scrollable).first);
    await tester.pumpAndSettle();
    expect(find.text('Copy report'), findsOneWidget);
    await tester.ensureVisible(find.text('Copy report'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Copy report'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    expect(find.text('Diagnostics copied'), findsOneWidget);
  });
}
