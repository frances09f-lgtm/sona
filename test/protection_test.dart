import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/ai_brain.dart';
import 'package:sona/protection.dart';
import 'package:sona/protection_screen.dart';

/// The pre-1.2.11 rule (floor 0.3%, default 0.6%, cap 2%, TP >= 1.5R),
/// kept here only to show the before/after on the same numbers.
(double, double) legacyTargets(bool up, double ref, double? sl, double? tp) {
  const minStop = 0.003, maxStop = 0.02;
  if (sl == null || (up ? sl >= ref : sl <= ref)) {
    sl = up ? ref * (1 - 0.006) : ref * (1 + 0.006);
  } else {
    final dist = (ref - sl).abs() / ref;
    if (dist < minStop) sl = up ? ref * (1 - minStop) : ref * (1 + minStop);
    if (dist > maxStop) sl = up ? ref * (1 - maxStop) : ref * (1 + maxStop);
  }
  final risk = (ref - sl).abs();
  if (tp == null || (up ? tp <= ref : tp >= ref) || (tp - ref).abs() < 1.5 * risk) {
    tp = up ? ref + 1.5 * risk : ref - 1.5 * risk;
  }
  return (sl, tp);
}

void expectSides(Protection p, bool buy, double entry) {
  if (buy) {
    expect(p.sl, lessThan(entry), reason: 'buy SL below entry');
    expect(p.tp, greaterThan(entry), reason: 'buy TP above entry');
  } else {
    expect(p.sl, greaterThan(entry), reason: 'sell SL above entry');
    expect(p.tp, lessThan(entry), reason: 'sell TP below entry');
  }
}

void main() {
  const eps = 1e-6;

  group('gold XAU/USD (tick 0.01)', () {
    final tick = tickSizeFor('XAU/USD');
    test('tick', () => expect(tick, 0.01));

    test('buy at 4,038.40 with 15m ATR \$8: SL 9.60 below, TP 14.40 above', () {
      final p = computeProtection(buy: true, entry: 4038.40, atr: 8, tick: tick);
      expect(p.sl, closeTo(4028.80, eps));
      expect(p.tp, closeTo(4052.80, eps));
      expect(p.source, 'atr');
      expectSides(p, true, 4038.40);
    });

    test('sell at 4,038.00 with 15m ATR \$8: SL 9.60 above, TP 14.40 below', () {
      final p = computeProtection(buy: false, entry: 4038.00, atr: 8, tick: tick);
      expect(p.sl, closeTo(4047.60, eps));
      expect(p.tp, closeTo(4023.60, eps));
      expectSides(p, false, 4038.00);
    });

    test('5m ATR \$4.30 (measured): stop 5.16, target 7.74', () {
      final p = computeProtection(buy: true, entry: 4038.40, atr: 4.30, tick: tick);
      expect(4038.40 - p.sl, closeTo(5.16, 0.006));
      expect(p.tp - 4038.40, closeTo(7.74, 0.006));
    });

    test('a huge ATR is capped at 0.5% of price', () {
      final p = computeProtection(buy: true, entry: 4038.40, atr: 30, tick: tick);
      expect(p.sl, closeTo(4018.21, eps)); // 4038.40 - 20.19
      expect(p.source, 'atr+cap');
      expect(p.tp - 4038.40, closeTo(1.5 * (4038.40 - p.sl), 0.011));
    });

    test('before vs after on the same gold trade', () {
      // Before: AI gave no usable stop -> 0.6% default.
      final (oldSl, oldTp) = legacyTargets(true, 4038.40, null, null);
      expect(4038.40 - oldSl, closeTo(24.23, 0.01));
      expect(oldTp - 4038.40, closeTo(36.35, 0.01));
      // Before: AI chose a $6 structure stop -> floored to 0.3% ($12.12).
      final (oldSl2, oldTp2) = legacyTargets(true, 4038.40, 4032.40, 4047.40);
      expect(4038.40 - oldSl2, closeTo(12.12, 0.01));
      expect(oldTp2 - 4038.40, closeTo(18.17, 0.01));
      // After, 15m ATR $8: rule 9.60 / 14.40, AI's $6 stop kept -> 6 / 9.
      final a = computeProtection(buy: true, entry: 4038.40, atr: 8);
      expect(4038.40 - a.sl, closeTo(9.60, eps));
      expect(a.tp - 4038.40, closeTo(14.40, eps));
      final b = computeProtection(buy: true, entry: 4038.40, atr: 8, aiStop: 4032.40);
      expect(b.sl, closeTo(4032.40, eps));
      expect(b.tp, closeTo(4047.40, eps));
      expect(b.source, 'ai');
    });

    test('AI stop wider than the rule is cut to the rule', () {
      final p = computeProtection(buy: false, entry: 4038.00, atr: 8, aiStop: 4090);
      expect(p.sl, closeTo(4047.60, eps));
      expect(p.source, 'atr');
    });

    test('AI stop on the wrong side or under half an ATR is ignored', () {
      final wrong = computeProtection(buy: true, entry: 4038.40, atr: 8, aiStop: 4045);
      expect(wrong.sl, closeTo(4028.80, eps));
      final tiny = computeProtection(buy: true, entry: 4038.40, atr: 8, aiStop: 4036.40);
      expect(tiny.sl, closeTo(4028.80, eps)); // $2 < half ATR ($4)
    });

    test('no candles (no ATR) falls back to 0.25% of price', () {
      final p = computeProtection(buy: true, entry: 4000, atr: null);
      expect(p.sl, closeTo(3990, eps));
      expect(p.tp, closeTo(4015, eps));
      expect(p.source, 'percent');
    });
  });

  group('forex EUR/USD (tick 0.00001)', () {
    final tick = tickSizeFor('EUR/USD');
    test('tick', () {
      expect(tick, 0.00001);
      expect(tickSizeFor('USDJPY'), 0.001);
    });
    test('buy 1.08500, 15m ATR 0.00092 (9.2 pips)', () {
      final p = computeProtection(buy: true, entry: 1.08500, atr: 0.00092, tick: tick);
      expect(p.sl, closeTo(1.08390, 1e-9));
      expect(p.tp, closeTo(1.08666, 1e-9));
      expectSides(p, true, 1.085);
    });
    test('sell 1.08490', () {
      final p = computeProtection(buy: false, entry: 1.08490, atr: 0.00092, tick: tick);
      expect(p.sl, closeTo(1.08600, 1e-9));
      expect(p.tp, closeTo(1.08324, 1e-9));
      expectSides(p, false, 1.0849);
    });
  });

  group('index NAS100 (tick 0.1)', () {
    final tick = tickSizeFor('NAS100', price: 20000);
    test('tick', () => expect(tick, 0.1));
    test('buy 20,000, 15m ATR 40', () {
      final p = computeProtection(buy: true, entry: 20000, atr: 40, tick: tick);
      expect(p.sl, closeTo(19952.0, eps));
      expect(p.tp, closeTo(20072.0, eps));
      expectSides(p, true, 20000);
    });
    test('sell 20,000, 15m ATR 40', () {
      final p = computeProtection(buy: false, entry: 20000, atr: 40, tick: tick);
      expect(p.sl, closeTo(20048.0, eps));
      expect(p.tp, closeTo(19928.0, eps));
      expectSides(p, false, 20000);
    });
  });

  group('settings', () {
    test('percent mode and a 1:2 reward:risk', () {
      const s = ProtectionSettings(mode: StopMode.percent, stopPct: 0.2, riskReward: 2);
      final p = computeProtection(buy: false, entry: 4000, atr: 8, settings: s);
      expect(p.sl, closeTo(4008, eps));
      expect(p.tp, closeTo(3984, eps));
    });
    test('ATR multiple 1.5', () {
      const s = ProtectionSettings(atrMultiple: 1.5);
      final p = computeProtection(buy: true, entry: 4000, atr: 8, settings: s);
      expect(p.sl, closeTo(3988, eps));
      expect(p.tp, closeTo(4018, eps));
    });
    test('AI stop switch off uses the rule only', () {
      const s = ProtectionSettings(useAiStop: false);
      final p = computeProtection(buy: true, entry: 4000, atr: 8, aiStop: 3994, settings: s);
      expect(p.sl, closeTo(3990.4, eps));
    });
    test('out-of-range values are clamped', () {
      final s = const ProtectionSettings(atrMultiple: 50, riskReward: 0, maxStopPct: 99).sanitized();
      expect(s.atrMultiple, 3.0);
      expect(s.riskReward, 0.5);
      expect(s.maxStopPct, 3.0);
    });
    test('saved and read back through SharedPreferences', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(ProtectionSettings.read(prefs).describe(), ProtectionSettings.defaults.describe());
      await const ProtectionSettings(mode: StopMode.percent, stopPct: 0.3, riskReward: 2).save(prefs);
      final r = ProtectionSettings.read(prefs);
      expect(r.mode, StopMode.percent);
      expect(r.stopPct, 0.3);
      expect(r.riskReward, 2);
      expect(r.describe(), 'SL 0.3% of price, max 0.5% · TP 2R');
    });
    test('defaults describe', () {
      expect(ProtectionSettings.defaults.describe(), 'SL 1.2x ATR(15m), max 0.5% · TP 1.5R');
    });
  });

  group('AI paths use the rule', () {
    test('auto-trade decision: gold sell with ATR', () {
      final d = parseDecision(
        '{"action":"sell","confidence":"high","stop_loss":4080,"take_profit":3950,"size_pct":10,"reason":"x"}',
        buyRef: 4038.4,
        sellRef: 4038.0,
        atr: 8,
      );
      expect(d.sl, closeTo(4047.60, eps));
      expect(d.tp, closeTo(4023.60, eps));
    });
    test('advice sure trade: gold buy with ATR and saved 1:2', () {
      final r = parseAdvice(
        '{"verdict":"buy","confidence":"high","stop_loss":3900,"take_profit":4200,"size_pct":10,"reasons":"x"}',
        buyRef: 4038.4,
        sellRef: 4038.0,
        atr: 8,
        settings: const ProtectionSettings(riskReward: 2),
      );
      expect(r.sl, closeTo(4028.80, eps));
      expect(r.tp, closeTo(4057.60, eps));
    });
  });

  testWidgets('settings screen edits and shows the example', (tester) async {
    SharedPreferences.setMockInitialValues({});
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      home: ProtectionSettingsScreen(examplePrice: 4038.40, exampleAtr: 8),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Stop loss & take profit'), findsOneWidget);
    expect(
      (tester.widget(find.byKey(const Key('prot-example-buy'))) as Text).data,
      'Buy: SL 4028.80 (-\$9.60) · TP 4052.80 (+\$14.40)',
    );
    expect(
      (tester.widget(find.byKey(const Key('prot-example-sell'))) as Text).data,
      'Sell: SL 4048.00 (+\$9.60) · TP 4024.00 (-\$14.40)',
    );
    await tester.tap(find.byKey(const Key('prot-mode-pct')));
    await tester.pumpAndSettle();
    final prefs = await SharedPreferences.getInstance();
    expect(ProtectionSettings.read(prefs).mode, StopMode.percent);
  });
}
