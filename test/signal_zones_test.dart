import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/ai_brain.dart';
import 'package:sona/signal_zones.dart';

SignalBox buyBox({
  double low = 3879.0,
  double high = 3880.5,
  int createdAtMs = 1000000,
  SignalBoxState state = SignalBoxState.pending,
  int? touchedAtMs,
}) =>
    SignalBox(
      id: 't1',
      isBuy: true,
      low: low,
      high: high,
      createdAtMs: createdAtMs,
      state: state,
      touchedAtMs: touchedAtMs,
      evaluatedUpToMs: createdAtMs,
    );

SignalBox sellBox({
  double low = 3904.5,
  double high = 3906.0,
  int createdAtMs = 1000000,
  SignalBoxState state = SignalBoxState.pending,
  int? touchedAtMs,
}) =>
    SignalBox(
      id: 't2',
      isBuy: false,
      low: low,
      high: high,
      createdAtMs: createdAtMs,
      state: state,
      touchedAtMs: touchedAtMs,
      evaluatedUpToMs: createdAtMs,
    );

Candle bar(int ms, double o, double h, double l, double c) => Candle(
    time: DateTime.fromMillisecondsSinceEpoch(ms, isUtc: true),
    open: o,
    high: h,
    low: l,
    close: c);

void main() {
  group('approved counting rule', () {
    test('no outcome before the first touch', () {
      // Price rallies straight to the target without entering the zone.
      var b = buyBox();
      b = evaluateSignalTick(b, 1001000, 3881.0, 3890.0);
      expect(b.state, SignalBoxState.pending);
      b = evaluateSignalTick(b, 1002000, 3884.0, 3881.0);
      expect(b.state, SignalBoxState.pending); // target = 3883.5, not touched
    });

    test('touch, then correct at +3.00 above the box top', () {
      var b = buyBox();
      b = evaluateSignalTick(b, 1001000, 3880.0, 3890.0);
      expect(b.state, SignalBoxState.active);
      expect(b.touchedAtMs, 1001000);
      b = evaluateSignalTick(b, 1002000, 3883.4, 3880.0);
      expect(b.state, SignalBoxState.active); // just under target
      b = evaluateSignalTick(b, 1003000, 3883.5, 3883.4);
      expect(b.state, SignalBoxState.correct);
      expect(b.decidedAtMs, 1003000);
    });

    test('touch, then wrong at -1.50 below the box bottom', () {
      var b = buyBox();
      b = evaluateSignalTick(b, 1001000, 3879.5, 3890.0);
      b = evaluateSignalTick(b, 1002000, 3877.6, 3879.5);
      expect(b.state, SignalBoxState.active); // just above invalidation
      b = evaluateSignalTick(b, 1003000, 3877.5, 3877.6);
      expect(b.state, SignalBoxState.wrong);
    });

    test('sell mirrors buy', () {
      var b = sellBox();
      b = evaluateSignalTick(b, 1001000, 3905.0, 3890.0);
      expect(b.state, SignalBoxState.active);
      b = evaluateSignalTick(b, 1002000, 3901.5, 3905.0);
      expect(b.state, SignalBoxState.correct); // bottom - 3.00 = 3901.5
      var s = sellBox();
      s = evaluateSignalTick(s, 1001000, 3905.0, 3890.0);
      s = evaluateSignalTick(s, 1002000, 3907.5, 3905.0);
      expect(s.state, SignalBoxState.wrong); // top + 1.50 = 3907.5
    });

    test('a tick jump over the whole zone is unclear, never scored', () {
      var b = buyBox();
      b = evaluateSignalTick(b, 1001000, 3878.0, 3890.0);
      expect(b.state, SignalBoxState.unclear);
      expect(b.countsCorrect, isFalse);
      expect(b.countsWrong, isFalse);
    });

    test('touch candle that also reaches a boundary is unclear', () {
      var b = buyBox();
      // Enters the zone AND passes the invalidation in one bar.
      b = evaluateSignalCandle(b, bar(1001000, 3890, 3891, 3877.0, 3878));
      expect(b.state, SignalBoxState.unclear);
      var c = buyBox();
      // Enters the zone AND hits the target in one bar.
      c = evaluateSignalCandle(c, bar(1001000, 3878, 3884.0, 3879.2, 3883));
      expect(c.state, SignalBoxState.unclear);
    });

    test('clean touch bar activates, later bar decides', () {
      var b = buyBox();
      b = evaluateSignalCandle(b, bar(1001000, 3890, 3881.5, 3880.0, 3881));
      expect(b.state, SignalBoxState.active);
      b = evaluateSignalCandle(b, bar(1006000, 3881, 3883.6, 3880.5, 3883.4));
      expect(b.state, SignalBoxState.correct);
    });

    test('one later bar spanning both boundaries is unclear', () {
      var b = buyBox();
      b = evaluateSignalCandle(b, bar(1001000, 3890, 3881.5, 3880.0, 3881));
      b = evaluateSignalCandle(b, bar(1006000, 3881, 3884.0, 3877.0, 3882));
      expect(b.state, SignalBoxState.unclear);
    });

    test('expiry 4h after touch is not counted', () {
      var b = buyBox(
          state: SignalBoxState.active, touchedAtMs: 1000000);
      final after = 1000000 + kSignalExpiry.inMilliseconds + 1;
      b = evaluateSignalTick(b, after, 3885.0, 3884.0);
      expect(b.state, SignalBoxState.expired);
      expect(b.countsCorrect, isFalse);
    });

    test('untouched 4h after creation expires, not counted', () {
      var b = buyBox();
      final after = 1000000 + kSignalExpiry.inMilliseconds + 1;
      b = evaluateSignalTick(b, after, 3890.0, 3891.0);
      expect(b.state, SignalBoxState.expired);
    });

    test('decided boxes are immutable', () {
      var b = buyBox(state: SignalBoxState.wrong, touchedAtMs: 999000);
      final same = evaluateSignalTick(b, 1001000, 3880.0, 3890.0);
      expect(same.state, SignalBoxState.wrong);
      expect(same.decidedAtMs, b.decidedAtMs);
    });

    test('pre-activation candle moves never count', () {
      // A bar entirely before the box existed is skipped by the cursor.
      var b = buyBox(createdAtMs: 1000000);
      final m = SignalBoxManager();
      m.boxes.add(b);
      final changed = m.onCandles([
        bar(500000, 3878, 3890, 3877, 3889), // way before creation
        bar(1000000 - 300000, 3885, 3886, 3883, 3884),
      ], 3890.0, 1000000);
      expect(m.boxes.single.state, SignalBoxState.pending);
      expect(changed, isFalse);
    });
  });

  group('daily count attribution (IST resolution day)', () {
    test('outcomes count on the IST day they were decided', () {
      // 2026-11-13 23:30 UTC = 2026-11-14 05:00 IST.
      final decidedUtc =
          DateTime.utc(2026, 11, 13, 23, 30).millisecondsSinceEpoch;
      final nowUtc = DateTime.utc(2026, 11, 14, 1, 0).millisecondsSinceEpoch;
      final m = SignalBoxManager();
      m.boxes.add(SignalBox(
        id: 'a',
        isBuy: true,
        low: 3879,
        high: 3880.5,
        createdAtMs: decidedUtc - 1000,
        state: SignalBoxState.correct,
        touchedAtMs: decidedUtc - 500,
        decidedAtMs: decidedUtc,
        evaluatedUpToMs: decidedUtc,
      ));
      // At 01:00 UTC Nov 14 (06:30 IST Nov 14) it counts for Nov 14 IST.
      expect(m.todayStats(nowUtc), (1, 0));
      // At 01:00 UTC Nov 15 it no longer counts.
      final laterUtc =
          DateTime.utc(2026, 11, 15, 1, 0).millisecondsSinceEpoch;
      expect(m.todayStats(laterUtc), (0, 0));
    });

    test('unclear and expired stay out of the count', () {
      final day = DateTime.utc(2026, 11, 13, 10, 0).millisecondsSinceEpoch;
      final m = SignalBoxManager();
      for (final (i, st) in [
        SignalBoxState.unclear,
        SignalBoxState.expired,
        SignalBoxState.correct,
        SignalBoxState.wrong,
      ].indexed) {
        m.boxes.add(SignalBox(
          id: 'b$i',
          isBuy: true,
          low: 3879,
          high: 3880.5,
          createdAtMs: day - 1000,
          state: st,
          decidedAtMs: day,
          evaluatedUpToMs: day,
        ));
      }
      expect(m.todayStats(day + 1000), (1, 1));
    });
  });

  group('fresh setups', () {
    test('detects support below and resistance above from swing pivots', () {
      // Build 60 bars: dip pivot at 3880 (touched twice), peak at 3906
      // (touched twice), price now 3893.
      final cs = <Candle>[];
      var t = 0;
      void add(double o, double h, double l, double c) {
        cs.add(bar(t, o, h, l, c));
        t += 300000;
      }

      for (var i = 0; i < 8; i++) {
        add(3890, 3891, 3889, 3890);
      }
      add(3890, 3891, 3880.0, 3881); // pivot low 3880
      for (var i = 0; i < 8; i++) {
        add(3885, 3890, 3884, 3889);
      }
      add(3890, 3906.0, 3889, 3905); // pivot high 3906
      for (var i = 0; i < 8; i++) {
        add(3900, 3901, 3890, 3891);
      }
      add(3891, 3892, 3880.2, 3881); // retest 3880
      for (var i = 0; i < 8; i++) {
        add(3885, 3890, 3884, 3889);
      }
      add(3890, 3905.8, 3889, 3905); // retest 3906
      for (var i = 0; i < 8; i++) {
        add(3900, 3901, 3892, 3893);
      }
      final zones = detectSignalZones(cs, 3893.0);
      expect(zones.length, 2);
      final buy = zones.firstWhere((z) => z.isBuy);
      final sell = zones.firstWhere((z) => !z.isBuy);
      expect(buy.level, closeTo(3880.0, 0.3));
      expect(sell.level, closeTo(3906.0, 0.3));
      expect(buy.high, lessThan(3893.0));
      expect(sell.low, greaterThan(3893.0));
    });

    test('no box when nothing qualifies - no forced signals', () {
      final cs = [
        for (var i = 0; i < 40; i++)
          bar(i * 300000, 3890, 3891.0 + i * 0.01, 3889, 3890),
      ];
      // Monotonic creep: no swing pivots at all.
      expect(detectSignalZones(cs, 3890.5), isEmpty);
    });

    test('after a break the same level is not redrawn immediately', () {
      final m = SignalBoxManager();
      final now = 1000000 + kSignalExpiry.inMilliseconds - 60000;
      m.boxes.add(SignalBox(
        id: 'old',
        isBuy: true,
        low: 3879.0,
        high: 3880.5,
        createdAtMs: 900000,
        state: SignalBoxState.wrong,
        touchedAtMs: 950000,
        decidedAtMs: now - 1000,
        evaluatedUpToMs: now - 1000,
      ));
      final cs = <Candle>[];
      var t = 0;
      void add(double o, double h, double l, double c) {
        cs.add(bar(t, o, h, l, c));
        t += 300000;
      }

      for (var i = 0; i < 10; i++) {
        add(3890, 3891, 3889, 3890);
      }
      add(3890, 3891, 3880.0, 3881);
      for (var i = 0; i < 10; i++) {
        add(3885, 3890, 3884, 3889);
      }
      m.onCandles(cs, 3890.0, now);
      // The only support level overlaps the just-broken box, so the
      // fresh-setup search proposes no new BUY zone for Groq to qualify.
      final cands = m.candidates(cs, 3890.0, now);
      expect(cands.where((z) => z.isBuy), isEmpty);
      for (final z in cands) {
        m.addBox(z, now);
      }
      expect(m.displayBoxes.where((b) => b.isBuy), isEmpty);
    });
  });

  group('persistence', () {
    test('history round-trips through SharedPreferences unchanged', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final m = SignalBoxManager();
      m.boxes.add(SignalBox(
        id: 'x',
        isBuy: false,
        low: 3904.5,
        high: 3906.0,
        createdAtMs: 111,
        state: SignalBoxState.correct,
        touchedAtMs: 222,
        decidedAtMs: 333,
        evaluatedUpToMs: 333,
      ));
      await m.save(prefs);
      final m2 = SignalBoxManager();
      await m2.load(prefs);
      final b = m2.boxes.single;
      expect(b.id, 'x');
      expect(b.isBuy, isFalse);
      expect(b.state, SignalBoxState.correct);
      expect(b.decidedAtMs, 333);
    });
  });

  group('Groq zone qualification (inside the normal reply - no extra call)', () {
    test('zone keys parse from the reply JSON', () {
      final q = zoneQualificationFromJson({
        'zone_buy': true,
        'zone_sell': false,
        'zone_reason': 'strong support',
      });
      expect(q, isNotNull);
      expect(q!.buyOk, isTrue);
      expect(q.sellOk, isFalse);
      expect(q.reason, 'strong support');
    });

    test('no zone keys means no qualification (no box is drawn)', () {
      expect(zoneQualificationFromJson({'action': 'hold'}), isNull);
    });

    test('explicit false flags mean not qualified; a lone reason is no answer', () {
      final q = zoneQualificationFromJson(
          {'zone_buy': false, 'zone_sell': false, 'zone_reason': 'nothing worthy'});
      expect(q, isNotNull);
      expect(q!.buyOk, isFalse);
      expect(q.sellOk, isFalse);
      expect(zoneQualificationFromJson({'zone_reason': 'nothing worthy'}),
          isNull);
    });

    test('a hold decision still carries the zone qualification', () {
      final d = parseDecision(
        '{"action":"hold","confidence":"low","reason":"chop",'
        '"zone_buy":true,"zone_sell":false,"zone_reason":"ok"}',
        buyRef: 3890,
        sellRef: 3889,
      );
      expect(d.action, 'hold');
      expect(d.zoneQual, isNotNull);
      expect(d.zoneQual!.buyOk, isTrue);
      expect(d.zoneQual!.sellOk, isFalse);
    });

    test('a trade decision still carries the zone qualification', () {
      final d = parseDecision(
        '{"action":"buy","confidence":"high","stop_loss":3880.0,'
        '"take_profit":3900.0,"size_pct":10,"reason":"breakout",'
        '"zone_buy":false,"zone_sell":true}',
        buyRef: 3890,
        sellRef: 3889,
      );
      expect(d.action, 'buy');
      expect(d.zoneQual, isNotNull);
      expect(d.zoneQual!.sellOk, isTrue);
    });

    test('advice replies carry the zone qualification', () {
      final r = parseAdvice(
        '{"verdict":"wait","reasons":"unclear","zone_buy":true}',
        buyRef: 3890,
        sellRef: 3889,
      );
      expect(r.zoneQual, isNotNull);
      expect(r.zoneQual!.buyOk, isTrue);
      expect(r.zoneQual!.sellOk, isFalse);
    });

    test('the prompt fragment names both proposed zones and the keys', () {
      final f = zonePromptFragment(
          buyZoneDesc: '3879.00 - 3880.50 (level 3879.8, 3 touches)');
      expect(f, contains('BUY zone'));
      expect(f, contains('3879.00 - 3880.50'));
      expect(f, contains('SELL zone (resistance): none proposed'));
      expect(f, contains('zone_buy'));
      expect(f, contains('zone_sell'));
    });

    test('buildPrompt appends the zone fragment when provided', () {
      final s = MarketSnapshot(
        bid: 3889,
        ask: 3890,
        candles: const [],
        openPosition: null,
        tradesToday: 0,
        dayPnl: 0,
        balance: 1000,
      );
      final withZones = buildPrompt(s, zoneFragment: 'ZONEFRAGMENT');
      expect(withZones, contains('ZONEFRAGMENT'));
      expect(buildPrompt(s), isNot(contains('ZONEFRAGMENT')));
    });
  });
}

