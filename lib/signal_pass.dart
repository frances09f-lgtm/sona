import 'package:shared_preferences/shared_preferences.dart';

import 'ai_brain.dart';
import 'market_data/market_data_config.dart';
import 'market_data/models.dart';
import 'market_data/swissquote_provider.dart';
import 'market_data/twelve_data_candles.dart';
import 'signal_status.dart';
import 'signal_zones.dart';
import 'user_api_keys.dart';

/// Independent gold signal-box pass (repair approved Nov 16 2026: the
/// user approved occasional standalone Groq qualification calls at fresh
/// setups; no paid service).
///
/// The Nov 13 agreement: BUY/SELL boxes appear AUTOMATICALLY at strong
/// support/resistance or other worthwhile setups, a fresh setup is found
/// after the market crosses a box (never a flip), and correct/wrong
/// reactions are counted daily. The original implementation welded box
/// creation to the AutoTrade decision cycle and the Advice button, so
/// trading gates (AutoTrade off, paused, cooldown, trade limits, an open
/// paper position) silently stopped signals. This pass decouples them:
/// trading gates govern trades only.
///
/// Cost shape: detection is on-device (swing S/R over real candles, no
/// AI). The ONE Groq call happens only when a direction slot is free AND
/// a fresh candidate exists, at most once per [minQualGap] across every
/// qualification path (this pass, the AutoTrade decision, the Advice
/// button). While boxes stand or no setup exists: zero AI calls.
enum RefreshOutcome { busy, noData, added, clearedNoSetup, noSetup }

class SignalPass {
  static bool _refreshing = false;
  static int _epoch = 0;

  /// True while a manual refresh runs (background paths skip meanwhile).
  static bool get refreshing => _refreshing;

  /// Bumped at the start of every manual refresh; background qualifiers
  /// remember it and discard their answer if it changed.
  static int get epoch => _epoch;

  /// Manual "Refresh signals": removes every live box (pending and
  /// touched, marked manualClear, never counted), then asks the AI once
  /// for new setups on [candles] at [price], skipping the usual 15-minute
  /// wait (one extra AI call per tap). One refresh at a time: taps while
  /// one runs return [RefreshOutcome.busy] without another call. The AI
  /// may still decline; nothing is forced and no trade is placed.
  static Future<RefreshOutcome> refresh(
    SharedPreferences prefs,
    SignalBoxManager mgr,
    List<Candle> candles,
    double price, {
    GroqBrain? brain,
    int? nowMs,
  }) async {
    if (_refreshing) return RefreshOutcome.busy;
    if (candles.isEmpty) return RefreshOutcome.noData;
    _refreshing = true;
    final myEpoch = ++_epoch;
    try {
      await prefs.reload();
      await mgr.load(prefs);
      final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
      final cleared = mgr.clearLive(now);
      if (cleared) await mgr.save(prefs);
      final added = await qualifyFreshSetup(prefs, mgr, candles, price,
          brain: brain,
          nowMs: now,
          path: 'manual',
          bypassGap: true,
          isCurrent: () => _epoch == myEpoch);
      if (added) await mgr.save(prefs);
      if (added) return RefreshOutcome.added;
      return cleared ? RefreshOutcome.clearedNoSetup : RefreshOutcome.noSetup;
    } finally {
      _refreshing = false;
    }
  }

  /// SharedPreferences key of the last zone-qualification AI call,
  /// whichever path made it.
  static const String lastQualMsKey = 'tj_signal_qual_last_ms';

  /// Minimum gap between zone-qualification AI calls across all paths.
  static const Duration minQualGap = Duration(minutes: 15);

  /// Stamps that a zone-qualification AI call just happened on any path,
  /// so concurrent and follow-up callers collapse onto that one call.
  static Future<void> stampQualified(SharedPreferences prefs, [int? nowMs]) {
    return prefs.setInt(
        lastQualMsKey, nowMs ?? DateTime.now().millisecondsSinceEpoch);
  }

  static Future<double?> _defaultMid() async {
    try {
      final q = await SwissquoteQuoteProvider().fetchQuote(Instrument.xauUsd);
      return q.mid ?? q.bid ?? q.ask;
    } catch (_) {
      return null;
    }
  }

  /// Full pass for the background worker: fetch quote + candles, score
  /// live boxes against the fresh candles, then qualify at most one
  /// fresh setup per free direction slot. No trading gates are read
  /// here. Returns a human summary for logs and tests.
  static Future<String> run(
    SharedPreferences prefs, {
    GroqBrain? brain,
    Future<double?> Function()? midFetcher,
    Future<List<Candle>> Function()? candleFetcher,
    int? nowMs,
  }) async {
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    // The background worker starts in a fresh isolate where the in-memory
    // API keys are still empty (AutoTrade.status loads them, but only
    // AFTER this pass). Load them first; a load failure leaves the keys
    // as they were and the pass proceeds exactly as before.
    try {
      await UserApiKeys.load();
    } catch (_) {}
    final mid =
        await (midFetcher?.call() ?? _defaultMid());
    if (mid == null) {
      await SignalStatus.record(prefs,
          path: 'worker', outcome: 'no_quote', nowMs: now);
      return 'No live quote - skipped';
    }
    List<Candle> candles;
    try {
      candles = await (candleFetcher?.call() ??
          TwelveDataCandleService(apiKey: MarketDataConfig.apiKey)
              .fetchCandles(Instrument.xauUsd, interval: '15min', limit: 60));
    } catch (_) {
      await SignalStatus.record(prefs,
          path: 'worker', outcome: 'no_candles', nowMs: now);
      return 'No candle data - skipped';
    }
    if (candles.length < 2) {
      await SignalStatus.record(prefs,
          path: 'worker', outcome: 'no_candles', nowMs: now);
      return 'No candle data - skipped';
    }
    final mgr = SignalBoxManager();
    await mgr.load(prefs);
    var changed = mgr.onCandles(candles, mid, now);
    final added = await qualifyFreshSetup(prefs, mgr, candles, mid,
        brain: brain, nowMs: now, path: 'worker');
    changed = added || changed;
    if (changed) await mgr.save(prefs);
    return added ? 'New signal box qualified and drawn' : 'Checked - no new signal';
  }

  /// Qualifies fresh setups for [mgr] against [candles]: at most one new
  /// box per free direction slot, and only when no qualification call
  /// (any path) happened in the last [minQualGap]. The dedupe stamp is
  /// written BEFORE the AI call so concurrent callers collapse onto one
  /// request. Returns true when a box was added (caller persists and
  /// repaints).
  static Future<bool> qualifyFreshSetup(
    SharedPreferences prefs,
    SignalBoxManager mgr,
    List<Candle> candles,
    double price, {
    GroqBrain? brain,
    int? nowMs,
    String path = 'foreground',
    bool bypassGap = false,
    bool Function()? isCurrent,
  }) async {
    final keyPresent = AiConfig.groqApiKey.isNotEmpty;
    Future<void> note(String outcome, [int? n, int? b, int? s]) =>
        SignalStatus.record(prefs,
            path: path,
            outcome: outcome,
            candidates: n,
            buyCandidates: b,
            sellCandidates: s,
            groqKeyPresent: keyPresent,
            nowMs: nowMs);
    if (!mgr.needsSetup) {
      await note('no_setup_needed');
      return false;
    }
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final c = mgr.candidates(candles, price, now);
    final buys = c.where((z) => z.isBuy);
    final sells = c.where((z) => !z.isBuy);
    final nb = buys.length, ns = sells.length;
    if (nb == 0 && ns == 0) {
      await note('no_candidates', 0, 0, 0);
      return false;
    }
    final last = prefs.getInt(lastQualMsKey) ?? 0;
    if (!bypassGap && now - last < minQualGap.inMilliseconds) {
      await note('gap_wait', nb + ns, nb, ns);
      return false;
    }
    await stampQualified(prefs, now);
    ZoneQualification? q;
    try {
      q = await (brain ?? GroqBrain()).qualifyZones(
        instrument: 'XAU/USD (gold)',
        bid: price,
        ask: price,
        candles: candles,
        buyZoneDesc: buys.isEmpty ? null : describeZone(buys.first),
        sellZoneDesc: sells.isEmpty ? null : describeZone(sells.first),
      );
    } catch (_) {
      await note('ai_no_reply', nb + ns, nb, ns);
      await SignalStatus.recordAi(prefs,
          path: path,
          outcome: 'ai_no_reply',
          candidates: nb + ns,
          buyCandidates: nb,
          sellCandidates: ns,
          groqKeyPresent: keyPresent,
          nowMs: nowMs);
      return false; // AI unavailable: stay silent, retry after the gap
    }
    if (q == null) {
      await note('ai_no_reply', nb + ns, nb, ns);
      await SignalStatus.recordAi(prefs,
          path: path,
          outcome: 'ai_no_reply',
          candidates: nb + ns,
          buyCandidates: nb,
          sellCandidates: ns,
          groqKeyPresent: keyPresent,
          nowMs: nowMs);
      return false;
    }
    // A refresh may have started while this call was in flight: its
    // answer was computed for the old state, so drop it.
    if (isCurrent != null && !isCurrent()) return false;
    var added = false;
    // Never stack a second live box in a direction another call filled
    // while this one was waiting on the AI.
    if (buys.isNotEmpty &&
        q.buyOk &&
        !mgr.displayBoxes.any((b) => b.isBuy)) {
      mgr.addBox(buys.first, now, price: price);
      added = true;
    }
    if (sells.isNotEmpty &&
        q.sellOk &&
        !mgr.displayBoxes.any((b) => !b.isBuy)) {
      mgr.addBox(sells.first, now, price: price);
      added = true;
    }
    await note(added ? 'asked_ai_added' : 'asked_ai_declined', nb + ns, nb, ns);
    await SignalStatus.recordAi(prefs,
        path: path,
        outcome: added ? 'asked_ai_added' : 'asked_ai_declined',
        candidates: nb + ns,
        buyCandidates: nb,
        sellCandidates: ns,
        groqKeyPresent: keyPresent,
        nowMs: nowMs);
    return added;
  }
}
