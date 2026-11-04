import 'notification_claims.dart';
import 'execution_ledger.dart';
import 'trade_safety.dart';
import 'market_data/swissquote_provider.dart';
import 'market_data/models.dart';

/// Local push notifications (Oro request): TP/SL hits and price alerts
/// while the app is closed.
///
/// Design: no FCM/server. Android WorkManager runs a periodic background
/// check (platform minimum ~15 minutes, OEM battery savers can delay it
/// further - that is the honest limit of server-free background work).
/// Each run fetches the real quote + paper_state and compares against the
/// last-seen open positions and untriggered price alerts stored in
/// SharedPreferences, then posts system notifications.
import 'dart:convert';

import 'usage_reporter.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:http/http.dart' as http;

import 'bridge.dart';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:workmanager/workmanager.dart';

import 'auto_trade.dart';
import 'notification_log.dart';

const String bgTaskName = 'oroBackgroundCheck';
const String _channelId = 'oro_alerts';
const String _sbUrl = 'https://ncaialkmxhbtarmhoiei.supabase.co';
// Public anon key (same as the app; RPCs are pin-guarded).
const String _sbKey = 'sb_publishable_oNw5xcfdpesEihrdmFXfgQ_HKgsVYAi';

final FlutterLocalNotificationsPlugin _fln = FlutterLocalNotificationsPlugin();

/// Shared "already notified" store: one prefs key per event
/// (tj_notified:<eventKey> -> ISO time), written by the app AND the
/// background worker so a close/alert is never notified twice.
///
/// Per-key storage (not one JSON map) because the app and the WorkManager
/// isolate each cache SharedPreferences: read-modify-write on a shared map
/// lost the other isolate's keys, which is what made closed positions
/// re-notify. Callers that need fresh cross-isolate state must
/// `await prefs.reload()` first. The legacy tj_notified map is still read
/// so events marked before this change are not repeated.
String _notifiedKey(String key) => 'tj_notified:$key';

bool notifiedHas(SharedPreferences prefs, String key) {
  if (prefs.getString(_notifiedKey(key)) != null) return true;
  try {
    final raw = prefs.getString('tj_notified'); // legacy shared map
    if (raw == null) return false;
    final map = jsonDecode(raw) as Map;
    if (!map.containsKey(key)) return false;
    final t = DateTime.tryParse(map[key]?.toString() ?? '');
    // Legacy entries were pruned after 7 days; honor the same window.
    return t != null &&
        t.isAfter(DateTime.now().subtract(const Duration(days: 7)));
  } catch (_) {
    return false;
  }
}

Future<void> notifiedAdd(SharedPreferences prefs, String key) async {
  try {
    await prefs.setString(_notifiedKey(key), DateTime.now().toIso8601String());
  } catch (_) {}
}

/// A reload is only a compatibility check; SQLite serializes the actual
/// claim across isolates at the persistence boundary.
Future<bool> claimNotification(SharedPreferences prefs, String key) async {
  await prefs.reload();
  if (notifiedHas(prefs, key)) return false;
  if (!await NotificationClaims.claim(key)) return false;
  await notifiedAdd(prefs, key);
  return true;
}

/// Drop per-key dedupe marks older than 30 days. With open-only position
/// snapshots a close can only be reported once, so pruning cannot cause
/// repeats; it just bounds storage.
Future<void> notifiedPrune(SharedPreferences prefs) async {
  try {
    final cutoff = DateTime.now().subtract(const Duration(days: 30));
    for (final k in prefs.getKeys()) {
      if (!k.startsWith('tj_notified:')) continue;
      final t = DateTime.tryParse(prefs.getString(k) ?? '');
      if (t == null || t.isBefore(cutoff)) await prefs.remove(k);
    }
  } catch (_) {}
}

/// Open-position snapshot for the worker's next run (tj_bg_positions).
/// OPEN positions only: older builds stored the full position history,
/// and every long-closed position then looked like it "just disappeared",
/// producing a "position closed" notification again and again.
String encodeOpenPositionsSnapshot(List<Map<String, dynamic>> positions) =>
    jsonEncode(
      positions
          .where((p) => p['status'] == 'open')
          .map(
            (p) => {
              'id': p['id'],
              'status': p['status'],
              'direction': p['direction'],
              'qty': p['qty'],
              'tp': p['tp'],
              'sl': p['sl'],
            },
          )
          .toList(),
    );

/// Server timestamps: Supabase returns UTC, sometimes without a suffix.
DateTime? parseServerTs(Object? raw) {
  if (raw == null) return null;
  var s = raw.toString();
  if (s.isEmpty) return null;
  final hasZone = s.endsWith('Z') || RegExp(r'[+-]\d{2}:?\d{2}$').hasMatch(s);
  if (!hasZone) s = '${s}Z';
  return DateTime.tryParse(s);
}

/// How far before the last check a close may be stamped and still count
/// as new (stale fetch / server clock skew tolerance).
const newCloseGrace = Duration(minutes: 10);

/// Previous-snapshot entries that genuinely closed since [lastRun].
/// A candidate must still exist in the current position list with
/// status closed AND a closed_at AFTER the last successful check;
/// positions already closed at snapshot time (stored by older builds)
/// are never reported again. Duplicate ids collapse to one entry.
List<Map<String, dynamic>> newlyClosedPositions({
  required List<Map<String, dynamic>> prev,
  required List<Map<String, dynamic>> positions,
  required Set<String> closedIds,
  required DateTime? lastRun,
}) {
  final byId = {for (final p in positions) p['id'].toString(): p};
  final seen = <String>{};
  final out = <Map<String, dynamic>>[];
  for (final p in prev) {
    final id = p['id']?.toString() ?? '';
    if (id.isEmpty || !seen.add(id)) continue;
    if (closedIds.contains(id)) continue; // closed by this worker just now
    if (p['status'] == 'closed') continue; // was already closed at snapshot
    final cur = byId[id];
    if (cur == null) continue; // gone from history - cannot verify, skip
    if (cur['status'] != 'closed') continue; // not a verified close
    final closedAt = parseServerTs(cur['closed_at']);
    if (p['status'] != 'open' && lastRun != null && closedAt != null) {
      // Grace: a stale fetch or clock skew can stamp a genuine close
      // slightly before lastRun; only clearly-old closes are old news.
      // Repeats are impossible either way (dedupe marks), so the grace
      // can only recover delayed closes, never double-notify.
      final cutoff = lastRun.toUtc().subtract(newCloseGrace);
      if (!closedAt.toUtc().isAfter(cutoff)) {
        continue; // closed well before the last check: old news
      }
    }
    out.add(p);
  }
  return out;
}

/// Entries of [pending] whose dedupe key is not yet marked, checked
/// against freshly reloaded prefs. Guards the read-check-post race
/// between the app isolate and this worker: an event marked by either
/// side after the first check is dropped here instead of double-posted.
Future<List<(String, int, String, String)>> unnotifiedOnly(
  SharedPreferences prefs,
  List<(String, int, String, String)> pending,
) async {
  await prefs.reload();
  return pending.where((e) => !notifiedHas(prefs, e.$1)).toList();
}

Future<void> _initPlugin() async {
  const init = InitializationSettings(
    android: AndroidInitializationSettings('@mipmap/ic_launcher'),
  );
  await _fln.initialize(init);
  final android = _fln
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >();
  await android?.createNotificationChannel(
    const AndroidNotificationChannel(
      _channelId,
      'Sona alerts',
      description: 'TP/SL hits and price alerts',
      importance: Importance.high,
    ),
  );
}

/// Call once from main() before runApp.
Future<void> initNotifications() async {
  await _initPlugin();
  // Runtime permission (Android 13+). No-op on older versions.
  await _fln
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()
      ?.requestNotificationsPermission();
  await Workmanager().initialize(oroBgDispatcher);
  await Workmanager().registerPeriodicTask(
    bgTaskName,
    bgTaskName,
    frequency: const Duration(minutes: 15), // Android-enforced minimum
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

Future<void> _notify(int id, String title, String body) async {
  // Record every posted notification for the in-app history (bell icon).
  // Also runs in the background worker isolate; SharedPreferences is shared.
  await NotificationLog.add(title, body);
  await _fln.show(
    id,
    title,
    body,
    const NotificationDetails(
      android: AndroidNotificationDetails(
        _channelId,
        'Sona alerts',
        channelDescription: 'TP/SL hits and price alerts',
        importance: Importance.high,
        priority: Priority.high,
      ),
    ),
  );
}

bool _foregroundInitDone = false;

/// Post a system notification from the RUNNING app (price alert triggered
/// while the user is watching, TP/SL seen on refresh, ...). Without this,
/// an alert that fires in the foreground only shows the in-app banner AND
/// gets marked triggered, so the background worker never notifies either.
Future<void> showForegroundNotification(String title, String body) async {
  try {
    if (!_foregroundInitDone) {
      await _initPlugin();
      _foregroundInitDone = true;
    }
    await _notify(
      DateTime.now().millisecondsSinceEpoch ~/ 1000 % 100000,
      title,
      body,
    );
  } catch (_) {
    // Plugin unavailable (tests, unsupported platform): banner still shows.
  }
}

@pragma('vm:entry-point')
void oroBgDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    try {
      await _bgCheck();
    } catch (_) {
      // Never crash the worker; a failed run just retries next cycle.
    }
    return true;
  });
}

Future<Quote?> _fetchQuote() async {
  try {
    final q = await SwissquoteQuoteProvider().fetchQuote(Instrument.xauUsd);
    return freshExecutionQuote(
          q.bid,
          q.ask,
          q.ts.millisecondsSinceEpoch,
          DateTime.now().millisecondsSinceEpoch,
        )
        ? q
        : null;
  } catch (_) {
    return null;
  }
}

/// Close one paper position server-side via the existing paper_close RPC.
/// Returns the decoded response (may carry pnl), or null on failure.
Future<Map<String, dynamic>?> _closePosition(
  String pin,
  dynamic tid,
  double price,
  String why,
  int quoteAt,
) async {
  if (!freshExecutionQuote(
    price,
    price,
    quoteAt,
    DateTime.now().millisecondsSinceEpoch,
  ))
    return null;
  if (!await ExecutionLedger.claim(tid.toString(), quoteAt, price, why))
    return null;
  try {
    final r = await http
        .post(
          Uri.parse('$_sbUrl/rest/v1/rpc/paper_close'),
          headers: {'apikey': _sbKey, 'Content-Type': 'application/json'},
          body: jsonEncode({'p': pin, 'tid': tid, 'price': price, 'why': why}),
        )
        .timeout(const Duration(seconds: 20));
    if (r.statusCode >= 400) {
      if (r.statusCode < 500) await ExecutionLedger.rejected(tid.toString());
      return null;
    }
    final verified = await _fetchPositions(pin);
    if (!verified.any(
      (p) => p['id'].toString() == tid.toString() && p['status'] == 'closed',
    )) {
      return null; // Keep claim pending until a later authoritative refresh.
    }
    UsageReporter.report('trade_closed', {'src': 'auto'});
    final j = jsonDecode(r.body);
    return j is Map<String, dynamic> ? j : const {};
  } catch (_) {
    return null;
  }
}

Future<List<Map<String, dynamic>>> _fetchPositions(String pin) async {
  final r = await http
      .post(
        Uri.parse('$_sbUrl/rest/v1/rpc/paper_state'),
        headers: {'apikey': _sbKey, 'Content-Type': 'application/json'},
        body: jsonEncode({'p': pin}),
      )
      .timeout(const Duration(seconds: 20));
  if (r.statusCode >= 400) {
    throw StateError('Account refresh failed: HTTP ${r.statusCode}');
  }
  final j = jsonDecode(r.body);
  if (j is! Map || j['positions'] is! List) {
    throw StateError('Account response has no positions');
  }
  final prefs = await SharedPreferences.getInstance();
  await prefs.setString(
    'tj_paper_cache',
    jsonEncode({
      'accountAt': DateTime.now().millisecondsSinceEpoch,
      'starting': j['starting'],
      'balance': j['balance'],
      'positions': j['positions'],
    }),
  );
  OroBridge.notePaper(prefs);
  final positions = List<Map<String, dynamic>>.from(j['positions'] as List);
  await ExecutionLedger.reconcile(positions);
  return positions;
}

Future<void> _bgCheck() async {
  await _initPlugin();
  final prefs = await SharedPreferences.getInstance();
  // The app isolate writes dedupe marks (manual closes, foreground alerts)
  // that this isolate's cache has not seen; reload or closes get re-notified.
  await prefs.reload();
  await notifiedPrune(prefs);
  final pin = prefs.getString('tj_pin') ?? '';
  if (pin.isEmpty) return; // not unlocked on this device

  // Catch-up detection: if the last real check was long ago (worker was
  // killed/asleep), detected events may be ancient - post ONE summary
  // instead of a burst of stale notifications.
  final lastRunRaw = prefs.getString('tj_bg_last_run');
  final lastRun = lastRunRaw == null ? null : DateTime.tryParse(lastRunRaw);
  final catchUp =
      lastRun == null ||
      DateTime.now().difference(lastRun) > const Duration(minutes: 45);
  final pending =
      <(String, int, String, String)>[]; // (dedupeKey, id, title, body)

  final quote = await _fetchQuote();
  var positions = await _fetchPositions(pin);
  final closedIds = <String>{};

  // --- Auto-close TP/SL (the server never closes positions by itself;
  // the foreground app normally does, so when the app is closed this
  // worker is the only closer). Reads tp/sl from the server position,
  // overlaid with the device-local limits the user edited after opening
  // (same merge as the app's effectiveLimit). Exit-side pricing: a buy
  // is sold at bid, a sell is bought back at ask.
  if (quote != null) {
    Map<String, dynamic> localLimits = const {};
    final limitsRaw = prefs.getString('tj_paper_limits');
    if (limitsRaw != null) {
      try {
        localLimits = Map<String, dynamic>.from(jsonDecode(limitsRaw));
      } catch (_) {}
    }
    double? effLimit(Map<String, dynamic> p, String key) {
      final local = localLimits[p['id'].toString()];
      if (local is Map && local.containsKey(key)) {
        return (local[key] as num?)?.toDouble();
      }
      return (p[key] as num?)?.toDouble();
    }

    var nid = 50;
    for (final p in positions.where((p) => p['status'] == 'open')) {
      final buy = p['direction'] == 'buy';
      final mark = buy ? quote.bid : quote.ask;
      final tp = effLimit(p, 'tp');
      final sl = effLimit(p, 'sl');
      String? why;
      String? label;
      why = protectionTrigger(p['direction'], mark, tp, sl);
      label = why == 'SL hit' ? 'Stop Loss Hit' : 'Take Profit';
      if (why == null) continue;
      // Spec 21: the same slippage setting applies to worker fills.
      final slipMode = prefs.getString('tj_slippage_mode') ?? 'off';
      final slipCustom = prefs.getDouble('tj_slippage_custom') ?? 0;
      final slipAmt = slipMode == 'low'
          ? 0.05
          : slipMode == 'custom'
          ? (slipCustom < 0 ? 0 : slipCustom)
          : 0.0;
      final fillPx = buy ? mark - slipAmt : mark + slipAmt;
      final res = await _closePosition(
        pin,
        p['id'],
        fillPx,
        why,
        quote.ts.millisecondsSinceEpoch,
      );
      if (res == null) continue; // failed - retry next cycle, no notification
      closedIds.add(p['id'].toString());
      final closeKey = 'close:${p['id']}';
      if (notifiedHas(prefs, closeKey)) continue; // app already told him
      final pnl = (res['pnl'] as num?)?.toDouble();
      final pnlTxt = pnl != null
          ? ' · P/L ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}'
          : '';
      pending.add((
        closeKey,
        nid++,
        '$label',
        '${buy ? 'Buy' : 'Sell'} XAU/USD ${_qty(p)} closed at ${mark.toStringAsFixed(2)}$pnlTxt',
      ));
    }
    if (closedIds.isNotEmpty) {
      positions = await _fetchPositions(pin);
    }
  }

  // --- TP/SL fallback (position closed since the last successful check,
  // e.g. from another device). Only VERIFIED new closes: a candidate must
  // be closed now with a closed_at after the last check, and it must not
  // have been closed already when the snapshot was taken. Older snapshots
  // stored the full history, so without this every old close re-notified.
  final prevRaw = prefs.getString('tj_bg_positions');
  if (prevRaw != null) {
    try {
      final prev = List<Map<String, dynamic>>.from(
        (jsonDecode(prevRaw) as List).map(
          (e) => Map<String, dynamic>.from(e as Map),
        ),
      );
      var nid = 1;
      for (final p in newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: closedIds,
        lastRun: lastRun,
      )) {
        final id = p['id'].toString();
        final dir = p['direction'] == 'buy' ? 'Buy' : 'Sell';
        const why = 'closed; refresh history for the recorded fill and reason';
        final closeKey = 'close:$id';
        if (notifiedHas(prefs, closeKey)) continue; // app already told him
        pending.add((
          closeKey,
          nid++,
          'Sona: position closed',
          '$dir XAU/USD ${_qty(p)} - $why',
        ));
      }
    } catch (_) {}
  }
  await prefs.setString(
    'tj_bg_positions',
    encodeOpenPositionsSnapshot(positions),
  );

  // --- Price alerts ---
  final alertPrice = quote?.mid;
  if (alertPrice != null) {
    final price = alertPrice;
    final raw = prefs.getString('tj_price_alerts');
    if (raw != null) {
      try {
        final alerts = List<Map<String, dynamic>>.from(jsonDecode(raw));
        var changed = false;
        var nid = 100;
        for (final a in alerts) {
          if (a['triggered'] == true) continue;
          final level = (a['level'] as num?)?.toDouble();
          if (level == null) continue;
          final above = a['above'] == true;
          final hit = above ? price >= level : price <= level;
          if (!hit) continue;
          a['triggered'] = true;
          a['triggeredAt'] = DateTime.now().toIso8601String();
          changed = true;
          final alertKey = 'alert:${a['id'] ?? '$level:$above'}';
          if (notifiedHas(prefs, alertKey)) continue; // app already told him
          pending.add((
            alertKey,
            nid++,
            'Sona: price alert',
            'XAU/USD ${above ? "rose above" : "fell below"} $level (now ${price.toStringAsFixed(2)})',
          ));
        }
        if (changed) {
          await prefs.setString('tj_price_alerts', jsonEncode(alerts));
        }
      } catch (_) {}
    }
  }

  // Flush queued notifications: individually when the last check was
  // recent; as ONE summary when this run is a catch-up after the worker
  // was killed/asleep (no stale-notification bursts). Every event is still
  // marked notified so nothing repeats.
  if (pending.isNotEmpty) {
    // Cross-isolate same-event guard: the app may have closed and marked
    // the same position while this worker was fetching. Re-check marks
    // against fresh prefs, then claim BEFORE posting so the other path's
    // read sees the claim even while posts are still going out.
    final fresh = <(String, int, String, String)>[];
    for (final e in pending) {
      if (await claimNotification(prefs, e.$1)) fresh.add(e);
    }
    if (fresh.length != pending.length) {
      pending
        ..clear()
        ..addAll(fresh);
    }
  }
  if (pending.isNotEmpty) {
    if (catchUp && pending.length > 1) {
      final closes = pending.where((e) => e.$1.startsWith('close:')).length;
      final alertsN = pending.length - closes;
      final parts = <String>[
        if (closes > 0) '$closes position${closes == 1 ? '' : 's'} closed',
        if (alertsN > 0) '$alertsN price alert${alertsN == 1 ? '' : 's'}',
      ];
      await _notify(
        900,
        'Sona: while you were away',
        '${parts.join(' · ')} - tap to view',
      );
    } else {
      for (final e in pending) {
        await _notify(e.$2, e.$3, e.$4);
      }
    }
  }
  if (quote != null) {
    await prefs.setString('tj_bg_last_run', DateTime.now().toIso8601String());
    // Keep the Friday bridge snapshot fresh even when the app is closed.
    OroBridge.noteQuote(
      prefs,
      quote.bid,
      quote.ask,
      quote.ts.millisecondsSinceEpoch,
    );
  }

  // AI auto-trade: the brain runs after position housekeeping so a fresh
  // close is seen before the next decision. Never let it break the worker.
  try {
    await AutoTrade.think(prefs);
  } catch (_) {}
}

String _qty(Map<String, dynamic> p) =>
    'x${(p['qty'] as num?)?.toStringAsFixed(2) ?? '?'}';
