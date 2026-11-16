import 'package:shared_preferences/shared_preferences.dart';

import 'ai_brain.dart';
import 'market_data/market_data_config.dart';
import 'market_data/models.dart';
import 'market_data/swissquote_provider.dart';
import 'market_data/twelve_data_candles.dart';
import 'signal_zones.dart';

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
class SignalPass {
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
    final mid =
        await (midFetcher?.call() ?? _defaultMid());
    if (mid == null) return 'No live quote - skipped';
    List<Candle> candles;
    try {
      candles = await (candleFetcher?.call() ??
          TwelveDataCandleService(apiKey: MarketDataConfig.apiKey)
              .fetchCandles(Instrument.xauUsd, interval: '15min', limit: 60));
    } catch (_) {
      return 'No candle data - skipped';
    }
    if (candles.length < 2) return 'No candle data - skipped';
    final mgr = SignalBoxManager();
    await mgr.load(prefs);
    var changed = mgr.onCandles(candles, mid, now);
    final added = await qualifyFreshSetup(prefs, mgr, candles, mid,
        brain: brain, nowMs: now);
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
  }) async {
    if (!mgr.needsSetup) return false;
    final now = nowMs ?? DateTime.now().millisecondsSinceEpoch;
    final c = mgr.candidates(candles, price, now);
    final buys = c.where((z) => z.isBuy);
    final sells = c.where((z) => !z.isBuy);
    if (buys.isEmpty && sells.isEmpty) return false;
    final last = prefs.getInt(lastQualMsKey) ?? 0;
    if (now - last < minQualGap.inMilliseconds) return false;
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
      return false; // AI unavailable: stay silent, retry after the gap
    }
    if (q == null) return false;
    var added = false;
    if (buys.isNotEmpty && q.buyOk) {
      mgr.addBox(buys.first, now, price: price);
      added = true;
    }
    if (sells.isNotEmpty && q.sellOk) {
      mgr.addBox(sells.first, now, price: price);
      added = true;
    }
    return added;
  }
}
