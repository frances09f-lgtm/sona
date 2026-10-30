import 'package:flutter_test/flutter_test.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/ai_brain.dart';

void main() {
  group('parseDecision', () {
    test('parses a clean buy decision and clamps SL/TP', () {
      final d = parseDecision(
        '{"action":"buy","confidence":"high","stop_loss":3980.0,"take_profit":4050.0,"size_pct":12,"reason":"uptrend with momentum"}',
        buyRef: 4000.0,
        sellRef: 3999.5,
        atr: 20, // rule 1.2x ATR = 24: the AI's tighter 20 stop is kept
      );
      expect(d.action, 'buy');
      expect(d.confidence, 'high');
      expect(d.isTrade, isTrue);
      expect(d.sl, 3980.0);
      expect(d.tp, 4030.0); // TP = 1.5R of the 20 stop, not the AI's 4050
      expect(d.sizePct, 12);
    });

    test('garbage becomes a safe hold', () {
      final d = parseDecision('I think the market looks nice today',
          buyRef: 4000, sellRef: 3999);
      expect(d.action, 'hold');
      expect(d.isTrade, isFalse);
    });

    test('low confidence never trades', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"low","stop_loss":3990,"take_profit":4020,"size_pct":10,"reason":"weak signal"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.isTrade, isFalse);
    });

    test('wild stop loss never widens the rule stop (v1.2.11)', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","stop_loss":3000,"take_profit":5000,"size_pct":50,"reason":"yolo"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.sl, 3990.0); // no ATR: 0.25% of price
      expect(d.sizePct, 25); // clamped to max
      expect(d.tp, 4015.0); // 1.5R
    });

    test('missing SL/TP gets sane defaults for a sell', () {
      final d = parseDecision(
          '{"action":"sell","confidence":"medium","size_pct":10,"reason":"breakdown"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.sl, closeTo(3999 * 1.0025, 0.01));
      expect(d.tp, closeTo(3999 - 1.5 * (3999 * 0.0025), 0.01));
    });

    test('wrong-side TP is replaced', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","stop_loss":3990,"take_profit":3950,"size_pct":10,"reason":"x"}',
          buyRef: 4000, sellRef: 3999);
      expect(d.tp, greaterThan(4000));
    });
  });

  test('medium confidence no longer trades (user: only when sure)', () {
    final d = parseDecision(
        '{"action":"buy","confidence":"medium","stop_loss":3990,"take_profit":4020,"size_pct":10,"reason":"decent setup"}',
        buyRef: 4000, sellRef: 3999);
    expect(d.action, 'buy');
    expect(d.isTrade, isFalse);
  });

  test('AiDecision.hold never trades', () {
    expect(AiDecision.hold('x').isTrade, isFalse);
  });

  test('parseAdvice reads a clean verdict', () {
    final r = parseAdvice('{"verdict":"buy","reasons":"Price holding above support."}');
    expect(r.verdict, 'buy');
    expect(r.reasons, contains('support'));
  });
  
  test('parseAdvice demotes unknown verdicts to wait', () {
    final r = parseAdvice('{"verdict":"moon","reasons":"x"}');
    expect(r.verdict, 'wait');
  });
  
  test('parseAdvice survives garbage', () {
    final r = parseAdvice('not json at all');
    expect(r.verdict, 'wait');
    expect(r.reasons, isNotEmpty);
  });
  
  test('buildAdvicePrompt includes S/R and drawn levels', () {
    final candles = List.generate(
        60,
        (i) => Candle(
              time: DateTime.fromMillisecondsSinceEpoch(i * 900000),
              open: 4000 + i.toDouble(),
              high: 4002 + i.toDouble(),
              low: 3998 + i.toDouble(),
              close: 4001 + i.toDouble(),
            ));
    final p = buildAdvicePrompt(bid: 4059.5, ask: 4060.5, candles: candles, drawnLevels: [4010.0, 4044.0]);
    expect(p, contains('resistance'));
    expect(p, contains('support'));
    expect(p, contains('4010.0'));
    expect(p, contains('4044.0'));
  });


  group('Advice sure-trade (v37)', () {
    test('sure directional advice carries clamped TP/SL and trades', () {
      final r = parseAdvice(
          '{"verdict":"buy","confidence":"high","buy_pct":80,"sell_pct":15,'
          '"stop_loss":3000,"take_profit":5000,"size_pct":40,"reasons":"Strong breakout."}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isTrue);
      expect(r.sl, 3990.0); // rule stop: 0.25% of price without ATR
      expect(r.tp, 4015.0); // 1.5R
      expect(r.sizePct, 25); // clamped to max
    });
    test('low-confidence direction stays read-only', () {
      final r = parseAdvice(
          '{"verdict":"sell","confidence":"low","stop_loss":4010,"take_profit":3980,"reasons":"Weak."}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isFalse);
      expect(r.sl, isNull);
      expect(r.tp, isNull);
    });
    test('high-confidence wait never trades', () {
      final r = parseAdvice(
          '{"verdict":"wait","confidence":"high","reasons":"Mixed picture."}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isFalse);
      expect(r.sl, isNull);
    });
    test('missing confidence defaults to low (no trade)', () {
      final r = parseAdvice('{"verdict":"buy","reasons":"x"}',
          buyRef: 4000, sellRef: 3999);
      expect(r.sureTrade, isFalse);
    });
  });

  group('Advice prediction percentages (v36)', () {
    test('buy/sell percentages parse through', () {
      final r = parseAdvice(
          '{"verdict":"buy","buy_pct":62,"sell_pct":38,"reasons":"Support held."}');
      expect(r.verdict, 'buy');
      expect(r.buyPct, 62);
      expect(r.sellPct, 38);
      expect(r.reasons, 'Support held.');
    });
    test('missing percentages stay null so the UI hides them', () {
      final r = parseAdvice('{"verdict":"wait","reasons":"Mixed."}');
      expect(r.buyPct, isNull);
      expect(r.sellPct, isNull);
    });
    test('percentages clamp to 0-100 and must be numeric', () {
      final r = parseAdvice(
          '{"verdict":"sell","buy_pct":-5,"sell_pct":140,"reasons":"x"}');
      expect(r.buyPct, 0);
      expect(r.sellPct, 100);
      final r2 = parseAdvice(
          '{"verdict":"sell","buy_pct":"high","sell_pct":70,"reasons":"x"}');
      expect(r2.buyPct, isNull);
      expect(r2.sellPct, 70);
    });
    test('malformed still degrades to wait with no percentages', () {
      final r = parseAdvice('not json at all');
      expect(r.verdict, 'wait');
      expect(r.buyPct, isNull);
      expect(r.sellPct, isNull);
    });
    test('double percentages round to whole numbers', () {
      final r = parseAdvice(
          '{"verdict":"buy","buy_pct":61.6,"sell_pct":38.2,"reasons":"x"}');
      expect(r.buyPct, 62);
      expect(r.sellPct, 38);
    });
  });

  group('ATR-relative stops (user: SL/TP too far) - v1.2.13 rule', () {
    // Instinct's ATR-band scenarios, checked against the shipped rule
    // (lib/protection.dart): stop 1.2x ATR, AI stop kept only when tighter
    // and >= 0.5x ATR, cap 0.5% of price, TP 1.5R, 0.01 gold tick.
    test('defaults land at 1.2x ATR with TP at 1.5x risk', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","size_pct":10,"reason":"x"}',
          buyRef: 3900, sellRef: 3899.5, atr: 9.5);
      expect(d.sl, closeTo(3900 - 1.2 * 9.5, 0.001));
      expect(d.tp, closeTo(3900 + 1.5 * 1.2 * 9.5, 0.001));
    });
    test('model stop closer than half an ATR is replaced by the rule', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","stop_loss":3898.0,"take_profit":3920.0,"size_pct":10,"reason":"x"}',
          buyRef: 3900, sellRef: 3899.5, atr: 9.5);
      expect(d.sl, closeTo(3900 - 1.2 * 9.5, 0.001));
    });
    test('wild model stop never widens the trade', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","stop_loss":3000,"take_profit":5000,"size_pct":10,"reason":"x"}',
          buyRef: 3900, sellRef: 3899.5, atr: 9.5);
      expect(d.sl, closeTo(3900 - 1.2 * 9.5, 0.001));
      expect(d.tp! - 3900, closeTo(1.5 * (3900 - d.sl!), 0.011));
    });
    test('sell side mirrors: stop above entry, target below', () {
      final d = parseDecision(
          '{"action":"sell","confidence":"high","size_pct":10,"reason":"x"}',
          buyRef: 3900, sellRef: 3899.5, atr: 9.5);
      expect(d.sl, closeTo(3899.5 + 1.2 * 9.5, 0.001));
      expect(d.tp, closeTo(3899.5 - 1.5 * 1.2 * 9.5, 0.001));
    });
    test('invalid ATR (NaN, infinite, zero, negative) uses the % fallback', () {
      for (final bad in [double.nan, double.infinity, 0.0, -5.0]) {
        final d = parseDecision(
            '{"action":"buy","confidence":"high","size_pct":10,"reason":"x"}',
            buyRef: 3900, sellRef: 3899.5, atr: bad);
        expect(d.sl, closeTo(3900 * (1 - 0.0025), 0.001));
      }
    });
    test('outlier ATR is capped at 0.5% of price', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","stop_loss":1000,"take_profit":5000,"size_pct":10,"reason":"x"}',
          buyRef: 3900, sellRef: 3899.5, atr: 500);
      expect(d.sl, closeTo(3900 * 0.995, 0.001));
    });
    test('tiny ATR is floored at 0.02% of price (inside-spread guard)', () {
      final d = parseDecision(
          '{"action":"buy","confidence":"high","size_pct":10,"reason":"x"}',
          buyRef: 3900, sellRef: 3899.5, atr: 0.1);
      expect(d.sl, closeTo(3900 - 0.0002 * 3900, 0.001));
    });
    test('advice sure-trade uses the same rule', () {
      final r = parseAdvice(
          '{"verdict":"buy","confidence":"high","stop_loss":3000,"take_profit":5000,"reasons":"Strong."}',
          buyRef: 3900, sellRef: 3899.5, atr: 9.5);
      expect(r.sureTrade, isTrue);
      expect(r.sl, closeTo(3900 - 1.2 * 9.5, 0.001));
    });
  });
}
