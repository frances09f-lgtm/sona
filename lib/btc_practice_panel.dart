import 'dart:async';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'btc_feed.dart';
import 'btc_paper.dart';
import 'chart/candle_chart.dart';
import 'chart/chart_tools.dart';
import 'market_data/models.dart';
import 'signal_zones.dart';

const _kCard = Color(0xFF171A21);
const _kBorder = Color(0xFF232834);
const _kDim = Color(0xFF8A93A5);
const _kGreen = Color(0xFF2ECC71);
const _kRed = Color(0xFFFF5A5F);
const _kOrange = Color(0xFFF7931A); // bitcoin brand orange

/// USDT amounts with thousands separators, 2 decimals (66,950.83).
String btcFmt(num? n) {
  if (n == null || !n.isFinite) return '--';
  final parts = n.abs().toStringAsFixed(2).split('.');
  final buf = StringBuffer();
  for (var i = 0; i < parts[0].length; i++) {
    if (i > 0 && (parts[0].length - i) % 3 == 0) buf.write(',');
    buf.write(parts[0][i]);
  }
  return '${n < 0 ? '-' : ''}$buf.${parts[1]}';
}

/// BTC quantity: up to 3 decimals, no trailing zeros (0.001 BTC).
String btcQty(num? n) {
  if (n == null || !n.isFinite) return '--';
  var s = n.toStringAsFixed(3);
  while (s.contains('.') && s.endsWith('0')) {
    s = s.substring(0, s.length - 1);
  }
  if (s.endsWith('.')) s = s.substring(0, s.length - 1);
  return s;
}

/// Live BTC/USDT quote ticker for the practice panel. Polls Binance's
/// key-free book ticker while the panel is visible; the 24h change is
/// refreshed rarely. Gold's quote path is never touched.
class BtcQuoteState extends ChangeNotifier {
  final BinanceBtcFeed feed;
  final DateTime Function() _now;
  BtcQuoteState({BinanceBtcFeed? feed, DateTime Function()? now})
      : feed = feed ?? BinanceBtcFeed(),
        _now = now ?? DateTime.now;

  double? bid, ask, price;
  int? priceAt;
  double? dayChangePct;
  String? error;
  final List<(int, double)> liveTicks = [];

  Timer? _timer;
  int _ticks = 0;
  int _failStreak = 0;
  int _lastFailAt = 0;

  bool get fresh =>
      priceAt != null && _now().millisecondsSinceEpoch - priceAt! < 10000;

  /// Seconds to wait before retrying after consecutive failures
  /// (1, 2, 4, ... capped at 30) so a rate-limited or unreachable
  /// feed is not hammered every second.
  int get backoffSeconds {
    if (_failStreak <= 0) return 0;
    final s = 1 << (_failStreak - 1);
    return s > 30 ? 30 : s;
  }

  void start() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  @visibleForTesting
  Future<void> tick() => _tick();

  Future<void> _tick() async {
    if (_failStreak > 0) {
      final waited = _now().millisecondsSinceEpoch - _lastFailAt;
      if (waited < backoffSeconds * 1000) return;
    }
    try {
      final q = await feed.fetchQuote();
      bid = q.bid;
      ask = q.ask;
      price = (q.bid + q.ask) / 2;
      priceAt = _now().millisecondsSinceEpoch;
      liveTicks.add((priceAt!, q.bid));
      if (liveTicks.length > 300) liveTicks.removeAt(0);
      error = null;
      _failStreak = 0;
      _ticks++;
      if (_ticks % 30 == 1) {
        unawaited(
          feed.fetchDayChangePct().then((v) {
            dayChangePct = v;
            notifyListeners();
          }).catchError((_) {}),
        );
      }
    } catch (e) {
      _failStreak++;
      _lastFailAt = _now().millisecondsSinceEpoch;
      error = e is BtcFeedException ? e.message : 'BTC feed unavailable.';
    }
    notifyListeners();
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }
}

/// The approved BTC weekend-practice surface: live chart, manual paper
/// trades with TP/SL, and a phone-local USDT practice balance (balance
/// row hidden at the user's request; the ledger itself is untouched).
/// Signals: rule-based BUY/SELL boxes without AI qualification (approved
/// Nov 14, user chose this over gold's AI-qualified flow) with offsets
/// scaled to BTC's price - documented on the panel as an unvalidated
/// heuristic. Alerts, AutoTrade and AI advice stay gold-only.

/// BTC signal-box scoring (user-approved Nov 14, rule-based, no AI
/// filtering): the same RELATIVE geometry as gold's approved
/// $3.00/$1.50 at gold's ~3,900 tuning price, expressed as fractions of
/// price. Each box's offsets are computed from the real BTC price at the
/// moment it is drawn and then stay fixed forever (same immutability as
/// gold). Heuristic, NOT validated performance.
const double kBtcSignalTargetPct = 3.0 / 3900.0; // 0.077%
const double kBtcSignalInvalidationPct = 1.5 / 3900.0; // 0.038%
const double kBtcZoneHalfHeightPct = 0.75 / 3900.0;
const double kBtcSignalTouchTolerancePct = 1.0 / 3900.0;
const String kBtcSignalPrefsKey = 'sona_btc_signal_boxes_v1';
class BtcPracticePanel extends StatefulWidget {
  /// Test hooks.
  final BinanceBtcFeed? feedOverride;
  final CandleLoader? candleLoaderOverride;
  const BtcPracticePanel({super.key, this.feedOverride, this.candleLoaderOverride});

  @override
  State<BtcPracticePanel> createState() => BtcPracticePanelState();
}

class BtcPracticePanelState extends State<BtcPracticePanel>
    with WidgetsBindingObserver {
  final btcChartKey = GlobalKey<CandleChartPanelState>();
  late final BinanceBtcFeed feed = widget.feedOverride ?? BinanceBtcFeed();
  late final BtcQuoteState quote = BtcQuoteState(feed: feed);
  final BtcPaperState paper = BtcPaperState();

  /// BTC's own box history under its own key; gold's manager and stored
  /// boxes are never touched.
  final SignalBoxManager signals = SignalBoxManager(
    prefsKey: kBtcSignalPrefsKey,
    targetPct: kBtcSignalTargetPct,
    invalidationPct: kBtcSignalInvalidationPct,
    zoneHalfHeightPct: kBtcZoneHalfHeightPct,
    touchTolerancePct: kBtcSignalTouchTolerancePct,
  );
  SharedPreferences? prefs;
  String? notice;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) async {
      prefs = p;
      await paper.load(p);
      await signals.load(p);
      if (mounted) setState(() {});
    });
    quote.addListener(_onTick);
    quote.start();
    WidgetsBinding.instance.addObserver(this);
  }

  /// The Binance poll runs only while the app is foregrounded: background
  /// polling wastes battery and can trip the API's rate limits.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      quote.start();
    } else {
      quote.stop();
    }
  }

  void _onTick() {
    final p = prefs;
    // TP/SL may only fire on a live feed: never on stale quotes.
    if (p != null &&
        quote.fresh &&
        quote.bid != null &&
        quote.ask != null) {
      final closed = paper.checkTpsl(p, quote.bid!, quote.ask!);
      if (closed.isNotEmpty && mounted) {
        setState(() => notice = 'BTC practice position closed by TP/SL.');
      }
      if (signals.onTick(DateTime.now().millisecondsSinceEpoch,
          (quote.bid! + quote.ask!) / 2)) {
        unawaited(signals.save(p));
      }
    }
    if (mounted) setState(() {});
  }

  /// Test entry into the production candle path (the widget's loader
  /// calls this on every real refresh).
  @visibleForTesting
  Future<void> debugSignalCandles(List<Candle> candles) =>
      _signalCandles(candles);

  /// Candle refresh: score live boxes, then - because BTC boxes are
  /// rule-based with no AI qualification (user-approved Nov 14) - draw
  /// freshly detected setups directly, one per free direction slot.
  Future<void> _signalCandles(List<Candle> candles) async {
    final p = prefs;
    if (p == null || candles.isEmpty) return;
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final mid = (quote.bid != null && quote.ask != null)
        ? (quote.bid! + quote.ask!) / 2
        : quote.price;
    if (mid == null) return;
    var changed = signals.onCandles(candles, mid, nowMs);
    if (signals.needsSetup) {
      final c = signals.candidates(candles, mid, nowMs);
      final buys = c.where((z) => z.isBuy);
      final sells = c.where((z) => !z.isBuy);
      if (buys.isNotEmpty) {
        signals.addBox(buys.first, nowMs, price: mid);
        changed = true;
      }
      if (sells.isNotEmpty) {
        signals.addBox(sells.first, nowMs, price: mid);
        changed = true;
      }
    }
    if (changed) {
      await signals.save(p);
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    quote.removeListener(_onTick);
    quote.dispose();
    super.dispose();
  }

  Widget _rangeChip(ChartInterval r) {
    final st = btcChartKey.currentState;
    final selected = st == null
        ? r.code == 'range:1D'
        : st.usingRange && st.interval.code == r.code;
    return InkWell(
      onTap: () => setState(() {
        btcChartKey.currentState?.applyChartSelection(
          range: true,
          code: r.code,
        );
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
            color: selected ? Colors.black : _kDim,
          ),
        ),
      ),
    );
  }

  Future<void> _openTicket(String side) async {
    final p = prefs;
    if (p == null) return;
    if (quote.bid == null || quote.ask == null || !quote.fresh) {
      setState(() => notice = 'No fresh BTC price - wait for the feed.');
      return;
    }
    final qtyCtrl = TextEditingController(text: '0.001');
    final tpCtrl = TextEditingController();
    final slCtrl = TextEditingController();
    String? err;
    final opened = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) {
          final qty = double.tryParse(qtyCtrl.text.trim());
          final px = side == 'buy' ? quote.ask! : quote.bid!;
          final margin = (qty != null && qty > 0)
              ? px * qty / BtcPaperState.leverage
              : null;
          return AlertDialog(
            backgroundColor: _kCard,
            title: Text('${side == 'buy' ? 'Buy' : 'Sell'} BTC/USDT (practice)'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: qtyCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Size (BTC, min 0.001)',
                  ),
                  onChanged: (_) => update(() {}),
                ),
                TextField(
                  controller: tpCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Take profit (optional, USDT price)',
                  ),
                ),
                TextField(
                  controller: slCtrl,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: const InputDecoration(
                    labelText: 'Stop loss (optional, USDT price)',
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  margin == null
                      ? 'Margin estimate needs a valid size.'
                      : 'Estimated margin: ${btcFmt(margin)} USDT at simulated 1:500 leverage. Practice funds only - not real money, not a real trade, and not broker terms.',
                  style: const TextStyle(color: _kDim, fontSize: 12),
                ),
                if (err != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      err!,
                      style: const TextStyle(color: _kRed, fontSize: 12),
                    ),
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () {
                  final q = double.tryParse(qtyCtrl.text.trim());
                  final tp = double.tryParse(tpCtrl.text.trim());
                  final sl = double.tryParse(slCtrl.text.trim());
                  if (q == null) {
                    update(() => err = 'Enter a valid BTC size.');
                    return;
                  }
                  final e = paper.open(
                    p,
                    side,
                    q,
                    tp,
                    sl,
                    quote.bid!,
                    quote.ask!,
                  );
                  if (e != null) {
                    update(() => err = e);
                    return;
                  }
                  Navigator.pop(ctx, true);
                },
                child: Text(side == 'buy' ? 'Buy' : 'Sell'),
              ),
            ],
          );
        },
      ),
    );
    if (opened == true && mounted) {
      setState(
        () => notice =
            '${side == 'buy' ? 'Bought' : 'Sold'} BTC practice position opened.',
      );
    }
  }

  void _closePosition(Map<String, dynamic> pos) {
    final p = prefs;
    if (p == null || quote.bid == null || quote.ask == null) return;
    paper.close(p, pos['id'] as String, quote.bid!, quote.ask!);
    setState(() => notice = 'BTC practice position closed.');
  }

  Widget _note(String text) => Container(
    margin: const EdgeInsets.only(top: 10),
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    decoration: BoxDecoration(
      color: _kCard,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: _kBorder),
    ),
    child: Row(
      children: [
        const Icon(Icons.info_outline, size: 14, color: _kDim),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: const TextStyle(color: _kDim, fontSize: 11)),
        ),
      ],
    ),
  );

  Widget _sideButton(String label, double? px, Color color) {
    return Expanded(
      child: InkWell(
        onTap: () => _openTicket(label.toLowerCase()),
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: color,
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            height: 52,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  btcFmt(px),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bid = quote.bid, ask = quote.ask;
    final chg = quote.dayChangePct;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: const BoxDecoration(
                  color: _kOrange,
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.currency_bitcoin, color: Colors.white),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'BTC',
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Text(
                      'BTC/USDT · Paper trading',
                      style: TextStyle(color: _kDim, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    quote.price != null ? btcFmt(quote.price) : '--',
                    style: const TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  if (chg != null)
                    Text(
                      '${chg >= 0 ? '+' : ''}${chg.toStringAsFixed(2)}% 24h',
                      style: TextStyle(
                        fontSize: 12,
                        color: chg >= 0 ? _kGreen : _kRed,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
        if (quote.error != null && !quote.fresh)
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: _kCard,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _kRed),
            ),
            child: Text(
              quote.error!,
              style: const TextStyle(color: _kRed, fontSize: 12),
            ),
          ),
        SizedBox(
          height: 320,
          child: CandleChartPanel(
            key: btcChartKey,
            rangeMode: true,
            chromeless: true,
            personalOverlays: false,
            loader: widget.candleLoaderOverride ??
                (iv) async {
                  final spec = tradeRangeSpec(iv);
                  final data = await feed.fetchCandles(
                    interval: spec.$1,
                    limit: spec.$2,
                  );
                  final trimmed = trimTradeRange(data, iv);
                  unawaited(_signalCandles(trimmed));
                  return trimmed;
                },
            signalZones: [
              for (final b in signals.displayBoxes)
                SignalZone(isBuy: b.isBuy, low: b.low, high: b.high),
            ],
            signalStats: signals
                    .hasAnythingToday(DateTime.now().millisecondsSinceEpoch)
                ? signals
                    .todayStats(DateTime.now().millisecondsSinceEpoch)
                : null,
            marketUpdates: quote,
            marketSnapshot: () => ChartMarketSnapshot(
              price: quote.price,
              fresh: quote.fresh,
              bid: quote.bid,
              ask: quote.ask,
              liveTicks: quote.liveTicks,
              positions: [
                for (final pos in paper.openPositions)
                  ChartPosition(
                    buy: pos['direction'] == 'buy',
                    entry: (pos['entry'] as num).toDouble(),
                    quantity: (pos['qty'] as num).toDouble(),
                    stop: (pos['sl'] as num?)?.toDouble(),
                    target: (pos['tp'] as num?)?.toDouble(),
                    pnl: quote.fresh && bid != null && ask != null
                        ? ((pos['direction'] == 'buy'
                                    ? bid - (pos['entry'] as num).toDouble()
                                    : (pos['entry'] as num).toDouble() - ask) *
                                (pos['qty'] as num).toDouble())
                            .toDouble()
                        : null,
                  ),
              ],
            ),
            livePrice: quote.price,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [for (final r in tradeRanges) _rangeChip(r)],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _sideButton('BUY', ask, _kGreen),
            const SizedBox(width: 12),
            _sideButton('SELL', bid, _kRed),
          ],
        ),
        if (notice != null)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              notice!,
              style: const TextStyle(color: _kDim, fontSize: 12),
            ),
          ),
        if (paper.openPositions.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Open BTC practice positions',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          for (final pos in paper.openPositions)
            Card(
              color: _kCard,
              child: ListTile(
                title: Text(
                  '${(pos['direction'] as String).toUpperCase()} ${btcQty(pos['qty'] as num)} BTC @ ${btcFmt(pos['entry'] as num)}',
                ),
                subtitle: Text(
                  '${pos['tp'] != null ? "TP ${btcFmt(pos['tp'] as num)}" : "No TP"} · ${pos['sl'] != null ? "SL ${btcFmt(pos['sl'] as num)}" : "No SL"}',
                  style: const TextStyle(color: _kDim, fontSize: 12),
                ),
                trailing: TextButton(
                  onPressed: () => _closePosition(pos),
                  child: const Text('Close'),
                ),
              ),
            ),
        ],
        if (paper.history.isNotEmpty) ...[
          const SizedBox(height: 12),
          const Text(
            'Recent BTC practice history',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
          ),
          for (final pos in paper.history.take(5))
            Card(
              color: _kCard,
              child: ListTile(
                dense: true,
                title: Text(
                  '${(pos['direction'] as String).toUpperCase()} ${btcQty(pos['qty'] as num)} BTC @ ${btcFmt(pos['entry'] as num)} → ${btcFmt(pos['exit'] as num)}',
                ),
                subtitle: Text(
                  '${pos['closeReason']}',
                  style: const TextStyle(color: _kDim, fontSize: 11),
                ),
                trailing: Text(
                  '${(pos['pnl'] as num) >= 0 ? '+' : ''}${btcFmt(pos['pnl'] as num)} USDT',
                  style: TextStyle(
                    color: (pos['pnl'] as num) >= 0 ? _kGreen : _kRed,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
        ],
        _note('Signals: rule-based BUY/SELL boxes, no AI check. '
            'Target/stop distance: 0.077%/0.038% of BTC price '
            '(~52/26 USDT at 67,000) - heuristic, not validated. '
            'Alerts, AutoTrade and AI advice stay on Gold'),
        _note(
            'Practice TP/SL triggers only while Sona is open with a live BTC feed.'),
      ],
    );
  }

}
