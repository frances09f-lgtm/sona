import 'execution_ledger.dart';
import 'replay.dart';
import 'trade_safety.dart';
import 'journal_record.dart';
import 'strategies_screen.dart';
import 'history_summary.dart';

import 'dart:async';

import 'user_api_keys.dart';
import 'pending_orders.dart';
import 'paper_margin.dart';
import 'chart_explanation.dart';
import 'learn_screen.dart';

import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'market_data/market_data_config.dart';
import 'update/app_update.dart';
import 'market_data/models.dart';
import 'market_data/twelve_data_candles.dart';
import 'market_data/swissquote_provider.dart';
import 'chart/candle_chart.dart';
import 'chart/chart_tools.dart' show TickBuffer;
import 'chart/chart_tools.dart';
import 'analytics.dart';
import 'trade_card.dart';
import 'ai_brain.dart';
import 'alerts.dart';
import 'auto_trade.dart';
import 'notification_log.dart';
import 'sessions.dart';
import 'slippage.dart';
import 'watch_service.dart';
import 'bridge.dart';
import 'notifications.dart';
import 'usage_reporter.dart';

const String sbUrl = 'https://ncaialkmxhbtarmhoiei.supabase.co';
const String sbKey = 'sb_publishable_oNw5xcfdpesEihrdmFXfgQ_HKgsVYAi';

const cBg = Color(0xFF0F1115);
const cCard = Color(0xFF171A21);
const cBorder = Color(0xFF232834);
const cDim = Color(0xFF8A93A5);
const cGreen = Color(0xFF2ECC71);
const cRed = Color(0xFFFF5A5F);

String fmt(num? n, {bool sign = false}) {
  if (n == null) return '-';
  // Adaptive precision: tiny values (e.g. 0.0024 oz) must not round to 0.00.
  final a = n.abs();
  final s = (a > 0 && a < 0.01) ? n.toStringAsFixed(4) : n.toStringAsFixed(2);
  return (sign && n > 0 ? '+' : '') + s;
}

String money(num? n, {bool sign = false}) {
  if (n == null) return '-';
  final neg = n < 0;
  final s = (neg ? '-' : (sign && n > 0 ? '+' : '')) + '\$' + fmt(n.abs());
  return s;
}

/// XM-style lots: 1 lot = 100 oz (min/step 0.01 lot = 1 oz).
String lotsStr(num qtyOz) {
  final l = qtyOz / 100;
  final s = (l > 0 && l < 0.01) ? l.toStringAsFixed(4) : l.toStringAsFixed(2);
  return '$s lot${l > 0.01 ? 's' : ''} (${fmt(qtyOz)} oz)';
}

Color cls(num? n) =>
    n == null ? cDim : (n > 0 ? cGreen : (n < 0 ? cRed : cDim));

/// $ outcome if this position exits at [level]: (level - entry) * dir * qty.
/// Used to show "+$5" at TP / "-$2" at SL (user request), live in dialogs
/// and on open-position cards.
double? pnlAtLevel(Map<String, dynamic> t, double? level) {
  if (level == null) return null;
  final entry = (t['entry'] as num?)?.toDouble();
  final qty = (t['qty'] as num?)?.toDouble();
  if (entry == null || qty == null) return null;
  final dir = t['direction'] == 'buy' ? 1.0 : -1.0;
  return (level - entry) * dir * qty;
}

double? quickProtectionLevel(
  Map<String, dynamic> position,
  String key,
  double offset,
) {
  final entry = (position['entry'] as num?)?.toDouble();
  if (entry == null || !entry.isFinite) return null;
  final buy = position['direction'] == 'buy';
  return entry + ((key == 'tp') == buy ? offset : -offset);
}

class RpcException implements Exception {
  final String message;
  final bool badPin;
  final int? status;
  RpcException(this.message, this.badPin, [this.status]);
  @override
  String toString() => message;
}

class AppState extends ChangeNotifier {
  String pin = '';
  bool unlocked = false;
  String lockError = '';
  bool unlocking = false;

  double? price; // mid (display / chart)
  double? bid; // real bid, when the feed provides it
  double? ask; // real ask, when the feed provides it
  int priceAt = 0;
  bool priceOk = false;

  /// Stage (c): execution prices. Buys open at ASK and close at BID;
  /// sells open at BID and close at ASK. Spread is a real trading cost,
  /// so it must be inside entry/exit prices and therefore inside PnL.
  /// Falls back to the single mid price when the feed has no spread.
  double? entrySidePrice(String dir) {
    final px = dir == 'buy' ? (ask ?? price) : (bid ?? price);
    // Spec 21: optional slippage worsens the fill, never improves it.
    return px == null ? null : slippage.fill(px, buying: dir == 'buy');
  }

  double? exitSidePrice(String dir) {
    // a buy is sold at bid, a sell is bought back at ask
    final px = dir == 'buy' ? (bid ?? price) : (ask ?? price);
    return px == null ? null : slippage.fill(px, buying: dir != 'buy');
  }

  double? get spread => (bid != null && ask != null) ? ask! - bid! : null;

  /// Public wrapper so screens can ask dependents to rebuild after they
  /// mutate persisted preferences outside AppState's own setters.
  void refresh() => notifyListeners();

  /// Single price basis for everything drawn on the chart: the live line,
  /// its price tag, the forming candle's close and the big header number.
  /// MetaTrader/XM OTC charts are based on bid, so we use bid too (mid as
  /// fallback if a mid-only feed answered).
  double? get chartBasis => bid ?? price;

  bool get priceFresh =>
      priceOk &&
      freshExecutionQuote(
        bid ?? price,
        ask ?? price,
        priceAt,
        DateTime.now().millisecondsSinceEpoch,
      );

  double starting = 10000;
  double balance = 10000;
  int accountRevision = 0;
  bool serverProtection = false;
  int uncertainCloses = 0;
  String protectionStatus =
      'Device checks only: Android may delay or stop them. Always-on server protection is not deployed.';
  Future<void> refreshProtectionCapability() async {
    // Backend adapters/scheduler have not been integrated or verified. Never
    // enable a remote capability flag alone or silently disable device checks.
    serverProtection = false;
    protectionStatus = 'Device checks only: Android may delay or stop them. Always-on server protection is not deployed.';
  }

  int accountAt = 0;
  bool openingPaper = false;
  double? get estimatedFreeMargin => priceFresh && bid != null && ask != null
      ? PaperMargin.estimate(
          balance: balance,
          bid: bid!,
          ask: ask!,
          positions: positions,
        )
      : null;
  List<Map<String, dynamic>> positions = [];
  int notifUnread = 0;
  List<Map<String, dynamic>> trades = [];
  Map<String, Map<String, double?>> limits = {};

  final Set<String> closing = {};
  final Set<String> expanded = {};

  /// Stage (e): journal notes on paper trades. Device-local because the
  /// backend contract has no note field for paper positions.
  Map<String, String> tradeNotes = {};

  void setTradeNote(String tradeId, String note) {
    if (note.trim().isEmpty) {
      tradeNotes.remove(tradeId);
    } else {
      tradeNotes[tradeId] = note.trim();
    }
    prefs?.setString('tj_trade_notes', jsonEncode(tradeNotes));
    notifyListeners();
  }

  /// Stage (e): device-local price alerts, checked on each real quote.
  List<PriceAlert> alerts = [];
  PriceAlert? alertBanner; // most recent trigger, cleared on dismiss

  void _saveAlerts() {
    prefs?.setString(
      'tj_price_alerts',
      jsonEncode(alerts.map((a) => a.toJson()).toList()),
    );
  }

  void addAlert(double level, bool above) {
    alerts.add(
      PriceAlert(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        level: level,
        above: above,
        createdAt: DateTime.now(),
      ),
    );
    _saveAlerts();
    notifyListeners();
  }

  void removeAlert(String id) {
    alerts.removeWhere((a) => a.id == id);
    _saveAlerts();
    notifyListeners();
  }

  void dismissAlertBanner() {
    alertBanner = null;
    notifyListeners();
  }

  Timer? _alertBannerTimer;

  Future<void> _checkAlerts() async {
    if (price == null || !priceOk) return;
    for (final a in alerts) {
      if (a.check(price!)) {
        // Worker may have already notified this alert while the app was
        // dead - sync silently instead of double-notifying.
        if (prefs != null && notifiedHas(prefs!, 'alert:${a.id}')) {
          _saveAlerts();
          continue;
        }
        if (prefs != null) await notifiedAdd(prefs!, 'alert:${a.id}');
        alertBanner = a;
        _saveAlerts();
        // User request: a triggered banner auto-dismisses after 30s; the
        // manual close button still works for earlier dismissal.
        _alertBannerTimer?.cancel();
        _alertBannerTimer = Timer(const Duration(seconds: 30), () {
          alertBanner = null;
          notifyListeners();
        });
        // Also post a real system notification: otherwise an alert that
        // fires while the app is open is banner-only AND marked triggered,
        // so the background worker never notifies for it either.
        showForegroundNotification(
          'Sona: price alert',
          'XAU/USD ${a.above ? "rose above" : "fell below"} ${a.level} (now ${price!.toStringAsFixed(2)})',
        );
      }
    }
    if (alertBanner != null) notifyListeners();
  }

  Timer? _priceTimer;
  Timer? _ticker;
  SharedPreferences? prefs;
  PendingPaperOrders? pendingOrders;
  Future<void> evaluatePending() async {
    if (!unlocked || !priceFresh || bid == null || ask == null) return;
    await pendingOrders?.evaluate(
      bid: bid!,
      ask: ask!,
      fresh: priceFresh,
      active:
          WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed,
      now: DateTime.now().millisecondsSinceEpoch,
      submit: (o) => openPaper(o.side, o.qty, o.tp, o.sl),
    );
    notifyListeners();
  }

  double? effectiveLimit(Map<String, dynamic> t, String key) {
    final local = limits[t['id'].toString()];
    if (local != null && local.containsKey(key)) return local[key];
    final v = t[key];
    return v == null ? null : (v as num).toDouble();
  }

  Future<void> init() async {
    UsageReporter.report('app_start');
    prefs = await SharedPreferences.getInstance();
    pendingOrders = PendingPaperOrders.load(prefs!);
    await pendingOrders!.save();
    pin = prefs?.getString('tj_pin') ?? '';
    final raw = prefs?.getString('tj_paper_limits');
    if (raw != null) {
      try {
        final m = jsonDecode(raw) as Map<String, dynamic>;
        m.forEach((k, v) {
          limits[k] = {};
          (v as Map<String, dynamic>).forEach((k2, v2) {
            limits[k]![k2] = v2 == null ? null : (v2 as num).toDouble();
          });
        });
      } catch (_) {}
    }
    final rawNotes = prefs?.getString('tj_trade_notes');
    if (rawNotes != null) {
      try {
        tradeNotes = Map<String, String>.from(jsonDecode(rawNotes) as Map);
      } catch (_) {}
    }
    _loadDailyLimits();
    _loadSlippage();
    final rawAlerts = prefs?.getString('tj_price_alerts');
    if (rawAlerts != null) {
      try {
        alerts = (jsonDecode(rawAlerts) as List)
            .map((e) => PriceAlert.fromJson(Map<String, dynamic>.from(e)))
            .whereType<PriceAlert>()
            .toList();
      } catch (_) {}
    }
    final cache = prefs?.getString('tj_paper_cache');
    if (cache != null) {
      try {
        final m = jsonDecode(cache) as Map<String, dynamic>;
        starting = (m['starting'] as num?)?.toDouble() ?? starting;
        balance = (m['balance'] as num?)?.toDouble() ?? balance;
        positions = List<Map<String, dynamic>>.from(
          m['positions'] as List? ?? [],
        );
      } catch (_) {}
    }
    fetchPrice();
    // Live chart (user request): poll the free Swissquote BBO feed every
    // 1s. The feed itself ticks every ~1.5s during liquid hours, so 1s
    // polling shows nearly every tick (3s polling hid over half of them,
    // which read as "the price moves very slow"). The 1m candle HISTORY
    // refresh stays at 15s to respect TwelveData 8/min.
    _priceTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      fetchPrice();
    });
    _ticker = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!unlocked) return;
      // User request: triggered price alerts auto-remove after 1 minute
      // (the banner separately auto-dismisses after 30s).
      final cutoff = DateTime.now().subtract(const Duration(minutes: 1));
      final before = alerts.length;
      alerts.removeWhere(
        (a) =>
            a.triggered &&
            a.triggeredAt != null &&
            a.triggeredAt!.isBefore(cutoff),
      );
      if (alerts.length != before) _saveAlerts();
      refreshNotifUnread();
      notifyListeners();
    });
    if (pin.isNotEmpty) await unlock(pin);
  }

  void _saveLimits() {
    prefs?.setString('tj_paper_limits', jsonEncode(limits));
  }

  // --- Daily trading limits (spec 31). Device-local; 0/empty = off. ---
  int maxTradesDay = 0;
  double maxDailyLoss = 0;
  bool blockOnLimit = false;

  Slippage slippage = const Slippage('off');

  void _loadSlippage() {
    slippage = Slippage(
      prefs?.getString('tj_slippage_mode') ?? 'off',
      prefs?.getDouble('tj_slippage_custom') ?? 0,
    );
  }

  void setSlippage(String mode, double custom) {
    slippage = Slippage(mode, custom);
    prefs?.setString('tj_slippage_mode', mode);
    prefs?.setDouble('tj_slippage_custom', custom);
    notifyListeners();
  }

  void _loadDailyLimits() {
    maxTradesDay = prefs?.getInt('tj_lim_trades') ?? 0;
    maxDailyLoss = prefs?.getDouble('tj_lim_loss') ?? 0;
    blockOnLimit = prefs?.getBool('tj_lim_block') ?? false;
  }

  void setDailyLimits({int? trades, double? loss, bool? block}) {
    if (trades != null) {
      maxTradesDay = trades;
      prefs?.setInt('tj_lim_trades', trades);
    }
    if (loss != null) {
      maxDailyLoss = loss;
      prefs?.setDouble('tj_lim_loss', loss);
    }
    if (block != null) {
      blockOnLimit = block;
      prefs?.setBool('tj_lim_block', block);
    }
    notifyListeners();
  }

  int tradesToday() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    return positions.where((p) {
      final d = DateTime.tryParse(p['opened_at']?.toString() ?? '')?.toLocal();
      return d != null && !d.isBefore(start);
    }).length;
  }

  double realizedToday() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day);
    var sum = 0.0;
    for (final p in positions) {
      if (p['status'] != 'closed') continue;
      final d = DateTime.tryParse(p['closed_at']?.toString() ?? '')?.toLocal();
      if (d == null || d.isBefore(start)) continue;
      sum += (p['pnl'] as num?)?.toDouble() ?? 0;
    }
    return sum;
  }

  /// Null when inside limits; otherwise why a new trade should warn/block.
  String? limitWarning() {
    if (maxTradesDay > 0 && tradesToday() >= maxTradesDay) {
      return 'Max trades/day reached ($maxTradesDay)';
    }
    if (maxDailyLoss > 0 && realizedToday() <= -maxDailyLoss) {
      return 'Daily loss limit hit (today: ${money(realizedToday(), sign: true)})';
    }
    return null;
  }

  void setLimit(String tid, String key, double? value) {
    limits[tid] = {...(limits[tid] ?? {}), key: value};
    _saveLimits();
    notifyListeners();
  }

  Future<dynamic> rpc(String fn, Map<String, dynamic> args) async {
    final r = await http
        .post(
          Uri.parse('$sbUrl/rest/v1/rpc/$fn'),
          headers: {'apikey': sbKey, 'Content-Type': 'application/json'},
          body: jsonEncode(args),
        )
        .timeout(const Duration(seconds: 20));
    dynamic j;
    try {
      j = jsonDecode(r.body);
    } catch (_) {
      j = null;
    }
    if (r.statusCode >= 400) {
      final m = (j is Map && j['message'] != null)
          ? j['message'].toString()
          : 'Request failed';
      throw RpcException(m, m.toLowerCase().contains('bad pin'), r.statusCode);
    }
    return j;
  }

  Future<bool> unlock(String p) async {
    unlocking = true;
    lockError = '';
    notifyListeners();
    try {
      final list = await rpc('j_list', {'p': p});
      trades = List<Map<String, dynamic>>.from(list as List)
          .map(decodeJournal)
          .toList();
      pin = p;
      unlocked = true;
      await prefs?.setString('tj_pin', p);
      await paperRefresh();
      await refreshProtectionCapability();
      unlocking = false;
      notifyListeners();
      return true;
    } on RpcException catch (e) {
      unlocking = false;
      lockError = e.badPin ? 'Wrong PIN' : 'Cannot connect. Check internet.';
      if (e.badPin) await prefs?.remove('tj_pin');
      notifyListeners();
      return false;
    } catch (_) {
      unlocking = false;
      lockError = 'Cannot connect. Check internet.';
      notifyListeners();
      return false;
    }
  }

  Future<void> lock() async {
    unlocked = false;
    pin = '';
    await prefs?.remove('tj_pin');
    notifyListeners();
  }

  bool _fetching = false;
  int _lastFallbackTry = 0;

  /// Recent bid ticks from the Swissquote stream. The chart builds its
  /// forming bar from these - the same stream that drives the live line -
  /// so the last candle and the line share one source.
  final TickBuffer _tickBuffer = TickBuffer();
  List<(int, double)> get liveTicks => List.unmodifiable(_tickBuffer.ticks);

  Future<void> fetchPrice() async {
    if (_fetching) return; // 1s cadence: never stack overlapping fetches
    _fetching = true;
    // Stage (c): primary source is the Swissquote public BBO feed with a
    // real bid/ask spread. Mid-only feeds remain as fallback.
    try {
      final q = await SwissquoteQuoteProvider().fetchQuote(Instrument.xauUsd);
      bid = q.bid;
      ask = q.ask;
      price = q.mid;
      priceAt = q.ts.millisecondsSinceEpoch;
      if (bid != null) _tickBuffer.add(DateTime.now(), bid!);
      priceOk = true;
      notifyListeners();
      OroBridge.noteQuote(prefs, bid, ask, priceAt);
      unawaited(evaluatePending());
      checkTpsl();
      _checkAlerts();
      _fetching = false;
      return;
    } catch (_) {}
    // Fallback feeds are minute-granularity mid prices. At the 1s poll
    // cadence, retrying them every tick would hammer two free endpoints
    // for no fresher data, so run the fallback chain at most every 10s.
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastFallbackTry < 10000) {
      _fetching = false;
      return;
    }
    _lastFallbackTry = nowMs;
    Future<({double p, int t})?> trySource(int which) async {
      try {
        if (which == 0) {
          final r = await http
              .get(Uri.parse('https://api.gold-api.com/price/XAU'))
              .timeout(const Duration(seconds: 10));
          final j = jsonDecode(r.body);
          final p = (j['price'] as num).toDouble();
          final t =
              DateTime.tryParse(j['updatedAt']?.toString() ?? '')
                  ?.millisecondsSinceEpoch ??
              0;
          return (p: p, t: t);
        } else {
          final r = await http
              .get(Uri.parse('https://data-asg.goldprice.org/dbXRates/USD'))
              .timeout(const Duration(seconds: 10));
          final j = jsonDecode(r.body);
          final p = (j['items'][0]['xauPrice'] as num).toDouble();
          final rawAt = j['ts'];
          final t = rawAt is num ? rawAt.toInt() : 0;
          return (p: p, t: t);
        }
      } catch (_) {
        return null;
      }
    }

    for (final w in [0, 1]) {
      final q = await trySource(w);
      if (q != null && q.p.isFinite && q.p > 0) {
        price = q.p;
        bid = q.p;
        ask = q.p;
        priceAt = q.t;
        priceOk = true;
        notifyListeners();
        OroBridge.noteQuote(prefs, bid, ask, priceAt);
        unawaited(evaluatePending());
        checkTpsl();
        _checkAlerts();
        _fetching = false;
        return;
      }
    }
    priceOk = false;
    notifyListeners();
    _fetching = false;
  }

  Future<void> refreshNotifUnread() async {
    final p = prefs;
    if (p == null) return;
    final n = NotificationLog.unread(p);
    if (n != notifUnread) {
      notifUnread = n;
      notifyListeners();
    }
  }

  Future<void> paperRefresh() async {
    if (!unlocked) return;
    try {
      final s = await rpc('paper_state', {'p': pin});
      starting = (s['starting'] as num).toDouble();
      balance = (s['balance'] as num).toDouble();
      positions = List<Map<String, dynamic>>.from(
        s['positions'] as List? ?? [],
      );
      try {
        await ExecutionLedger.reconcile(positions);
        uncertainCloses = await ExecutionLedger.pendingCount();
      } catch (_) {}
      accountRevision++;
      accountAt = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
      // Stage (d): device-local cache so the app opens with last-known
      // state while offline; the network refresh above always wins.
      prefs?.setString(
        'tj_paper_cache',
        jsonEncode({
          'accountAt': DateTime.now().millisecondsSinceEpoch,
          'starting': starting,
          'balance': balance,
          'positions': positions,
        }),
      );
      OroBridge.notePaper(prefs);
      // Keep the background worker's position set in sync so a position
      // closed manually in the app is not later misreported as TP/SL.
      prefs?.setString(
        'tj_bg_positions',
        jsonEncode(
          positions
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
        ),
      );
      // v15 "always watching" (spec 35): native foreground service keeps the
      // process alive while positions are open so the background TP/SL and
      // price-alert checks survive OEM task-killers. Checking itself stays
      // in the existing worker; this only shows the persistent notification.
      WatchService.sync(positions.where((p) => p['status'] == 'open').length);
    } on RpcException catch (e) {
      if (e.badPin) lock();
    } catch (_) {}
  }

  Future<void> refreshTrades() async {
    if (!unlocked) return;
    try {
      final list = await rpc('j_list', {'p': pin});
      trades = List<Map<String, dynamic>>.from(list as List)
          .map(decodeJournal)
          .toList();
      notifyListeners();
    } on RpcException catch (e) {
      if (e.badPin) lock();
    } catch (_) {}
  }

  double? livePnl(Map<String, dynamic> t) {
    if (!priceOk || price == null) return null;
    final entry = (t['entry'] as num).toDouble();
    final qty = (t['qty'] as num).toDouble();
    final dirStr = t['direction'] == 'buy' ? 'buy' : 'sell';
    final dir = t['direction'] == 'buy' ? 1.0 : -1.0;
    final mark = exitSidePrice(
      dirStr,
    ); // a buy is sold at bid, a sell bought back at ask
    if (mark == null) return null;
    return (mark - entry) * dir * qty;
  }

  double? movePct(Map<String, dynamic> t) {
    if (!priceOk || price == null) return null;
    final entry = (t['entry'] as num).toDouble();
    final dirStr = t['direction'] == 'buy' ? 'buy' : 'sell';
    final dir = t['direction'] == 'buy' ? 1.0 : -1.0;
    final mark = exitSidePrice(dirStr);
    if (mark == null) return null;
    return (mark - entry) / entry * 100 * dir;
  }

  double floatPnl() {
    double sum = 0;
    for (final t in positions.where((t) => t['status'] == 'open')) {
      sum += livePnl(t) ?? 0;
    }
    return sum;
  }

  Future<String?> openPaper(
    String dir,
    double qty,
    double? tp,
    double? sl,
  ) async {
    if (!unlocked)
      return 'Paper account not connected. Open the account button to connect.';
    if (!priceFresh) {
      return marketClosedMessage() ??
          'No fresh live price - cannot open right now.';
    }
    final warn = limitWarning();
    if (warn != null && blockOnLimit) {
      return '$warn - new trades blocked (Daily limits)';
    }
    if (!['buy', 'sell'].contains(dir) || !qty.isFinite || qty <= 0)
      return 'Enter a valid side and positive size.';
    if (openingPaper)
      return 'Another paper order is being checked. Wait for its result.';
    openingPaper = true;
    try {
      final before = accountRevision;
      await paperRefresh();
      if (!unlocked || accountRevision == before)
        return 'Could not refresh the paper account. No order submitted.';
      final px = entrySidePrice(dir);
      if (px == null || !priceFresh)
        return 'No fresh live bid/ask - cannot open right now.';
      final marginError = PaperMargin.guard(
        free: estimatedFreeMargin,
        price: px,
        qty: qty,
      );
      if (marginError != null) return marginError;
      final protectionError = validateProtection(dir, px, tp, sl);
      if (protectionError != null) return protectionError;
      await rpc('paper_open', {
        'p': pin,
        'd': dir,
        'price': px,
        'q': qty,
        'target': tp,
        'stop': sl,
      });
      UsageReporter.report('trade_opened', {'src': 'manual'});
      await paperRefresh();
      return null;
    } on RpcException catch (e) {
      return e.message;
    } catch (_) {
      return 'Could not open trade';
    } finally {
      openingPaper = false;
    }
  }

  Future<String?> closePaper(Map<String, dynamic> t, {String? reason}) async {
    if (!unlocked) return 'Paper account not connected.';
    final id = t['id'].toString();
    if (closing.contains(id)) return null;
    if (!priceFresh) {
      return marketClosedMessage() ?? 'No fresh live price - try Refresh';
    }
    final px = exitSidePrice(t['direction'] == 'buy' ? 'buy' : 'sell');
    if (px == null) return 'No fresh live price - try Refresh';
    try {
      if (!await ExecutionLedger.claim(
        id,
        priceAt,
        px,
        reason ?? 'Manual close',
      )) {
        return 'A close was already submitted. Refresh to confirm; no duplicate sent.';
      }
    } catch (_) {
      return 'Execution safety storage unavailable. No close submitted.';
    }
    closing.add(id);
    notifyListeners();
    try {
      final r = await rpc('paper_close', {
        'p': pin,
        'tid': t['id'],
        'price': px,
        'why': reason ?? 'Manual close',
      });
      // Read back authoritative state before reporting execution success.
      await paperRefresh();
      if (!positions.any(
        (p) => p['id'].toString() == id && p['status'] == 'closed',
      )) {
        closing.remove(id);
        uncertainCloses = await ExecutionLedger.pendingCount();
        notifyListeners();
        return 'Close outcome unconfirmed. Refresh; no duplicate will be submitted.';
      }
      UsageReporter.report('trade_closed', {'src': 'manual'});
      closing.remove(id);
      // Dedupe with the background worker: it must not re-notify this close.
      if (prefs != null) await notifiedAdd(prefs!, 'close:$id');
      await paperRefresh();
      final pnl = (r is Map && r['pnl'] != null)
          ? (r['pnl'] as num).toDouble()
          : null;
      // Auto TP/SL closes happen silently otherwise: no banner, and
      // paperRefresh() syncs the worker's position set so the background
      // path never reports them either. Post a system notification.
      if (reason == 'TP hit' || reason == 'SL hit') {
        final dirLabel = t['direction'] == 'buy' ? 'Buy' : 'Sell';
        final q = (t['qty'] as num?)?.toDouble();
        final pnlTxt = pnl != null ? ' · P/L ${money(pnl, sign: true)}' : '';
        showForegroundNotification(
          reason == 'TP hit' ? 'Take Profit' : 'Stop Loss Hit',
          '$dirLabel XAU/USD x${q?.toStringAsFixed(2) ?? '?'} closed at ${px.toStringAsFixed(2)}$pnlTxt',
        );
      }
      return pnl != null ? 'closed:${money(pnl, sign: true)}' : 'closed';
    } catch (e) {
      closing.remove(id);
      notifyListeners();
      if (e is RpcException &&
          e.status != null &&
          e.status! >= 400 &&
          e.status! < 500) {
        await ExecutionLedger.rejected(id);
        return e.message;
      }
      uncertainCloses++;
      return 'Close outcome unconfirmed. Refresh; no automatic retry will be sent.';
    }
  }

  void checkTpsl() {
    if (!priceFresh || !unlocked || serverProtection) return;
    for (final t in positions.where((t) => t['status'] == 'open')) {
      final mark = exitSidePrice(t['direction']);
      if (mark == null) continue;
      final reason = protectionTrigger(
        t['direction'],
        mark,
        effectiveLimit(t, 'tp'),
        effectiveLimit(t, 'sl'),
      );
      if (reason != null) unawaited(closePaper(t, reason: reason));
    }
  }

  Future<String?> saveTrade(Map<String, dynamic> t) async {
    try {
      await rpc('j_save', {'p': pin, 't': encodeJournal(t)});
      await refreshTrades();
      return null;
    } on RpcException catch (e) {
      return e.badPin
          ? 'PIN changed. Lock and re-enter.'
          : 'Could not save: ${e.message}';
    } catch (_) {
      return 'Could not save';
    }
  }

  Future<String?> deleteTrade(Map<String, dynamic> t) async {
    try {
      await rpc('j_delete', {'p': pin, 'tid': t['id']});
      await refreshTrades();
      return null;
    } catch (_) {
      return 'Could not delete';
    }
  }

  /// Edit the CURRENT paper balance (Oro request). Uses the additive
  /// paper_set_balance RPC; the backend guards by PIN and range.
  Future<String?> setBalance(double a) async {
    try {
      await rpc('paper_set_balance', {'p': pin, 'amount': a});
      await paperRefresh();
      return null;
    } catch (_) {
      return 'Could not update';
    }
  }

  Future<String?> setStarting(double a) async {
    try {
      await rpc('paper_balance', {'p': pin, 'amount': a});
      await paperRefresh();
      return null;
    } catch (_) {
      return 'Could not update';
    }
  }

  Future<String?> resetPaper(double a) async {
    try {
      await rpc('paper_reset', {'p': pin, 'amount': a});
      await paperRefresh();
      return null;
    } catch (_) {
      return 'Could not reset';
    }
  }

  List<({double pnl, DateTime at})> allClosed() {
    final out = <({double pnl, DateTime at})>[];
    for (final t in trades) {
      if (t['pnl'] != null) {
        out.add((
          pnl: (t['pnl'] as num).toDouble(),
          at:
              DateTime.tryParse(t['traded_at']?.toString() ?? '') ??
              DateTime.now(),
        ));
      }
    }
    for (final t in positions) {
      if (t['status'] == 'closed' && t['pnl'] != null) {
        out.add((
          pnl: (t['pnl'] as num).toDouble(),
          at:
              DateTime.tryParse(t['closed_at']?.toString() ?? '') ??
              DateTime.now(),
        ));
      }
    }
    out.sort((a, b) => a.at.compareTo(b.at));
    return out;
  }
}

ThemeData buildAppTheme() => ThemeData(
  brightness: Brightness.dark,
  fontFamily: 'Roboto',
  scaffoldBackgroundColor: cBg,
  colorScheme: const ColorScheme.dark(
    surface: cCard,
    primary: cGreen,
    error: cRed,
    onSurface: Colors.white,
  ),
  appBarTheme: const AppBarTheme(backgroundColor: cBg, elevation: 0),
  cardColor: cCard,
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: cBg,
    border: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: cBorder),
    ),
    enabledBorder: OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: const BorderSide(color: cBorder),
    ),
  ),
);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await UserApiKeys.load();
  // Local notifications + background TP/SL / alert checks (Oro request).
  // Android WorkManager minimum cadence is ~15 min; failures degrade silently.
  try {
    await initNotifications();
  } catch (_) {}
  runApp(const SonaApp());
}

class SonaApp extends StatelessWidget {
  const SonaApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Sona',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const Root(),
    );
  }
}

class Root extends StatefulWidget {
  final AppState? testApp;
  final CandleLoader? candleLoaderOverride;
  const Root({super.key, this.testApp, this.candleLoaderOverride});
  @override
  State<Root> createState() => _RootState();
}

class _RootState extends State<Root> with WidgetsBindingObserver {
  late final AppState app = widget.testApp ?? AppState();
  int tab = 0;
  final tradeKey = GlobalKey<_TradeTabState>();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.testApp == null) {
      app.init();
      // In-app self-update: check the latest GitHub release once per few
      // hours and prompt with release notes + in-app APK download.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) maybePromptUpdate(context);
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) {
      app.fetchPrice();
      app.paperRefresh();
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: app,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text(
              'Sona',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            actions: [
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => SonaSettingsScreen(app: app),
                    ),
                  );
                  if (mounted) setState(() {});
                },
              ),
              IconButton(
                tooltip: 'Paper account',
                icon: Icon(
                  app.unlocked
                      ? Icons.account_circle
                      : Icons.account_circle_outlined,
                ),
                onPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => LockScreen(app: app))),
              ),
              IconButton(
                tooltip: 'Notification history',
                icon: Badge(
                  isLabelVisible: app.notifUnread > 0,
                  label: Text('${app.notifUnread}'),
                  child: const Icon(Icons.notifications_none),
                ),
                onPressed: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const NotificationHistoryScreen(),
                    ),
                  );
                  app.refreshNotifUnread();
                },
              ),
            ],
          ),
          body: Column(
            children: [
              if (!app.unlocked)
                MaterialBanner(
                  content: Text(
                    app.unlocking
                        ? 'Connecting saved paper account...'
                        : 'Paper account not connected. Quotes are available.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => LockScreen(app: app)),
                      ),
                      child: const Text('Connect'),
                    ),
                  ],
                ),
              Expanded(
                child: IndexedStack(
                  index: tab,
                  children: [
                    TradeTab(
                      key: tradeKey,
                      app: app,
                      candleLoaderOverride: widget.candleLoaderOverride,
                    ),
                    PositionsTab(app: app),
                    AddTab(app: app),
                    StatsTab(app: app),
                    AiTab(
                      app: app,
                      onExplainChart: () =>
                          tradeKey.currentState?.explainChart(),
                    ),
                  ],
                ),
              ),
            ],
          ),
          bottomNavigationBar: NavigationBar(
            backgroundColor: cCard,
            selectedIndex: tab,
            onDestinationSelected: (i) {
              setState(() => tab = i);
              if (i == 0 || i == 1 || i == 3) app.paperRefresh();
              if (i == 2) app.refreshTrades();
            },
            destinations: [
              const NavigationDestination(
                icon: Icon(Icons.show_chart),
                label: 'Trade',
              ),
              NavigationDestination(
                icon: Badge(
                  isLabelVisible: app.positions
                      .where((t) => t['status'] == 'open')
                      .isNotEmpty,
                  label: Text(
                    '${app.positions.where((t) => t['status'] == 'open').length}',
                  ),
                  child: const Icon(Icons.work_outline),
                ),
                label: 'Portfolio',
              ),
              const NavigationDestination(icon: Icon(Icons.add), label: 'Add'),
              const NavigationDestination(
                icon: Icon(Icons.bar_chart),
                label: 'Stats',
              ),
              const NavigationDestination(
                icon: Icon(Icons.smart_toy_outlined),
                label: 'AI',
              ),
            ],
          ),
        );
      },
    );
  }
}

class SonaSettingsScreen extends StatefulWidget {
  final AppState app;
  const SonaSettingsScreen({super.key, required this.app});
  @override
  State<SonaSettingsScreen> createState() => _SonaSettingsScreenState();
}

class _SonaSettingsScreenState extends State<SonaSettingsScreen> {
  String _mode = 'candles';
  String _intervalCode = '15min';
  String _rangeCode = 'range:1D';
  bool _showAsk = false;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((prefs) {
      if (!mounted) return;
      setState(() {
        _mode = prefs.getString(kChartModePref) ?? _mode;
        _intervalCode = prefs.getString(kChartIntervalPref) ?? _intervalCode;
        _rangeCode = prefs.getString(kChartRangePref) ?? _rangeCode;
        _showAsk = prefs.getBool(kChartShowAskPref) ?? false;
      });
    });
  }

  String _labelFor(bool range, String code) {
    final list = range ? tradeRanges : intervals;
    return list.where((e) => e.code == code).firstOrNull?.label ?? code;
  }

  Future<void> _pick(bool range) async {
    final list = range ? tradeRanges : intervals;
    final current = range ? _rangeCode : _intervalCode;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            for (final iv in list)
              ListTile(
                title: Text(iv.label),
                trailing: iv.code == current
                    ? const Icon(Icons.check, color: Color(0xFFF5C242))
                    : null,
                onTap: () => Navigator.pop(ctx, iv.code),
              ),
          ],
        ),
      ),
    );
    if (chosen == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(kChartModePref, range ? 'range' : 'candles');
    await prefs.setString(range ? kChartRangePref : kChartIntervalPref, chosen);
    await prefs.setInt(
      kChartSelectionRevPref,
      (prefs.getInt(kChartSelectionRevPref) ?? 0) + 1,
    );
    if (!mounted) return;
    setState(() {
      _mode = range ? 'range' : 'candles';
      if (range) {
        _rangeCode = chosen;
      } else {
        _intervalCode = chosen;
      }
    });
    widget.app.refresh();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Settings')),
    body: ListView(
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(
            'Chart',
            style: TextStyle(
              color: Color(0xFF8A93A6),
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.candlestick_chart_outlined),
          title: const Text('Candle interval'),
          subtitle: Text(
            'Chart shows candle intervals - now: ${_labelFor(false, _intervalCode)}${_mode == 'candles' ? ' (active)' : ''}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pick(false),
        ),
        ListTile(
          leading: const Icon(Icons.date_range_outlined),
          title: const Text('History range'),
          subtitle: Text(
            'Chart shows history ranges - now: ${_labelFor(true, _rangeCode)}${_mode == 'range' ? ' (active)' : ''}',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => _pick(true),
        ),
        ListTile(
          leading: const Icon(Icons.psychology_outlined),
          title: const Text('Strategies'),
          subtitle: const Text(
            'Custom price-action strategies: chart levels and backtests',
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => StrategiesScreen(app: widget.app)),
          ),
        ),
        SwitchListTile(
          secondary: const Icon(Icons.show_chart),
          title: const Text('Show ask line'),
          subtitle: const Text(
            'Red dashed line at the buy (ask) price; the yellow bid line always shows',
          ),
          value: _showAsk,
          onChanged: (v) async {
            final prefs = await SharedPreferences.getInstance();
            await prefs.setBool(kChartShowAskPref, v);
            await prefs.setInt(
              kChartSelectionRevPref,
              (prefs.getInt(kChartSelectionRevPref) ?? 0) + 1,
            );
            if (!mounted) return;
            setState(() => _showAsk = v);
            widget.app.refresh();
          },
        ),
        const Divider(),
        ListTile(
          leading: const Icon(Icons.system_update_alt),
          title: const Text('Check for updates'),
          subtitle: const Text('Download and install the latest Sona release'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => checkUpdateManually(context),
        ),
        ListTile(
          leading: const Icon(Icons.key_outlined),
          title: const Text('API settings'),
          subtitle: const Text('Twelve Data candles and Groq AI keys'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => const ApiKeysScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.school_outlined),
          title: const Text('Learn paper trading'),
          subtitle: const Text('Oz, spread, TP/SL and estimated margin'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () =>
              Navigator.of(context)
                  .push(MaterialPageRoute(builder: (_) => const LearnScreen())),
        ),
        ListTile(
          leading: const Icon(Icons.account_circle_outlined),
          title: const Text('Paper account'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context)
              .push(MaterialPageRoute(builder: (_) => LockScreen(app: widget.app))),
        ),
      ],
    ),
  );
}

class LockScreen extends StatefulWidget {
  final AppState app;
  const LockScreen({super.key, required this.app});
  @override
  State<LockScreen> createState() => _LockScreenState();
}

class _LockScreenState extends State<LockScreen> {
  final ctrl = TextEditingController();
  @override
  Widget build(BuildContext context) {
    final app = widget.app;
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Sona',
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Connect existing paper account',
                style: TextStyle(color: cDim),
              ),
              const SizedBox(height: 8),
              const Text(
                'Account PIN is for server access only. You can use quotes and API settings without connecting.',
                style: TextStyle(color: cDim, fontSize: 12),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: ctrl,
                obscureText: true,
                keyboardType: TextInputType.number,
                textAlign: TextAlign.center,
                onSubmitted: (_) async {
                  if (await app.unlock(ctrl.text.trim()) && context.mounted)
                    Navigator.pop(context);
                },
                decoration: const InputDecoration(hintText: 'PIN'),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  style: FilledButton.styleFrom(
                    backgroundColor: cGreen,
                    foregroundColor: Colors.black,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  onPressed: app.unlocking
                      ? null
                      : () async {
                          if (await app.unlock(ctrl.text.trim()) &&
                              context.mounted)
                            Navigator.pop(context);
                        },
                  child: Text(
                    app.unlocking ? 'Connecting...' : 'Connect account',
                  ),
                ),
              ),
              if (app.lockError.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    app.lockError,
                    style: const TextStyle(color: cRed),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

Widget card(Widget child, {EdgeInsets? padding}) => Container(
  width: double.infinity,
  margin: const EdgeInsets.only(bottom: 12),
  padding: padding ?? const EdgeInsets.all(14),
  decoration: BoxDecoration(
    color: cCard,
    borderRadius: BorderRadius.circular(14),
    border: Border.all(color: cBorder),
  ),
  child: child,
);

class TradeTab extends StatefulWidget {
  final AppState app;

  /// Optional test hook: override the candle source (stage b chart).
  /// When null the panel is driven by the configured Twelve Data key.
  final CandleLoader? candleLoaderOverride;
  const TradeTab({super.key, required this.app, this.candleLoaderOverride});
  @override
  State<TradeTab> createState() => _TradeTabState();
}

class _TradeTabState extends State<TradeTab> {
  Future<void> confirmChartAlert(double level) async {
    bool above = app.price == null || level >= app.price!;
    final field = TextEditingController(text: level.toStringAsFixed(2));
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Create price alert?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: field,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: const InputDecoration(
                  labelText: 'XAU/USD level · USD/oz',
                ),
              ),
              SwitchListTile(
                title: Text(
                  above ? 'Notify above this level' : 'Notify below this level',
                ),
                value: above,
                onChanged: (v) => update(() => above = v),
              ),
              const Text(
                'Device-local alert, checked on fresh quotes. Background delivery is best-effort. No trade will be placed.',
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Save alert'),
            ),
          ],
        ),
      ),
    );
    final parsed = double.tryParse(field.text.trim());
    if (yes != true || !mounted) return;
    if (parsed == null || !parsed.isFinite || parsed <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter a positive alert level. Nothing saved.'),
        ),
      );
      return;
    }
    try {
      final prefs = app.prefs;
      if (prefs == null) throw StateError('Alert storage not ready.');
      final alert = PriceAlert(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        level: parsed,
        above: above,
        createdAt: DateTime.now(),
      );
      final saved = await prefs.setString(
        'tj_price_alerts',
        jsonEncode([...app.alerts, alert].map((a) => a.toJson()).toList()),
      );
      if (!saved) throw StateError('Could not save alert.');
      app.alerts.add(alert);
      app.notifyListeners();
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Alert saved: ${above ? "above" : "below"} ${parsed.toStringAsFixed(2)} USD/oz.',
            ),
          ),
        );
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save alert. Try again.')),
        );
    }
  }

  final chartKey = GlobalKey<CandleChartPanelState>();
  bool explaining = false;

  // ---- Bar replay (practice trading over historical bars) ----
  ReplayController? _replay;
  List<Candle>? _replayCandles;
  bool _pickingReplayStart = false;
  bool _replayPlaying = false;
  Timer? _replayTimer;
  double _replaySpeed = 1;

  Widget _replayControls() {
    final r = _replay!;
    final pnl = r.equity - r.startBalance;
    final pnlColor = pnl >= 0 ? cGreen : const Color(0xFFDE1557);
    final lt = r.time.toLocal();
    final stamp =
        '${lt.month.toString().padLeft(2, '0')}-${lt.day.toString().padLeft(2, '0')} '
        '${lt.hour.toString().padLeft(2, '0')}:${lt.minute.toString().padLeft(2, '0')}';
    Widget orderButton(String label, bool buy) => Expanded(
      child: Material(
        color: buy ? cGreen : const Color(0xFFDE1557),
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => _replayOrder(buy),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Center(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: const Color(0xFF9B7BFF),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'REPLAY',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$stamp · P&L ${pnl >= 0 ? '+' : ''}${pnl.toStringAsFixed(2)}'
                '${r.open.isNotEmpty ? ' · ${r.open.length} open' : ''}',
                style: TextStyle(fontSize: 12, color: pnlColor),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(
              onPressed: _replayCycleSpeed,
              child: Text(
                'x${_replaySpeed.toInt()}',
                style: const TextStyle(fontSize: 12),
              ),
            ),
            InkWell(
              onTap: _exitReplay,
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(Icons.close, size: 18, color: cDim),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            orderButton('SELL', false),
            const SizedBox(width: 8),
            InkWell(
              key: const ValueKey('replay-play'),
              onTap: r.atEnd ? null : _replayPlayPause,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  _replayPlaying ? Icons.pause : Icons.play_arrow,
                  color: r.atEnd ? cDim : Colors.white,
                ),
              ),
            ),
            InkWell(
              key: const ValueKey('replay-step'),
              onTap: r.atEnd ? null : _replayStep,
              child: Padding(
                padding: const EdgeInsets.all(8),
                child: Icon(
                  Icons.skip_next,
                  color: r.atEnd ? cDim : Colors.white,
                ),
              ),
            ),
            const SizedBox(width: 8),
            orderButton('BUY', true),
          ],
        ),
        if (r.open.isNotEmpty)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: () => setState(() => r.closeAll()),
              child: const Text('Close all', style: TextStyle(fontSize: 12)),
            ),
          ),
      ],
    );
  }

  Widget _rangeChip(ChartInterval r) {
    final st = chartKey.currentState;
    // Before the chart's first frame, highlight the panel's default (1D).
    final selected = st == null
        ? r.code == 'range:1D'
        : st.usingRange && st.interval.code == r.code;
    return InkWell(
      onTap: () => setState(() {
        chartKey.currentState?.applyChartSelection(range: true, code: r.code);
      }),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          r.label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? Colors.black : cDim,
          ),
        ),
      ),
    );
  }

  Future<void> _openChartFullscreen() async {
    final st = chartKey.currentState;
    if (st == null) return;
    final layout = await Navigator.of(context).push<Map<String, dynamic>>(
      MaterialPageRoute(
        builder: (_) => FullscreenChartPage(
          loader: st.widget.loader,
          livePrice: _replay?.price ?? app.chartBasis,
          rangeMode: st.usingRange,
          onAlertPrice: confirmChartAlert,
          onReplay: () {
            Navigator.of(context).pop();
            _toggleReplay();
          },
          replayOn: _replay != null || _pickingReplayStart,
          onTradeSide: (side) => selectSide(side),
          initialLayout: st.layoutSnapshot(),
          marketUpdates: app,
          marketSnapshot: st.widget.marketSnapshot,
        ),
      ),
    );
    if (layout != null) {
      setState(() => st.applyPreset(layout));
    }
  }

  void _toggleReplay() {
    if (_replay != null) {
      _exitReplay();
      return;
    }
    final chart = chartKey.currentState;
    if (chart == null || chart.candles.length < 30) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Chart still loading - try again.')),
      );
      return;
    }
    setState(() => _pickingReplayStart = true);
  }

  Future<void> _startReplay() async {
    final chart = chartKey.currentState;
    if (chart == null) return;
    final full = List<Candle>.of(chart.candles);
    final sel = chart.selected ?? (full.length - 60);
    final start = sel.clamp(20, full.length - 1) + 1;
    setState(() {
      _replayCandles = full;
      _replay = ReplayController(full, startIndex: start);
      _pickingReplayStart = false;
      _replayPlaying = false;
    });
    await chart.reload();
    // The visible list just shrank to the replay window; drop any
    // scrolled-back offset so the replay edge is on screen.
    chart.jumpToLatest();
  }

  Future<void> _replayStep() async {
    final r = _replay;
    if (r == null) return;
    setState(() {
      r.step();
      if (r.atEnd) {
        r.settle();
        _replayPlaying = false;
        _replayTimer?.cancel();
      }
    });
    await chartKey.currentState?.reload();
  }

  void _replayPlayPause() {
    setState(() {
      _replayPlaying = !_replayPlaying;
      _replayTimer?.cancel();
      if (_replayPlaying) {
        _replayTimer = Timer.periodic(
          Duration(milliseconds: (700 ~/ _replaySpeed).clamp(80, 2000)),
          (_) => _replayStep(),
        );
      }
    });
  }

  void _replayCycleSpeed() {
    setState(() {
      _replaySpeed = _replaySpeed == 1 ? 2 : (_replaySpeed == 2 ? 4 : 1);
      if (_replayPlaying) {
        _replayPlaying = false;
        _replayTimer?.cancel();
        _replayPlayPause();
      }
    });
  }

  void _replayOrder(bool buy) {
    final r = _replay;
    if (r == null) return;
    setState(() {
      final err = r.openMarket(buy);
      if (err != null) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(err)));
      }
    });
  }

  void _exitReplay() {
    _replayTimer?.cancel();
    setState(() {
      _replay = null;
      _replayCandles = null;
      _pickingReplayStart = false;
      _replayPlaying = false;
    });
    chartKey.currentState?.reload();
  }

  Future<void> explainChart() async {
    Map<String, dynamic> data;
    try {
      final chart = chartKey.currentState;
      if (chart == null) throw StateError('Chart not ready.');
      data = ChartExplanation.snapshot(
        candles: List.of(chart.candles),
        interval: chart.interval.code,
        loadedAt: chart.loadedAt,
        quoteAt: app.priceAt ?? 0,
        bid: app.bid,
        ask: app.ask,
        positions: app.positions,
        accountAt: app.accountAt,
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
      return;
    }
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Explain with Groq?'),
        content: const Text(
          'Sends this displayed candle snapshot, quote timestamps and open position size/entry/TP/SL to Groq using your saved key. No PIN or account balance is sent. Read-only: this cannot open or change a trade. Saved data may be stale.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Explain'),
          ),
        ],
      ),
    );
    if (yes != true || !mounted) return;
    setState(() => explaining = true);
    String result;
    try {
      result = await ChartExplanation.explain(data);
    } catch (e) {
      result = '$e';
    }
    if (!mounted) return;
    setState(() => explaining = false);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Chart / position explanation'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Snapshot: ${data['snapshot_at']}\nLast candle: ${data['last_candle_time']}\nQuote age: ${data['quote_age_seconds'] ?? "unknown"} seconds${data['quote_stale'] == true ? " (stale)" : ""}',
                style: const TextStyle(color: cDim, fontSize: 12),
              ),
              const SizedBox(height: 12),
              SelectableText(result),
              const SizedBox(height: 12),
              const Text(
                'Read-only. No trade changed.',
                style: TextStyle(color: cDim, fontSize: 12),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  String dir = 'buy';
  Future<void> selectSide(String side) async {
    setState(() => dir = side);
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF28364F),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
      ),
      builder: (_) => PaperOrderSheet(app: app, side: side),
    );
  }

  final qtyCtrl = TextEditingController(text: '0.01'); // lots
  final tpCtrl = TextEditingController();
  final slCtrl = TextEditingController();
  final alertCtrl = TextEditingController();
  bool alertAbove = true;
  bool opening = false;
  String err = '';

  // Stage (b): real candle service. Null when no API key is configured;
  // the chart panel then says so instead of drawing demo bars.
  TwelveDataCandleService? get _candles => MarketDataConfig.apiKey.isEmpty
      ? null
      : TwelveDataCandleService(apiKey: MarketDataConfig.apiKey);

  AppState get app => widget.app;

  @override
  void initState() {
    super.initState();
    // Keep the stage (d) risk row live as the user types.
    qtyCtrl.addListener(_refresh);
    slCtrl.addListener(_refresh);
  }

  void _refresh() => setState(() {});

  @override
  void dispose() {
    _replayTimer?.cancel();
    qtyCtrl.dispose();
    slCtrl.dispose();
    tpCtrl.dispose();
    super.dispose();
  }

  double? parseNum(String s) {
    if (s.trim().isEmpty) return null;
    return double.tryParse(s.trim());
  }

  @override
  Widget build(BuildContext context) {
    final fresh = app.priceFresh;
    return ColoredBox(
      color: const Color(0xFF10182A),
      child: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(14),
              children: [
                Container(
                  padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
                  child: Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          color: Color(0xFFF5C242),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.stacked_bar_chart,
                          color: Color(0xFF10182A),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'GOLD',
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              'XAU/USD · Paper trading',
                              style: TextStyle(color: cDim, fontSize: 12),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        app.priceOk ? '\$${fmt(app.chartBasis)}' : '--',
                        style: const TextStyle(
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                CandleChartPanel(
                  key: chartKey,
                  onAlertPrice: confirmChartAlert,
                  rangeMode: true,
                  chromeless: true,
                  loader:

                      (_candles == null && widget.candleLoaderOverride == null)
                          ? null
                          : (iv) async {
                              // Replay slicing wraps every source, including
                              // test overrides, so the replay path is always
                              // exercised the way the phone runs it.
                              final replay = _replay;
                              if (replay != null) {
                                return _replayCandles!.sublist(0, replay.index);
                              }
                              if (widget.candleLoaderOverride != null) {
                                return widget.candleLoaderOverride!(iv);
                              }
                              final spec = tradeRangeSpec(iv);
                              final data = await _candles!.fetchCandles(
                                Instrument.xauUsd,
                                interval: spec.$1,
                                limit: spec.$2,
                              );
                              return trimTradeRange(data, iv);
                            },
