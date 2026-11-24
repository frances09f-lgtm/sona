import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';

/// FIXTURE pixel evidence for the Nov 24 2026 "Deriv style" chart skin
/// (mint/rose candles, approved as an added style option). This renders
/// the REAL CandleChartPanel + CandlePainter code from the minted build
/// against fixture candles, never live market data:
/// - Bars: the verbatim provider pull from the user's account
///   (test/fixtures/xau_15m_nov13_15.json), a real Friday session.
/// - No keys, accounts or device data exist in the test process.
///
/// Captures (run with DERIV_STYLE_CAPTURE=1 and --update-goldens; goldens
/// land in test/goldens/deriv_style_fixture*.png):
/// - deriv_style_fixture_classic.png: the SAME window in the unchanged
///   classic skin, for side-by-side comparison.
/// - deriv_style_fixture.png: the same window after 4 cycleChartStyle()
///   calls (the exact path the toolbar button takes) selects derivCandles.
///
/// The always-on test below also proves the style SURVIVES the persist /
/// restore round-trip (layoutSnapshot -> applyPreset, the same snapshot
/// contract used across app restarts), not only the 4 taps.

Future<void> loadFonts() async {
  final roboto = FontLoader('Roboto')
    ..addFont(rootBundle.load('assets/fonts/Roboto.ttf'));
  await roboto.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('assets/fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

List<Candle> fixtureSession() {
  final raw = jsonDecode(
      File('test/fixtures/xau_15m_nov13_15.json').readAsStringSync());
  final values = (raw['values'] as List).cast<Map<String, dynamic>>();
  final out = <Candle>[
    for (final v in values)
      Candle(
        time: DateTime.parse(
            '${(v['datetime'] as String).replaceFirst(' ', 'T')}Z').toLocal(),
        open: double.parse(v['open'] as String),
        high: double.parse(v['high'] as String),
        low: double.parse(v['low'] as String),
        close: double.parse(v['close'] as String),
      ),
  ]..sort((a, b) => a.time.compareTo(b.time));
  return out;
}

Widget harness(List<Candle> data, double quote) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(brightness: Brightness.dark, fontFamily: 'Roboto'),
    home: Scaffold(
      backgroundColor: const Color(0xFF0F1115),
      body: Center(
        child: SizedBox(
          width: 390,
          height: 480,
          child: CandleChartPanel(
            loader: (iv) async => data,
            livePrice: quote,
            marketSnapshot: () => ChartMarketSnapshot(
              price: quote,
              bid: quote,
              ask: quote + 0.67,
            ),
          ),
        ),
      ),
    ),
  );
}

/// Privacy guard identical to the weekend-sparse fixture capture: every
/// widget-layer string must be plain chart/market text. Canvas-painted
/// axis labels carry only fixture prices/dates by construction.
void assertFixtureOnlyText() {
  final forbidden = RegExp(
      '(@|apikey|api_key|token|bearer|secret|\\+?\\d[\\d ]{8,}\\d|[0-9a-f]{24,})',
      caseSensitive: false);
  final identity =
      RegExp('abhi|ambi|frances|nord|oneplus', caseSensitive: false);
  for (final el in find.byType(Text).evaluate()) {
    final t = (el.widget as Text).data ?? '';
    expect(forbidden.hasMatch(t), isFalse, reason: 'forbidden text: \$t');
    expect(identity.hasMatch(t), isFalse, reason: 'identity text: \$t');
  }
}

void main() {
  final capture = Platform.environment['DERIV_STYLE_CAPTURE'] == '1';

  testWidgets('Deriv style fixture render: mint/rose skin pixels, '
      'classic skin unchanged on the same window (fixture)', (tester) async {
    if (!capture) return;
    await loadFonts();
    final data = fixtureSession();
    final quote = data.last.close + 1.5;

    // Classic default on the same window (comparison baseline).
    await tester.pumpWidget(harness(data, quote));
    await tester.pumpAndSettle();
    CandleChartPanelState state() => tester
        .state<CandleChartPanelState>(find.byType(CandleChartPanel));
    CandlePainter painter() => tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((c) => c.painter)
        .whereType<CandlePainter>()
        .first;
    expect(state().chartStyle, ChartStyle.candles);
    expect(painter().bullC, CandlePainter.bull);
    assertFixtureOnlyText();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/deriv_style_fixture_classic.png'));

    // The toolbar button path: 4 cycles land on derivCandles.
    for (var i = 0; i < 4; i++) {
      state().cycleChartStyle();
      await tester.pump();
    }
    await tester.pumpAndSettle();
    expect(state().chartStyle, ChartStyle.derivCandles);
    expect(painter().bullC, CandlePainter.derivBull);
    expect(painter().bearC, CandlePainter.derivBear);
    expect(CandlePainter.derivBull, const Color(0xFF55C89B));
    expect(CandlePainter.derivBear, const Color(0xFFE0748C));
    assertFixtureOnlyText();
    await expectLater(find.byType(CandleChartPanel),
        matchesGoldenFile('goldens/deriv_style_fixture.png'));
  });

  testWidgets('Deriv style survives the persist/restore round-trip '
      '(layoutSnapshot -> applyPreset)', (tester) async {
    await loadFonts();
    final data = fixtureSession();
    await tester.pumpWidget(harness(data, data.last.close));
    await tester.pumpAndSettle();
    final state = tester
        .state<CandleChartPanelState>(find.byType(CandleChartPanel));
    for (var i = 0; i < 4; i++) {
      state.cycleChartStyle();
      await tester.pump();
    }
    expect(state.chartStyle, ChartStyle.derivCandles);
    final snap = state.layoutSnapshot();
    expect(snap['chartStyle'], 'derivCandles');

    // Fresh panel restored from the snapshot, as on the next app launch.
    await tester.pumpWidget(harness(data, data.last.close));
    await tester.pumpAndSettle();
    final restored = tester
        .state<CandleChartPanelState>(find.byType(CandleChartPanel));
    expect(restored.chartStyle, ChartStyle.candles); // fresh default
    restored.applyPreset(snap);
    await tester.pump();
    expect(restored.chartStyle, ChartStyle.derivCandles);
    final painter = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((c) => c.painter)
        .whereType<CandlePainter>()
        .first;
    expect(painter.bullC, CandlePainter.derivBull);
    expect(painter.bearC, CandlePainter.derivBear);
  });
}
