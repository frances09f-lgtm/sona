import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/chart/candle_chart.dart';

import 'fullscreen_editor_test.dart' show fakeCandles, loadFonts;

void main() {
  Future<void> pumpPanel(WidgetTester tester, {double? inlineHeight}) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    // Trade-page-like surface: 390x844 logical.
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: Scaffold(
          body: CandleChartPanel(
            loader: (_) async => fakeCandles(120),
            rangeMode: true,
            chromeless: true,
            inlineHeight: inlineHeight,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  double chromelessHeight(WidgetTester tester) {
    final sized = tester.widget<SizedBox>(
      find
          .descendant(
            of: find.byType(CandleChartPanel),
            matching: find.byType(SizedBox),
          )
          .first,
    );
    return sized.height!;
  }

  testWidgets('chromeless inline chart uses explicit inlineHeight when given',
      (tester) async {
    await pumpPanel(tester, inlineHeight: 190);
    expect(chromelessHeight(tester), 190);
  });

  testWidgets(
      'chromeless inline chart keeps baseline sizing without inlineHeight',
      (tester) async {
    // max(0.26 * 844, 230) = 230.
    await pumpPanel(tester);
    expect(chromelessHeight(tester), 230);
  });
}
