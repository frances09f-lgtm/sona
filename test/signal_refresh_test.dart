import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/ai_brain.dart';
import 'package:sona/chart/candle_chart.dart';
import 'package:sona/chart/chart_tools.dart';
import 'package:sona/market_data/models.dart';
import 'package:sona/signal_pass.dart';
import 'package:sona/signal_zones.dart';

import 'fullscreen_editor_test.dart' show fakeCandles, loadFonts;

/// Flat market with two retested lows at 3800 and two retested highs at
/// 4000 around a 3900 price: detection yields exactly one BUY and one SELL.
List<Candle> spikeCandles() {
  final base = DateTime(2026, 11, 19, 9);
  return List.generate(60, (i) {
    var high = 3901.0;
    var low = 3899.0;
    if (i == 10 || i == 25) low = 3800;
    if (i == 18 || i == 33) high = 4000;
    return Candle(
      time: base.add(Duration(minutes: 15 * i)),
      open: 3900,
      high: high,
      low: low,
      close: 3900,
    );
  });
}

class FakeBrain extends GroqBrain {
  int calls = 0;
  Future<void>? gate;
  void Function()? onCall;
  ZoneQualification? answer = const ZoneQualification(true, true, 'test');

  @override
  Future<ZoneQualification?> qualifyZones({
    required String instrument,
    required double bid,
    required double ask,
    required List<Candle> candles,
    String? buyZoneDesc,
    String? sellZoneDesc,
  }) async {
    calls++;
    onCall?.call();
    if (gate != null) await gate;
    return answer;
  }
}

final int nowMs = DateTime(2026, 11, 19, 12).millisecondsSinceEpoch;

SignalBox decided(String id, bool isBuy, SignalBoxState st, int at) =>
    SignalBox(
      id: id,
      isBuy: isBuy,
      low: 3700,
      high: 3701,
      createdAtMs: at - 1000,
      state: st,
      decidedAtMs: at,
      evaluatedUpToMs: at,
    );

void main() {
  test('cleared boxes do not block their levels, real results still do', () {
    final c = spikeCandles();
    final m = SignalBoxManager();
    final zs = m.candidates(c, 3900, nowMs);
    expect(zs.length, 2);
    for (final z in zs) {
      m.addBox(z, nowMs - 1000);
    }
    expect(m.candidates(c, 3900, nowMs), isEmpty);
    expect(m.clearLive(nowMs), isTrue);
    expect(m.displayBoxes, isEmpty);
    // Current-market recomputation: the same still-valid levels return.
    expect(m.candidates(c, 3900, nowMs).length, 2);
    expect(m.clearLive(nowMs + 1), isFalse);

    // A genuinely decided BUY level a bit ago stays protected.
    final buy = zs.firstWhere((z) => z.isBuy);
    final sell = zs.firstWhere((z) => !z.isBuy);
    final m2 = SignalBoxManager();
    m2.boxes.add(
      SignalBox(
        id: 'w',
        isBuy: true,
        low: buy.low,
        high: buy.high,
        createdAtMs: nowMs - 7200000,
        state: SignalBoxState.wrong,
        decidedAtMs: nowMs - 3600000,
        evaluatedUpToMs: nowMs - 3600000,
      ),
    );
    m2.addBox(sell, nowMs - 1000);
    m2.clearLive(nowMs);
    final again = m2.candidates(c, 3900, nowMs);
    expect(again.length, 1);
    expect(again.single.isBuy, isFalse);
  });

  test('clearLive keeps decided history and daily counters', () {
    final m = SignalBoxManager();
    m.boxes.add(decided('c', true, SignalBoxState.correct, nowMs));
    m.boxes.add(decided('x', false, SignalBoxState.wrong, nowMs));
    m.addBox(const DetectedZone(true, 3800, 3), nowMs - 5000);
    m.boxes[2] = m.boxes[2].copyWith(
      state: SignalBoxState.active,
      touchedAtMs: nowMs - 100,
    );
    final before = m.todayStats(nowMs);
    expect(before, (1, 1));
    m.clearLive(nowMs);
    expect(m.todayStats(nowMs), before);
    expect(m.boxes.length, 3);
    expect(m.boxes[0].state, SignalBoxState.correct);
    expect(m.boxes[1].state, SignalBoxState.wrong);
    expect(m.boxes[2].state, SignalBoxState.expired);
    expect(m.boxes[2].manualClear, isTrue);
    expect(m.boxes[0].manualClear, isFalse);
  });

  test('manualClear survives storage and is absent on normal boxes', () {
    final b = decided(
      'e',
      true,
      SignalBoxState.expired,
      nowMs,
    ).copyWith(manualClear: true);
    expect(SignalBox.fromJson(b.toJson())!.manualClear, isTrue);
    expect(
      decided(
        'e',
        true,
        SignalBoxState.expired,
        nowMs,
      ).toJson().containsKey('manualClear'),
      isFalse,
    );
    expect(
      SignalBox.fromJson(
        decided('o', true, SignalBoxState.wrong, nowMs).toJson(),
      )!.manualClear,
      isFalse,
    );
  });

  test('worker saving a pre-clear snapshot cannot undo a refresh', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final seed = SignalBoxManager();
    seed.boxes.add(decided('c', true, SignalBoxState.correct, nowMs - 9000));
    seed.addBox(const DetectedZone(true, 3800, 3), nowMs - 5000);
    seed.addBox(const DetectedZone(false, 4000, 3), nowMs - 4000);
    await seed.save(prefs);

    // Background worker loads its copy, then the user refreshes.
    final worker = SignalBoxManager();
    await worker.load(prefs);
    final app = SignalBoxManager();
    await app.load(prefs);
    expect(app.clearLive(nowMs), isTrue);
    await app.save(prefs);

    // Worker finishes later: it adds a box and saves its old snapshot.
    worker.addBox(const DetectedZone(true, 3810, 3), nowMs + 1000);
    await worker.save(prefs);

    final check = SignalBoxManager();
    await check.load(prefs);
    expect(check.displayBoxes, isEmpty);
    expect(check.boxes.length, 3);
    expect(check.boxes.where((b) => b.manualClear).length, 2);
    expect(check.todayStats(nowMs), (1, 0));

    // A later save from the same worker copy is a plain save again.
    worker.boxes.add(decided('n', false, SignalBoxState.wrong, nowMs + 2000));
    await worker.save(prefs);
    final check2 = SignalBoxManager();
    await check2.load(prefs);
    expect(check2.boxes.any((b) => b.id == 'n'), isTrue);
    expect(check2.displayBoxes, isEmpty);
  });

  test('worker result reached before the clear is kept', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final seed = SignalBoxManager();
    seed.addBox(const DetectedZone(true, 3800, 3), nowMs - 5000);
    await seed.save(prefs);
    final worker = SignalBoxManager();
    await worker.load(prefs);
    worker.boxes[0] = worker.boxes[0].copyWith(
      state: SignalBoxState.correct,
      decidedAtMs: nowMs - 500,
    );
    final app = SignalBoxManager();
    await app.load(prefs);
    app.clearLive(nowMs);
    await app.save(prefs);
    await worker.save(prefs);
    final check = SignalBoxManager();
    await check.load(prefs);
    expect(check.boxes.single.state, SignalBoxState.correct);
    expect(check.boxes.single.manualClear, isFalse);
    expect(check.todayStats(nowMs), (1, 0));
  });

  test('a clear landing between the worker check and write survives', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final seed = SignalBoxManager();
    seed.addBox(const DetectedZone(true, 3800, 3), nowMs - 5000);
    await seed.save(prefs);
    final worker = SignalBoxManager();
    await worker.load(prefs);
    worker.addBox(const DetectedZone(false, 4000, 3), nowMs - 100);
    worker.debugBeforeWrite = () async {
      final app = SignalBoxManager();
      await app.load(prefs);
      app.clearLive(nowMs);
      await app.save(prefs);
      worker.debugBeforeWrite = null;
    };
    await worker.save(prefs);
    final check = SignalBoxManager();
    await check.load(prefs);
    expect(check.displayBoxes, isEmpty);
  });

  group('qualification and refresh', () {
    late SharedPreferences prefs;
    setUp(() async {
      SharedPreferences.setMockInitialValues({SignalPass.lastQualMsKey: nowMs});
      prefs = await SharedPreferences.getInstance();
    });

    test(
      'the 15-minute gap holds unless the manual refresh bypasses it',
      () async {
        final brain = FakeBrain();
        final m = SignalBoxManager();
        final c = spikeCandles();
        expect(
          await SignalPass.qualifyFreshSetup(
            prefs,
            m,
            c,
            3900,
            brain: brain,
            nowMs: nowMs,
          ),
          isFalse,
        );
        expect(brain.calls, 0);
        expect(
          await SignalPass.qualifyFreshSetup(
            prefs,
            m,
            c,
            3900,
            brain: brain,
            nowMs: nowMs,
            bypassGap: true,
          ),
          isTrue,
        );
        expect(brain.calls, 1);
        expect(m.displayBoxes.length, 2);
      },
    );

    test('an answer that went stale during the AI call is dropped', () async {
      final brain = FakeBrain();
      final m = SignalBoxManager();
      final added = await SignalPass.qualifyFreshSetup(
        prefs,
        m,
        spikeCandles(),
        3900,
        brain: brain,
        nowMs: nowMs,
        bypassGap: true,
        isCurrent: () => false,
      );
      expect(added, isFalse);
      expect(brain.calls, 1);
      expect(m.displayBoxes, isEmpty);
    });

    test('a direction filled meanwhile is not duplicated', () async {
      final m = SignalBoxManager();
      final brain = FakeBrain()
        ..onCall = () => m.addBox(const DetectedZone(true, 3790, 3), nowMs);
      await SignalPass.qualifyFreshSetup(
        prefs,
        m,
        spikeCandles(),
        3900,
        brain: brain,
        nowMs: nowMs,
        bypassGap: true,
      );
      expect(m.displayBoxes.where((b) => b.isBuy).length, 1);
      expect(m.displayBoxes.where((b) => !b.isBuy).length, 1);
    });

    test(
      'refresh clears old boxes, recomputes, persists, keeps counters',
      () async {
        final c = spikeCandles();
        final m = SignalBoxManager();
        m.boxes.add(decided('c', true, SignalBoxState.correct, nowMs));
        for (final z in m.candidates(c, 3900, nowMs)) {
          m.addBox(z, nowMs - 60000);
        }
        await m.save(prefs);
        final stats = m.todayStats(nowMs);
        final brain = FakeBrain();
        final r = await SignalPass.refresh(
          prefs,
          m,
          c,
          3900,
          brain: brain,
          nowMs: nowMs,
        );
        expect(r, RefreshOutcome.added);
        expect(brain.calls, 1);
        expect(m.todayStats(nowMs), stats);
        expect(m.boxes.where((b) => b.manualClear).length, 2);
        expect(m.displayBoxes.length, 2);
        expect(
          m.displayBoxes.every((b) => b.state == SignalBoxState.pending),
          isTrue,
        );
        final fresh = SignalBoxManager();
        await fresh.load(prefs);
        expect(fresh.displayBoxes.length, 2);
        expect(fresh.boxes.where((b) => b.manualClear).length, 2);
      },
    );

    test('AI declining leaves the chart cleared and forces nothing', () async {
      final c = spikeCandles();
      final m = SignalBoxManager();
      for (final z in m.candidates(c, 3900, nowMs)) {
        m.addBox(z, nowMs - 60000);
      }
      await m.save(prefs);
      final brain = FakeBrain()
        ..answer = const ZoneQualification(false, false, 'no');
      final r = await SignalPass.refresh(
        prefs,
        m,
        c,
        3900,
        brain: brain,
        nowMs: nowMs,
      );
      expect(r, RefreshOutcome.clearedNoSetup);
      expect(m.displayBoxes, isEmpty);
    });

    test('a second tap while a refresh runs makes no second AI call', () async {
      final c = spikeCandles();
      final m = SignalBoxManager();
      final gate = Completer<void>();
      final brain = FakeBrain()..gate = gate.future;
      final first = SignalPass.refresh(
        prefs,
        m,
        c,
        3900,
        brain: brain,
        nowMs: nowMs,
      );
      await pumpEventQueue();
      expect(SignalPass.refreshing, isTrue);
      expect(
        await SignalPass.refresh(prefs, m, c, 3900, brain: brain),
        RefreshOutcome.busy,
      );
      expect(brain.calls, 1);
      gate.complete();
      expect(await first, RefreshOutcome.added);
      expect(brain.calls, 1);
      expect(SignalPass.refreshing, isFalse);
      expect(m.displayBoxes.length, 2);
    });

    test(
      'a background answer that predates a refresh cannot add boxes',
      () async {
        final c = spikeCandles();
        final m = SignalBoxManager();
        final gate = Completer<void>();
        final slow = FakeBrain()..gate = gate.future;
        final epoch = SignalPass.epoch;
        final background = SignalPass.qualifyFreshSetup(
          prefs,
          m,
          c,
          3900,
          brain: slow,
          nowMs: nowMs,
          bypassGap: true,
          isCurrent: () => SignalPass.epoch == epoch,
        );
        await pumpEventQueue();
        final quick = FakeBrain();
        final r = await SignalPass.refresh(
          prefs,
          m,
          c,
          3900,
          brain: quick,
          nowMs: nowMs + 1,
        );
        expect(r, RefreshOutcome.added);
        final drawn = m.displayBoxes.map((b) => b.id).toSet();
        gate.complete();
        expect(await background, isFalse);
        expect(m.displayBoxes.map((b) => b.id).toSet(), drawn);
      },
    );
  });

  testWidgets('Sigma menu lists Refresh signals first and runs it', (t) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    t.view.physicalSize = const Size(822, 1800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final boundary = GlobalKey();
    final data = fakeCandles(60);
    var calls = 0;
    await t.pumpWidget(
      RepaintBoundary(
        key: boundary,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: FullscreenChartPage(
            loader: (_) async => data,
            livePrice: 3855.10,
            signalStats: (0, 1),
            marketSnapshot: () => const ChartMarketSnapshot(
              price: 3855.10,
              fresh: true,
              bid: 3855.10,
              ask: 3855.77,
            ),
            onTradeSide: (_) {},
            onRefreshSignals: () async {
              calls++;
              return 'Signals refreshed: test';
            },
          ),
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.functions).first);
    await t.pumpAndSettle();
    expect(find.text('Refresh signals'), findsOneWidget);
    expect(find.text('SMA 20'), findsOneWidget);
    expect(find.text('MACD'), findsOneWidget);
    expect(
      t.getTopLeft(find.text('Refresh signals')).dy,
      lessThan(t.getTopLeft(find.text('SMA 20')).dy),
    );
    if (Platform.environment['REFRESH_CAPTURE'] == '1') {
      await t.runAsync(() async {
        final image =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        await File('/tmp/refresh-menu.png')
            .writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
    }
    await t.tap(find.text('Refresh signals'));
    await t.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('Signals refreshed: test'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('Sigma menu is unchanged when no refresh callback is given', (
    t,
  ) async {
    SharedPreferences.setMockInitialValues({});
    await loadFonts();
    t.view.physicalSize = const Size(822, 1800);
    t.view.devicePixelRatio = 2;
    addTearDown(t.view.reset);
    final data = fakeCandles(60);
    await t.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        home: FullscreenChartPage(
          loader: (_) async => data,
          livePrice: 3855.10,
          signalStats: (0, 1),
          marketSnapshot: () => const ChartMarketSnapshot(
            price: 3855.10,
            fresh: true,
            bid: 3855.10,
            ask: 3855.77,
          ),
          onTradeSide: (_) {},
        ),
      ),
    );
    await t.pumpAndSettle();
    await t.tap(find.byIcon(Icons.functions).first);
    await t.pumpAndSettle();
    expect(find.text('Refresh signals'), findsNothing);
    expect(find.text('SMA 20'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
  });
}
