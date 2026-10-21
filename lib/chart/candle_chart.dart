import 'dart:async';
import 'dart:io' show Platform;
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../analysis.dart';
import '../market_data/models.dart';
import 'indicators.dart';
import '../strategy.dart' as strat;
import 'chart_tools.dart';
import 'session_levels.dart';

/// Chart selection persisted from Sona Settings (user request: interval
/// and range pickers live in Settings, not on the chart card).
const kChartModePref = 'sona_chart_mode'; // 'candles' or 'range'
const kChartIntervalPref = 'sona_chart_interval'; // e.g. '15min'
const kChartRangePref = 'sona_chart_range'; // e.g. 'range:1D'
const kChartSelectionRevPref = 'sona_chart_selection_rev';
/// Red ask line on the chart (user request: hidden unless enabled in
/// Settings; the yellow bid/last-price line always shows).
const kChartShowAskPref = 'sona_chart_show_ask';

/// Real candle chart (stage b). Renders ONLY candles that came from a
/// historical candle service - never synthetic or placeholder bars.

typedef CandleLoader = Future<List<Candle>> Function(String interval);

/// A user-drawn horizontal level (spec 9: named, stored locally, editable).
/// Default name is neutral - never claim a level IS support or resistance.
class DrawnLine {
  final double price;
  final String name;
  const DrawnLine(this.price, this.name);
}

/// A user-drawn trend line (spec 9), anchored by candle TIME + price so it
/// stays attached to the same market points as new candles arrive.
class TrendLine {
  final DateTime t1;
  final double p1;
  final DateTime t2;
  final double p2;
  const TrendLine(this.t1, this.p1, this.t2, this.p2);
}

/// A parallel channel: main line (t1,p1)-(t2,p2) plus a parallel line
/// offset by [dp] price units. Anchored by candle time like trend lines.
class Channel {
  final DateTime t1;
  final double p1;
  final DateTime t2;
  final double p2;
  final double dp;
  const Channel(this.t1, this.p1, this.t2, this.p2, this.dp);
}

class ChartInterval {
  final String code; // provider interval code
  final String label;
  final Duration refresh;
  const ChartInterval(this.code, this.label, this.refresh);
}

// MT5/XM timeframe set (user request: behave like XM360).
/// MetaTrader Heikin Ashi transform: Close=(O+H+L+C)/4,
/// Open=(prevHAOpen+prevHAClose)/2, High=max(H,HAO,HAC), Low=min(L,HAO,HAC).
List<Candle> _heikinAshi(List<Candle> cs) {
  if (cs.isEmpty) return cs;
  final out = <Candle>[];
  var haOpen = (cs.first.open + cs.first.close) / 2;
  for (final c in cs) {
    final haClose = (c.open + c.high + c.low + c.close) / 4;
    out.add(
      Candle(
        time: c.time,
        open: haOpen,
        high: math.max(c.high, math.max(haOpen, haClose)),
        low: math.min(c.low, math.min(haOpen, haClose)),
        close: haClose,
        volume: c.volume,
      ),
    );
    haOpen = (haOpen + haClose) / 2;
  }
  return out;
}

const intervals = [
  ChartInterval('1min', '1m', Duration(seconds: 15)),
  ChartInterval('5min', '5m', Duration(seconds: 60)),
  ChartInterval('15min', '15m', Duration(minutes: 5)),
  ChartInterval('30min', '30m', Duration(minutes: 5)),
  ChartInterval('1h', '1h', Duration(minutes: 15)),
  ChartInterval('4h', '4h', Duration(minutes: 30)),
  ChartInterval('1day', 'D1', Duration(hours: 1)),
  ChartInterval('1week', 'W1', Duration(hours: 6)),
];

const tradeRanges = [
  ChartInterval('range:1H', '1H', Duration(minutes: 1)),
  ChartInterval('range:1D', '1D', Duration(minutes: 5)),
  ChartInterval('range:1W', '1W', Duration(minutes: 15)),
  ChartInterval('range:1M', '1M', Duration(hours: 1)),
  ChartInterval('range:3M', '3M', Duration(hours: 4)),
  ChartInterval('range:1Y', '1Y', Duration(hours: 12)),
];

class CandleChartPanel extends StatefulWidget {
  /// Loads real candles; may throw. When null, no candle source is
  /// configured and the panel says so instead of drawing fake bars.
  final CandleLoader? loader;
  final ValueChanged<double>? onAlertPrice;

  /// Latest live price for the dashed last-price line (optional).
  final double? livePrice;

  /// Editor overlay occupies the top-left; level labels stay clear of it.

  /// Bar Replay entry point. When set, a Replay chip appears in the
  /// toolbar; [replayOn] highlights it while a replay session runs.
  final VoidCallback? onReplay;
  final bool replayOn;

  /// Fullscreen mode: the chart body fills the available height instead
  /// of the fixed in-page height.
  final bool expand;
  final bool rangeMode;

  /// Trade-page mode (broker-reference layout): no card, no header, no
  /// toolbar, no OHLC/positions text - the bare chart. Controls live below
  /// the chart in the page (range chips, style, fullscreen).
  final bool chromeless;
  final Map<String, dynamic>? initialLayout;
  final Listenable? marketUpdates;
  final ChartMarketSnapshot Function()? marketSnapshot;

  const CandleChartPanel({
    super.key,
    this.loader,
    this.onAlertPrice,
    this.onReplay,
    this.replayOn = false,
    this.livePrice,
    this.expand = false,
    this.rangeMode = false,
    this.chromeless = false,
    this.initialLayout,
    this.marketUpdates,
    this.marketSnapshot,
  });

  @override
  State<CandleChartPanel> createState() => CandleChartPanelState();
}

class CandleChartPanelState extends State<CandleChartPanel>
    with SingleTickerProviderStateMixin {
  bool usingRange = false;
  ChartStyle chartStyle = ChartStyle.candles;
  int emaPeriod = 50,
      rsiPeriod = 14,
      macdFast = 12,
      macdSlow = 26,
      macdSignalPeriod = 9;
  ChartMarketSnapshot get market =>
      widget.marketSnapshot?.call() ??
      ChartMarketSnapshot(price: widget.livePrice);
  double? get chartPrice =>
      market.fresh && (market.price?.isFinite ?? false) && market.price! > 0
      ? market.price
      : null;
  /// Candles with the live quote folded into the still-forming last bar,
  /// so the last-price line and the last candle agree. Provider history
  /// is never rewritten: only the bar whose window contains now, and
  /// only that bar's close/high/low.
  List<Candle> get _liveCandles {
    final p = chartPrice;
    if (p == null || candles.isEmpty) return candles;
    final bar = _barDuration(interval.code);
    if (bar == null) return candles;
    final last = candles.last;
    final now = DateTime.now();
    if (now.isBefore(last.time)) {
      return candles; // provider data ahead of the clock: leave it alone
    }
    // Recent bars are built from the SAME live tick stream that drives the
    // price line, so the last candle and the line cannot diverge.
    final buf = TickBuffer()..ticks.addAll(market.liveTicks ?? const []);

    if (now.isBefore(last.time.add(bar))) {
      // The provider's last bar is still forming: fold the quote and any
      // tick extremes since the bar was stamped into it.
      final tw = buf.ohlc(last.time, now.add(const Duration(seconds: 1)));
      return [
        ...candles.take(candles.length - 1),
        Candle(
          time: last.time,
          open: last.open,
          high: math.max(last.high, math.max(tw?.$2 ?? p, p)),
          low: math.min(last.low, math.min(tw?.$3 ?? p, p)),
          close: p,
          volume: last.volume,
        ),
      ];
    }
    // The provider's last bar already closed (the free candle feed lags a
    // minute or two): extend with bars aggregated from the live tick
    // stream. Bars built from real ticks are DATA, not fabrication, so the
    // only limit is tick coverage (~12 min). Gap minutes with no ticks
    // (e.g. just after app start, before the buffer fills) are skipped,
    // and the currently forming bar is ALWAYS drawn: from ticks when they
    // exist, otherwise anchored at the last real close for up to 3 bars of
    // lag. Beyond that (candle-feed outage) nothing is fabricated.
    final lagBars =
        now.difference(last.time).inMilliseconds / bar.inMilliseconds;
    final k = now.difference(last.time).inMilliseconds ~/ bar.inMilliseconds;
    final out = [...candles];
    var prevClose = last.close;
    for (var j = 1; j <= k; j++) {
      final start = last.time.add(bar * j);
      final isCurrent = j == k;
      final end =
          isCurrent ? now.add(const Duration(seconds: 1)) : start.add(bar);
      final tw = buf.ohlc(start, end);
      if (tw == null) {
        if (isCurrent) {
          if (lagBars > 3) break; // feed outage: fabricate nothing
        } else {
          continue; // no ticks for that minute: leave the time gap
        }
      }
      // Bars connect like a real chart: open is always the previous bar's
      // close; high/low come from real ticks (plus that anchor); close is
      // the window's last tick - the live quote for the forming bar.
      final o = prevClose;
      final c = isCurrent ? p : tw!.$4;
      out.add(
        Candle(
          time: start,
          open: o,
          high: math.max(o, math.max(tw?.$2 ?? c, c)),
          low: math.min(o, math.min(tw?.$3 ?? c, c)),
          close: c,
          volume: 0,
        ),
      );
      prevClose = c;
    }
    return out;
  }

  DateTime _lastChartTap = DateTime.fromMillisecondsSinceEpoch(0);
  // Price-axis drag (TradingView-style vertical price scale): 1.0 = auto.
  double _priceScale = 1.0;
  bool _axisDrag = false;
  double _axisStartY = 0, _axisStartScale = 1.0;

  (double, double) _applyPriceScale(double hi, double lo) {
    if (_priceScale == 1.0) return (hi, lo);
    final mid = (hi + lo) / 2, half = (hi - lo) / 2 * _priceScale;
    return (mid + half, mid - half);
  }

  @visibleForTesting
  double get debugPriceScale => _priceScale;

  @visibleForTesting
  double debugSnapForTest(double price, int candleIdx) {
    var (hi, lo) = _visiblePriceRange();
    return _snapPrice(price, candleIdx, hi, lo);
  }

  @visibleForTesting
  void debugSetView({int? visibleCount, double? scroll}) {
    setState(() {
      visibleOverride = visibleCount;
      if (scroll != null) scrollCandles = scroll;
    });
  }

  static Duration? _barDuration(String code) {
    final c = code.startsWith('range:') ? tradeRangeSpec(code).$1 : code;
    return switch (c) {
      '1min' => const Duration(minutes: 1),
      '5min' => const Duration(minutes: 5),
      '15min' => const Duration(minutes: 15),
      '30min' => const Duration(minutes: 30),
      '1h' => const Duration(hours: 1),
      '4h' => const Duration(hours: 4),
      '1day' => const Duration(days: 1),
      '1week' => const Duration(days: 7),
      _ => null,
    };
  }

  double get _rsiHeight => rsiOn && candles.length > rsiPeriod ? 64 : 0;
  double get _macdHeight => macdOn && candles.length >= macdSlow ? 64 : 0;
  int _loadGeneration = 0;
  ChartInterval interval = intervals[2]; // M15 default
  List<Candle> candles = [];
  int loadedAt = 0;
  bool loading = false;
  String? error;
  int? selected; // crosshair candle index

  // MT5-style crosshair mode: toggled from the toolbar; while on, a
  // one-finger drag moves the crosshair freely (price on the right axis,
  // date/time on the bottom axis, OHLC caption at the touched bar).
  bool crosshairMode = false;
  bool _longPressCrosshair = false;
  Offset? crosshairPos;
  Timer? _timer;
  Timer? _countdownTimer;
  bool biasExpanded = false;
  // XM/MT5 default: a fresh chart has NO indicators; the user adds them
  // from the Indicators menu. Saved layouts from before v1.0.93 carried the
  // old on-by-default SMA/EMA - the one-time layoutV reset clears those.
  bool smaOn = false;
  bool emaOn = false;
  bool sma200On = false;
  bool rsiOn = false;
  bool macdOn = false;
  final Set<int> extraEmas = {};
  bool bollingerOn = false;
  bool showAskLine = false;
  bool sessionShadingOn = false;
  bool prevLevelsOn = false;
  List<strat.PriceActionStrategy> _strategies = [];
  List<StrategyLevelSegment> strategySegments = [];
  bool alertMode = false;
  bool drawMode = false;
  bool trendMode = false;
  bool rectMode = false;
  bool channelMode = false;
  bool rulerMode = false;
  final List<DrawnLine> hLines = []; // user-drawn named price levels
  final List<TrendLine> trendLines = []; // user-drawn trend lines
  final List<TrendLine> rects = []; // user-drawn rectangle zones
  final List<Channel> channels = []; // user-drawn parallel channels
  final List<TrendLine> rulers = []; // user-drawn measure tools
  TrendLine? pendingRect;
  Channel? pendingChannel;
  int channelStage = 0; // 1 = first anchor placed, 2 = main line placed
  TrendLine? pendingRuler;
  bool magnetOn = true; // snap anchors to candle high/low
  TrendLine? pendingTrend; // first anchor set, waiting for the second tap
  bool fibMode = false;
  int? _dragLineIdx; // hLine being drag-moved in Draw mode
  final List<TrendLine> fibs = []; // fibonacci retracements (2 anchors each)
  TrendLine? pendingFib;

  /// Undo/redo over drawing operations (user request, broker reference):
  /// snapshots of every drawing list, taken before each mutation.
  final List<Map<String, List<Map<String, Object>>>> _undoStack = [];
  final List<Map<String, List<Map<String, Object>>>> _redoStack = [];

  static Map<String, Object> _tl(TrendLine t) => {
        't1': t.t1.millisecondsSinceEpoch,
        'p1': t.p1,
        't2': t.t2.millisecondsSinceEpoch,
        'p2': t.p2,
      };

  Map<String, List<Map<String, Object>>> _drawingsSnapshot() => {
        'h': [for (final l in hLines) {'p': l.price, 'n': l.name}],
        't': [for (final t in trendLines) _tl(t)],
        'r': [for (final t in rects) _tl(t)],
        'c': [
          for (final c in channels)
            {
              't1': c.t1.millisecondsSinceEpoch,
              'p1': c.p1,
              't2': c.t2.millisecondsSinceEpoch,
              'p2': c.p2,
              'dp': c.dp,
            }
        ],
        'f': [for (final t in fibs) _tl(t)],
        'm': [for (final t in rulers) _tl(t)],
      };

  void _restoreDrawings(Map<String, List<Map<String, Object>>> snap) {
    TrendLine tl(Map<String, Object> e) => TrendLine(
          DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
          (e['p1'] as num).toDouble(),
          DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
          (e['p2'] as num).toDouble(),
        );
    hLines
      ..clear()
      ..addAll((snap['h'] ?? const []).map(
          (e) => DrawnLine((e['p'] as num).toDouble(), e['n']?.toString() ?? 'Level')));
    trendLines
      ..clear()
      ..addAll((snap['t'] ?? const []).map(tl));
    rects
      ..clear()
      ..addAll((snap['r'] ?? const []).map(tl));
    channels
      ..clear()
      ..addAll((snap['c'] ?? const []).map((e) => Channel(
            DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
            (e['p1'] as num).toDouble(),
            DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
            (e['p2'] as num).toDouble(),
            (e['dp'] as num).toDouble(),
          )));
    fibs
      ..clear()
      ..addAll((snap['f'] ?? const []).map(tl));
    rulers
      ..clear()
      ..addAll((snap['m'] ?? const []).map(tl));
    pendingTrend = null;
    pendingRect = null;
    pendingChannel = null;
    channelStage = 0;
    pendingRuler = null;
    pendingFib = null;
    _dragLineIdx = null;
  }

  void _pushUndo() {
    _undoStack.add(_drawingsSnapshot());
    if (_undoStack.length > 50) _undoStack.removeAt(0);
    _redoStack.clear();
  }

  bool get canUndo => _undoStack.isNotEmpty;
  bool get canRedo => _redoStack.isNotEmpty;

  void undo() {
    if (_undoStack.isEmpty) return;
    _redoStack.add(_drawingsSnapshot());
    setState(() => _restoreDrawings(_undoStack.removeLast()));
  }

  void redo() {
    if (_redoStack.isEmpty) return;
    _undoStack.add(_drawingsSnapshot());
    setState(() => _restoreDrawings(_redoStack.removeLast()));
  }

  // Chart navigation (user request): pinch to zoom, horizontal drag to
  // scroll back through candles. scrollCandles = bars scrolled back from
  // the newest; visibleOverride = zoomed bar count (null = fit all).
  double scrollCandles = 0;
  int? visibleOverride;
  double _scaleStartVC = 0;
  double _panStartScroll = 0;
  double _panStartX = 0;
  double _scaleStartIndexFloat = 0; // candle index under the pinch focal point
  int _gesturePointers = 0; // pointers at gesture start (ScaleEnd reports 0)
  Timer? _kineticTimer;
  double _kineticVelBars = 0; // bars per second, + = scroll back (right drag)
  static const double rightPad = 52.0;

  /// The series actually drawn: provider candles with the live quote
  /// folded in (and a synthesized forming bar appended when the feed lags).
  /// Every piece of visible-window math must use THIS length - using the
  /// provider length clips the forming bar off the right edge.
  List<Candle> get _drawn => _liveCandles;

  /// Deterministic clock under flutter_test so goldens never flake.
  static DateTime _chartNow() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return DateTime(2026, 10, 7, 13, 59, 42);
    }
    return DateTime.now();
  }

  int get _vc {
    final n = _drawn.length;
    if (n == 0) return 1;
    final v = visibleOverride ?? math.min(n, 60);
    if (v > n) return n;
    return v < 8 ? (n < 8 ? n : 8) : v;
  }

  int get _fv {
    final n = _drawn.length;
    if (n == 0) return 0;
    // Right-edge margin (TradingView-style): up to 5 bars of empty space
    // past the newest candle when the user scrolls forward.
    final maxFv = n - _vc + 5;
    var fv = n - _vc - scrollCandles.round();
    if (fv < 0) fv = 0;
    if (fv > maxFv) fv = maxFv < 0 ? 0 : maxFv;
    return fv;
  }

  /// Price range of the VISIBLE window (+ live price) - shared by the
  /// painter and every gesture mapper so they always agree.
  (double, double) _visiblePriceRange() {
    final eff = _drawn;
    final n = eff.length;
    double hi = -double.infinity, lo = double.infinity;
    if (n > 0) {
      final fv = _fv, vc = _vc;
      for (int i = fv; i < (fv + vc < n ? fv + vc : n); i++) {
        final c = eff[i];
        hi = hi > c.high ? hi : c.high;
        lo = lo < c.low ? lo : c.low;
      }
    }
    if (chartPrice != null) {
      hi = hi > chartPrice! ? hi : chartPrice!;
      lo = lo < chartPrice! ? lo : chartPrice!;
    }
    if (prevLevelsOn) {
      for (final hl in [previousDayHL(candles), previousWeekHL(candles)]) {
        if (hl == null) continue;
        hi = hi > hl.$1 ? hi : hl.$1;
        lo = lo < hl.$2 ? lo : hl.$2;
      }
    }
    return (hi, lo);
  }

  @override
  void initState() {
    super.initState();
    usingRange =
        widget.initialLayout?['rangeMode'] as bool? ?? widget.rangeMode;
    if (usingRange) interval = tradeRanges[1];
    if (widget.initialLayout != null) {
      _restoreTools(widget.initialLayout!);
    } else {
      _loadSavedSelection().whenComplete(_migrateV122Overlays);
    }
    widget.marketUpdates?.addListener(_syncSavedSelection);
    _loadLines();
    _loadRects();
    _loadChannels();
    _loadRulers();
    _loadStrategies();
    _load();
    _armTimer();
  }

  int _appliedSelectionRev = 0;

  /// Custom price-action strategies (user request): enabled ones mark
  /// their levels on the chart. Stored on-device; the Strategies screen
  /// bumps kChartSelectionRevPref so _syncSavedSelection refreshes this.
  Future<void> _loadStrategies() async {
    List<strat.PriceActionStrategy> all;
    try {
      all = await strat.StrategyStore.load();
    } catch (_) {
      return; // no prefs plugin (tests) or unreadable store: no levels
    }
    if (!mounted) return;
    setState(() {
      _strategies = all.where((x) => x.showOnChart).toList();
      _recomputeStrategySegments();
    });
  }

  void _recomputeStrategySegments() {
    final out = <StrategyLevelSegment>[];
    for (final s in _strategies) {
      final segs = strat.strategySegments(candles, s);
      // User (v1.0.97): only TWO lines - the high and low of the most
      // recent closed 1H candle, not every hour. The backtest engine
      // still evaluates every hour; this filter is chart-only.
      DateTime? latest;
      for (final seg in segs) {
        if (latest == null || seg.start.isAfter(latest)) latest = seg.start;
      }
      for (final seg in segs) {
        if (latest != null && seg.start != latest) continue;
        var startIdx = candles.indexWhere((c) => !c.time.isBefore(seg.start));
        if (startIdx < 0) startIdx = candles.length - 1;
        var endIdx = candles.lastIndexWhere((c) => !c.time.isAfter(seg.end));
        if (endIdx < 0) endIdx = candles.length - 1;
        out.add(StrategyLevelSegment(
          price: seg.price,
          isHigh: seg.isHigh,
          startIdx: startIdx,
          endIdx: endIdx < startIdx ? startIdx : endIdx,
          broken: seg.broken,
        ));
      }
    }
    strategySegments = out;
  }

  /// Reads the Settings-chosen chart selection and applies it once at
  /// start (fullscreen handoffs and presets pass initialLayout instead).
  Future<void> _loadSavedSelection() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      _appliedSelectionRev = prefs.getInt(kChartSelectionRevPref) ?? 0;
      final showAsk = prefs.getBool(kChartShowAskPref) ?? false;
      if (!mounted) return;
      if (showAsk != showAskLine) setState(() => showAskLine = showAsk);
      final mode = prefs.getString(kChartModePref);
      if (mode == null) return;
      final code = mode == 'range'
          ? prefs.getString(kChartRangePref)
          : prefs.getString(kChartIntervalPref);
      if (code == null) return;
      applyChartSelection(range: mode == 'range', code: code);
    } catch (_) {}
  }

  /// Settings bumps kChartSelectionRevPref and notifies app listeners;
  /// pick up the new selection without touching presets or drawings.
  void _syncSavedSelection() {
    if (widget.initialLayout != null) return;
    SharedPreferences.getInstance().then((prefs) {
      final rev = prefs.getInt(kChartSelectionRevPref) ?? 0;
      if (!mounted || rev == _appliedSelectionRev) return;
      _appliedSelectionRev = rev;
      final showAsk = prefs.getBool(kChartShowAskPref) ?? false;
      if (showAsk != showAskLine) setState(() => showAskLine = showAsk);
      _loadStrategies();
      final mode = prefs.getString(kChartModePref);
      final code = mode == 'range'
          ? prefs.getString(kChartRangePref)
          : prefs.getString(kChartIntervalPref);
      if (mode == null || code == null) return;
      applyChartSelection(range: mode == 'range', code: code);
    });
  }

  /// Applies a chart selection chosen in Settings (or tests): switches
  /// the card between candle intervals and history ranges and reloads.
  void applyChartSelection({required bool range, required String code}) {
    final list = range ? tradeRanges : intervals;
    final iv = list.where((e) => e.code == code).firstOrNull;
    if (iv == null) return;
    // New timeframe: back to the default newest-bars view (sane candle
    // width at every range; a zoom saved on another timeframe looked broken).
    visibleOverride = null;
    scrollCandles = 0;
    if (usingRange != range) {
      setState(() {
        usingRange = range;
        interval = iv;
        candles = [];
        selected = null;
        error = null;
      });
      _armTimer();
      _load();
    } else {
      _setInterval(iv);
    }
  }

  /// v1.2.2: session shading + previous day/week levels default OFF (user
  /// request: "why so many lines"). Existing installs get them switched off
  /// once; the Settings toggles can turn them back on and stay on.
  Future<void> _migrateV122Overlays() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool('sona_v122_overlay_reset') == true) return;
      await prefs.setBool('sona_v122_overlay_reset', true);
      if (!mounted) return;
      setState(() {
        sessionShadingOn = false;
        prevLevelsOn = false;
      });
    } catch (_) {}
  }

  static const presetKey = 'sona_chart_presets';
  Map<String, dynamic> layoutSnapshot() => {
    'layoutV': 2,
    'chartStyle': chartStyle.name,
    'emaPeriod': emaPeriod,
    'rsiPeriod': rsiPeriod,
    'macdFast': macdFast,
    'macdSlow': macdSlow,
    'macdSignalPeriod': macdSignalPeriod,
    'rangeMode': usingRange,
    'interval': interval.code,
    'sma20': smaOn,
    'ema50': emaOn,
    'sma200': sma200On,
    'rsi': rsiOn,
    'macd': macdOn,
    'bollinger': bollingerOn,
    'sessionShading': sessionShadingOn,
    'prevLevels': prevLevelsOn,
    'magnet': magnetOn,
    'extraEmas': extraEmas.toList(),
    'visibleCount': visibleOverride,
    'scrollCandles': scrollCandles,
  };
  void _restoreTools(Map<String, dynamic> data) {
    chartStyle =
        ChartStyle.values
            .where((v) => v.name == data['chartStyle'])
            .firstOrNull ??
        ChartStyle.candles;
    int period(String key, int fallback) =>
        data[key] is int && (data[key] as int) >= 2 && (data[key] as int) <= 200
        ? data[key] as int
        : fallback;
    emaPeriod = period('emaPeriod', 50);
    rsiPeriod = period('rsiPeriod', 14);
    macdFast = period('macdFast', 12);
    macdSlow = period('macdSlow', 26);
    macdSignalPeriod = period('macdSignalPeriod', 9);
    if (macdFast >= macdSlow) {
      macdFast = 12;
      macdSlow = 26;
    }
    // layoutV<2 snapshots saved the old on-by-default SMA20/EMA50. Reset
    // those once so existing installs also come up with a clean chart.
    final v2 = data['layoutV'] == 2;
    smaOn = v2 && data['sma20'] == true;
    emaOn = v2 && data['ema50'] == true;
    sma200On = data['sma200'] == true;
    rsiOn = data['rsi'] == true;
    macdOn = data['macd'] == true;
    bollingerOn = data['bollinger'] == true;
    sessionShadingOn = data['sessionShading'] == true;
    prevLevelsOn = data['prevLevels'] == true;
    magnetOn = data['magnet'] != false;
    extraEmas
      ..clear()
      ..addAll(
        (data['extraEmas'] as List? ?? []).whereType<int>().where(
          (p) => [9, 21, 200].contains(p),
        ),
      );
    final opts = usingRange ? tradeRanges : intervals;
    interval =
        opts.where((iv) => iv.code == data['interval']).firstOrNull ?? interval;
    visibleOverride = (data['visibleCount'] as int?)?.clamp(8, 500);
    final savedScroll = data['scrollCandles'];
    scrollCandles = savedScroll is num && savedScroll.isFinite
        ? savedScroll.toDouble().clamp(-5.0, 100000.0)
        : 0;
  }

  Future<void> configureIndicators() async {
    final values = await showDialog<List<int>>(
      context: context,
      builder: (_) => IndicatorSettingsDialog(
        values: [emaPeriod, rsiPeriod, macdFast, macdSlow, macdSignalPeriod],
      ),
    );
    if (!mounted || values == null) return;
    setState(() {
      emaPeriod = values[0];
      rsiPeriod = values[1];
      macdFast = values[2];
      macdSlow = values[3];
      macdSignalPeriod = values[4];
    });
  }

  Future<Map<String, dynamic>> readPresets() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(presetKey);
    if (raw == null) return {};
    return Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  Future<void> savePreset(String name) async {
    final label = name.trim();
    if (label.isEmpty || label.length > 40)
      throw StateError('Use a name with 1 to 40 characters.');
    final data = await readPresets();
    if (data.keys.any((n) => n.toLowerCase() == label.toLowerCase()))
      throw StateError(
        'That name already exists. Delete it first or use a new name.',
      );
    if (data.length >= 12)
      throw StateError('Delete a preset before adding more (12 maximum).');
    data[label] = layoutSnapshot();
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(presetKey, jsonEncode(data)))
      throw StateError('Could not save preset.');
  }

  Future<void> deletePreset(String name) async {
    final data = await readPresets();
    data.remove(name);
    final prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(presetKey, jsonEncode(data)))
      throw StateError('Could not delete preset.');
  }

  /// Public entry for the fullscreen editor's delete button.
  void clearDrawingsConfirmed() => _confirmClearAll();

  /// Cycles candles -> line -> Heikin Ashi (the below-chart style button in
  /// chromeless mode mirrors the toolbar dropdown).
  void cycleChartStyle() {
    setState(() {
      final values = ChartStyle.values;
      chartStyle = values[(chartStyle.index + 1) % values.length];
    });
  }

  void applyPreset(Map<String, dynamic> data) {
    if (data['rangeMode'] != usingRange)
      throw StateError(
        'This preset uses a different chart range mode. Open the matching chart to load it.',
      );
    final options = usingRange ? tradeRanges : intervals;
    final matches = options.where((iv) => iv.code == data['interval']);
    if (matches.isEmpty) throw StateError('Preset interval unavailable.');
    final iv = matches.first;
    final extras = (data['extraEmas'] as List? ?? [])
        .whereType<int>()
        .where((n) => [9, 21, 200].contains(n))
        .toSet();
    final count = (data['visibleCount'] as num?)?.toInt();
    setState(() {
      final previous = interval;
      _restoreTools(data);
      interval = previous;
      smaOn = data['sma20'] == true;
      emaOn = data['ema50'] == true;
      sma200On = data['sma200'] == true;
      rsiOn = data['rsi'] == true;
      macdOn = data['macd'] == true;
      bollingerOn = data['bollinger'] == true;
      extraEmas
        ..clear()
        ..addAll(extras);
      visibleOverride = count == null ? null : count.clamp(8, 500);
      selected = null;
      alertMode = drawMode = trendMode = fibMode = false;
      pendingTrend = null;
      pendingFib = null;
    });
    _setInterval(iv);
  }

  Future<void> presetDialog() async {
    Map<String, dynamic> data;
    try {
      data = await readPresets();
    } catch (_) {
      if (mounted)
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read saved layouts.')),
        );
      return;
    }
    if (!mounted) return;
    final name = TextEditingController();
    String? issue;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, update) => AlertDialog(
          title: const Text('Chart layouts'),
          content: SizedBox(
            width: 320,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Saved on this phone: indicators, range and zoom. No positions, alerts or drawings changed.',
                  ),
                  for (final entry in data.entries)
                    ListTile(
                      title: Text(entry.key),
                      subtitle: Text(
                        (entry.value as Map)['interval'].toString(),
                      ),
                      onTap: () {
                        try {
                          applyPreset(
                            Map<String, dynamic>.from(entry.value as Map),
                          );
                          Navigator.pop(ctx);
                        } catch (e) {
                          update(() => issue = e.toString());
                        }
                      },
                      trailing: IconButton(
                        tooltip: 'Delete layout',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: () async {
                          try {
                            await deletePreset(entry.key);
                            update(() => data.remove(entry.key));
                          } catch (_) {
                            update(() => issue = 'Could not delete layout.');
                          }
                        },
                      ),
                    ),
                  TextField(
                    controller: name,
                    maxLength: 40,
                    decoration: const InputDecoration(
                      labelText: 'Name current layout',
                    ),
                  ),
                  if (issue != null)
                    Text(
                      issue!,
                      style: const TextStyle(color: Colors.redAccent),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close'),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  await savePreset(name.text);
                  if (ctx.mounted) Navigator.pop(ctx);
                } catch (e) {
                  update(() => issue = e.toString());
                }
              },
              child: const Text('Save current'),
            ),
          ],
        ),
      ),
    );
  }

  /// Spec 9: drawn levels are stored locally (device), never on the server.
  Future<void> _loadLines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('tj_draw_lines');
      final rawT = prefs.getString('tj_draw_trends');
      setState(() {
        if (raw != null) {
          final list = jsonDecode(raw) as List;
          hLines
            ..clear()
            ..addAll(
              list.map(
                (e) => DrawnLine(
                  (e['p'] as num).toDouble(),
                  e['n']?.toString() ?? 'Level',
                ),
              ),
            );
        }
        if (rawT != null) {
          final list = jsonDecode(rawT) as List;
          trendLines
            ..clear()
            ..addAll(
              list.map(
                (e) => TrendLine(
                  DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
                  (e['p1'] as num).toDouble(),
                  DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
                  (e['p2'] as num).toDouble(),
                ),
              ),
            );
        }
        final rawF = prefs.getString('tj_draw_fibs');
        if (rawF != null) {
          final list = jsonDecode(rawF) as List;
          fibs
            ..clear()
            ..addAll(
              list.map(
                (e) => TrendLine(
                  DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
                  (e['p1'] as num).toDouble(),
                  DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
                  (e['p2'] as num).toDouble(),
                ),
              ),
            );
        }
      });
    } catch (_) {}
  }

  Future<void> _loadRects() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('tj_draw_rects');
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      setState(() {
        rects
          ..clear()
          ..addAll(
            list.map(
              (e) => TrendLine(
                DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
                (e['p1'] as num).toDouble(),
                DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
                (e['p2'] as num).toDouble(),
              ),
            ),
          );
      });
    } catch (_) {}
  }

  Future<void> _loadChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('tj_draw_channels');
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      setState(() {
        channels
          ..clear()
          ..addAll(
            list.map(
              (e) => Channel(
                DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
                (e['p1'] as num).toDouble(),
                DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
                (e['p2'] as num).toDouble(),
                (e['dp'] as num).toDouble(),
              ),
            ),
          );
      });
    } catch (_) {}
  }

  Future<void> _loadRulers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('tj_draw_rulers');
      if (raw == null) return;
      final list = jsonDecode(raw) as List;
      setState(() {
        rulers
          ..clear()
          ..addAll(
            list.map(
              (e) => TrendLine(
                DateTime.fromMillisecondsSinceEpoch(e['t1'] as int),
                (e['p1'] as num).toDouble(),
                DateTime.fromMillisecondsSinceEpoch(e['t2'] as int),
                (e['p2'] as num).toDouble(),
              ),
            ),
          );
      });
    } catch (_) {}
  }

  Future<void> _saveFibs() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_fibs',
        jsonEncode(
          fibs
              .map(
                (e) => {
                  't1': e.t1.millisecondsSinceEpoch,
                  'p1': e.p1,
                  't2': e.t2.millisecondsSinceEpoch,
                  'p2': e.p2,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  Future<void> _saveRects() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_rects',
        jsonEncode(
          rects
              .map(
                (e) => {
                  't1': e.t1.millisecondsSinceEpoch,
                  'p1': e.p1,
                  't2': e.t2.millisecondsSinceEpoch,
                  'p2': e.p2,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  Future<void> _saveChannels() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_channels',
        jsonEncode(
          channels
              .map(
                (e) => {
                  't1': e.t1.millisecondsSinceEpoch,
                  'p1': e.p1,
                  't2': e.t2.millisecondsSinceEpoch,
                  'p2': e.p2,
                  'dp': e.dp,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  Future<void> _saveRulers() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_rulers',
        jsonEncode(
          rulers
              .map(
                (e) => {
                  't1': e.t1.millisecondsSinceEpoch,
                  'p1': e.p1,
                  't2': e.t2.millisecondsSinceEpoch,
                  'p2': e.p2,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  Future<void> _saveTrends() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_trends',
        jsonEncode(
          trendLines
              .map(
                (e) => {
                  't1': e.t1.millisecondsSinceEpoch,
                  'p1': e.p1,
                  't2': e.t2.millisecondsSinceEpoch,
                  'p2': e.p2,
                },
              )
              .toList(),
        ),
      );
    } catch (_) {}
  }

  bool get _hasDrawings =>
      hLines.isNotEmpty ||
      trendLines.isNotEmpty ||
      fibs.isNotEmpty ||
      rects.isNotEmpty ||
      channels.isNotEmpty ||
      rulers.isNotEmpty ||
      pendingTrend != null ||
      pendingFib != null ||
      pendingRect != null ||
      pendingChannel != null ||
      pendingRuler != null;

  /// Clear ALL chart drawings at once (user request): every drawn level,
  /// trend line and fib, including a half-placed anchor. Persisted copies
  /// are cleared too so they stay gone after restart.
  Future<void> _clearAllDrawings() async {
    setState(() {
      hLines.clear();
      trendLines.clear();
      fibs.clear();
      rects.clear();
      channels.clear();
      rulers.clear();
      pendingTrend = null;
      pendingFib = null;
      pendingRect = null;
      pendingChannel = null;
      pendingRuler = null;
      channelStage = 0;
      _dragLineIdx = null;
    });
    await _saveLines();
    await _saveTrends();
    await _saveFibs();
    await _saveRects();
    await _saveChannels();
    await _saveRulers();
  }

  Future<void> _confirmClearAll() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151A22),
        title: const Text(
          'Clear all drawings?',
          style: TextStyle(color: Colors.white, fontSize: 15),
        ),
        content: const Text(
          'This removes every drawn level, trend line and fib on the chart.',
          style: TextStyle(color: Color(0xFF8A93A6), fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text(
              'Clear',
              style: TextStyle(color: Color(0xFFF27EA9)),
            ),
          ),
        ],
      ),
    );
    if (ok == true) {
      _pushUndo();
      await _clearAllDrawings();
    }
  }

  Future<void> _saveLines() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'tj_draw_lines',
        jsonEncode(hLines.map((e) => {'p': e.price, 'n': e.name}).toList()),
      );
    } catch (_) {}
  }

  /// Long-press near a drawn line: rename it (Support, Resistance, ...) or
  /// delete it (spec 9: create / edit / delete / rename).
  bool _anyDrawingHit(Offset pos, Size size) {
    if (candles.isEmpty) return false;
    const bottomPad = 16.0;
    final paneH = chartPaneHeight(size.height, _rsiHeight > 0, _macdHeight > 0);
    final rsiH = _rsiHeight > 0 ? paneH : 0.0;
    final macdH = _macdHeight > 0 ? paneH : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH) return false;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final scaled = _applyPriceScale(hi, lo);
    hi = scaled.$1;
    lo = scaled.$2;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final range = hi - lo;
    if (hLines.any((l) => (l.price - price).abs() < range * 0.02)) {
      return true;
    }
    if (_trendHit(pos, Size(size.width, plotH), hi, lo) >= 0) return true;
    if (_fibHit(pos, Size(size.width, plotH), hi, lo) >= 0) return true;
    return false;
  }

  Future<void> _editLineAt(Offset pos, Size size) async {
    if (hLines.isEmpty || candles.isEmpty) return;
    const bottomPad = 16.0;
    final paneH = chartPaneHeight(size.height, _rsiHeight > 0, _macdHeight > 0);
    final rsiH = _rsiHeight > 0 ? paneH : 0.0;
    final macdH = _macdHeight > 0 ? paneH : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final scaled = _applyPriceScale(hi, lo);
    hi = scaled.$1;
    lo = scaled.$2;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final range = hi - lo;
    final idx = hLines.indexWhere(
      (l) => (l.price - price).abs() < range * 0.02,
    );
    if (idx < 0) {
      // no horizontal level near - try trend lines (pixel-space distance)
      final tIdx = _trendHit(pos, Size(size.width, plotH), hi, lo);
      if (tIdx < 0) {
        final fIdx = _fibHit(pos, Size(size.width, plotH), hi, lo);
        if (fIdx < 0) return;
        final delF = await showDialog<bool>(
          context: context,
          builder: (dCtx) => AlertDialog(
            backgroundColor: const Color(0xFF161B24),
            title: const Text(
              'Fibonacci retracement',
              style: TextStyle(fontSize: 16),
            ),
            content: const Text('Delete this fibonacci retracement?'),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dCtx, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dCtx, true),
                child: const Text('Delete'),
              ),
            ],
          ),
        );
        if (delF == true) {
          _pushUndo();
          setState(() => fibs.removeAt(fIdx));
          _saveFibs();
        }
        return;
      }
      final del = await showDialog<bool>(
        context: context,
        builder: (dCtx) => AlertDialog(
          backgroundColor: const Color(0xFF161B24),
          title: const Text('Trend line', style: TextStyle(fontSize: 16)),
          content: const Text('Delete this trend line?'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dCtx, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dCtx, true),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (del == true) {
        _pushUndo();
        setState(() => trendLines.removeAt(tIdx));
        _saveTrends();
      }
      return;
    }
    final line = hLines[idx];
    final ctrl = TextEditingController(text: line.name);
    final act = await showDialog<String>(
      context: context,
      builder: (dCtx) => AlertDialog(
        backgroundColor: const Color(0xFF161B24),
        title: Text(
          'Level at ${line.price.toStringAsFixed(2)}',
          style: const TextStyle(fontSize: 16),
        ),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Name (e.g. Support, Resistance)',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dCtx, 'delete'),
            child: const Text(
              'Delete',
              style: TextStyle(color: Color(0xFFFF6B6B)),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dCtx),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dCtx, 'save'),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    setState(() {
      if (act == 'delete') {
        _pushUndo();
        hLines.removeAt(idx);
      } else if (act == 'save') {
        hLines[idx] = DrawnLine(
          line.price,
          ctrl.text.trim().isEmpty ? 'Level' : ctrl.text.trim(),
        );
      }
    });
    _saveLines();
  }

  void _stopKinetic() {
    _kineticTimer?.cancel();
    _kineticTimer = null;
  }

  void _startKinetic(double velPxPerSec, double plotW) {
    _stopKinetic();
    final step = plotW / _vc;
    if (step <= 0) return;
    // Same sign convention as the pan: finger/drag moving right (vx>0)
    // scrolls back through older candles; left scrolls forward.
    _kineticVelBars = velPxPerSec / step;
    if (_kineticVelBars.abs() < 2) return; // too slow to matter
    // 16ms timer instead of a Ticker: close enough to vsync for a
    // sub-second fling, and deterministic under fake-time widget tests.
    const dt = 0.016;
    _kineticTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      // exponential friction: v halves roughly every 0.6s
      _kineticVelBars *= math.pow(0.5, dt / 0.6);
      final n = _drawn.length;
      final maxScroll = (n - _vc) > 0 ? (n - _vc).toDouble() : 0.0;
      var next = scrollCandles + _kineticVelBars * dt;
      if (next < -5 || next > maxScroll) {
        next = next.clamp(-5.0, maxScroll);
        _kineticVelBars = 0; // hit the wall: stop
      }
      if (_kineticVelBars.abs() < 0.5) {
        _stopKinetic();
      }
      if (mounted) setState(() => scrollCandles = next);
    });
  }

  @override
  void dispose() {
    _stopKinetic();
    widget.marketUpdates?.removeListener(_syncSavedSelection);
    _timer?.cancel();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _armTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(interval.refresh, (_) => _load(quiet: true));
    // 1s repaint driver for the candle-close countdown under the price pill.
    // Skipped under flutter_test so fake-time tests stay deterministic.
    if (_countdownTimer == null &&
        !Platform.environment.containsKey('FLUTTER_TEST')) {
      _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  /// Re-invoke the loader without a loading spinner (bar-replay steps,
  /// external data refresh). Same path as the periodic refresh.
  Future<void> reload() => _load(quiet: true);

  Future<void> _load({bool quiet = false}) async {
    final loader = widget.loader;
    if (loader == null) return;
    if (!quiet) {
      setState(() {
        loading = true;
        error = null;
      });
    }
    final generation = ++_loadGeneration;
    try {
      final requested = interval.code;
      final raw = await loader(requested);
      if (raw.any((c) => !validChartCandle(c)))
        throw StateError(
          'Candle feed returned invalid prices. Last valid history retained.',
        );
      final sorted = {
        ...{for (final c in raw) c.time.toUtc().millisecondsSinceEpoch: c},
      }.values.toList()..sort((a, b) => a.time.compareTo(b.time));
      final data = usingRange ? trimTradeRange(sorted, requested) : sorted;
      if (!mounted ||
          generation != _loadGeneration ||
          interval.code != requested)
        return;
      setState(() {
        candles = data;
        loadedAt = DateTime.now().millisecondsSinceEpoch;
        loading = false;
        error = null;
        _recomputeStrategySegments();
      });
    } catch (e) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        loading = false;
        // Keep the last real candles on screen; flag the error.
        error = e.toString().replaceAll('Exception: ', '');
      });
    }
  }

  void _setInterval(ChartInterval iv) {
    if (iv.code == interval.code) return;
    setState(() {
      interval = iv;
      candles = [];
      selected = null;
      error = null;
    });
    _armTimer();
    _load();
  }

  @override
  Widget build(BuildContext context) {
    const bg = Color(0xFF0E1116);
    const dim = Color(0xFF8A93A6);
    if (widget.chromeless) {
      if (widget.expand) return _body();
      return SizedBox(
        height: math.max(MediaQuery.of(context).size.height * 0.55, 340.0) +
            _rsiHeight +
            _macdHeight,
        child: _body(),
      );
    }
    return LayoutBuilder(
      builder: (context, rootCons) {
        return Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: const Color(0xFF232A35)),
          ),
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 6),
          child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'XAU/USD',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      InkWell(
                        onTap: () => setState(() {
                          crosshairMode = !crosshairMode;
                          crosshairPos = null;
                        }),
                        child: Tooltip(
                          message: 'Crosshair',
                          child: SizedBox(
                            width: 28,
                            height: 24,
                            child: Icon(
                              Icons.add,
                              size: 18,
                              color: crosshairMode
                                  ? const Color(0xFFFFD166)
                                  : Colors.white,
                            ),
                          ),
                        ),
                      ),
                      InkWell(
                        onTap: presetDialog,
                        child: const Tooltip(
                          message: 'Chart layouts',
                          child: SizedBox(
                            width: 28,
                            height: 24,
                            child: Icon(Icons.bookmarks_outlined, size: 18),
                          ),
                        ),
                      ),
                      PopupMenuButton<ChartStyle>(
                        tooltip: 'Chart style',
                        initialValue: chartStyle,
                        onSelected: (v) => setState(() => chartStyle = v),
                        itemBuilder: (_) => [
                          for (final v in ChartStyle.values)
                            CheckedPopupMenuItem(
                              value: v,
                              checked: v == chartStyle,
                              child: Text(v.label),
                            ),
                        ],
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            chartStyle.label,
                            style: const TextStyle(
                              fontSize: 11,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                      PopupMenuButton<String>(
                        tooltip: 'Indicators',
                        onSelected: (v) {
                          if (v == 'configure') {
                            configureIndicators();
                            return;
                          }
                          setState(() {
                            switch (v) {
                              case 'SMA20':
                                smaOn = !smaOn;
                                break;
                              case 'SMA200':
                                sma200On = !sma200On;
                                break;
                              case 'EMA50':
                                emaOn = !emaOn;
                                break;
                              case 'RSI14':
                                rsiOn = !rsiOn;
                                break;
                              case 'MACD':
                                macdOn = !macdOn;
                                break;
                              case 'BB20':
                                bollingerOn = !bollingerOn;
                                break;
                              default:
                                final n = int.parse(v.substring(3));
                                extraEmas.contains(n)
                                    ? extraEmas.remove(n)
                                    : extraEmas.add(n);
                            }
                          });
                        },
                        itemBuilder: (_) => [
                          const PopupMenuItem(
                            value: 'configure',
                            child: Text('Indicator settings…'),
                          ),
                          for (final item in <(String, String, bool)>[
                            ('SMA20', 'SMA 20', smaOn),
                            ('SMA200', 'SMA 200', sma200On),
                            ('EMA9', 'EMA 9', extraEmas.contains(9)),
                            ('EMA21', 'EMA 21', extraEmas.contains(21)),
                            ('EMA50', 'EMA $emaPeriod', emaOn),
                            ('EMA200', 'EMA 200', extraEmas.contains(200)),
                            ('RSI14', 'RSI $rsiPeriod', rsiOn),
                            (
                              'MACD',
                              'MACD $macdFast/$macdSlow/$macdSignalPeriod',
                              macdOn,
                            ),
                            ('BB20', 'Bollinger 20 / 2', bollingerOn),
                          ])
                            CheckedPopupMenuItem(
                              value: item.$1,
                              checked: item.$3,
                              child: Text(item.$2),
                            ),
                        ],
                        child: const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'Indicators',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 11,
                                ),
                              ),
                              Icon(
                                Icons.arrow_drop_down,
                                color: Colors.white,
                                size: 18,
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (widget.onAlertPrice != null)
                        _indChip(
                          'Alert',
                          alertMode,
                          const Color(0xFFF5C242),
                          () => setState(() {
                            alertMode = !alertMode;
                            if (alertMode) {
                              drawMode = false;
                              trendMode = false;
                              fibMode = false;
                            }
                          }),
                        ),
                      if (widget.onReplay != null)
                        _indChip(
                          'Replay',
                          widget.replayOn,
                          const Color(0xFF9B7BFF),
                          widget.onReplay!,
                        ),
                      _indChip(
                        'Draw',
                        drawMode,
                        const Color(0xFF5EE0A0),
                        () => setState(() {
                          alertMode = false;
                          drawMode = !drawMode;
                          if (drawMode) {
                            trendMode = false;
                            fibMode = false;
                            rectMode = false;
                            channelMode = false;
                            rulerMode = false;
                          }
                        }),
                      ),
                      _indChip(
                        'Trend',
                        trendMode,
                        const Color(0xFF6FD3E0),
                        () => setState(() {
                          alertMode = false;
                          trendMode = !trendMode;
                          if (trendMode) {
                            drawMode = false;
                            fibMode = false;
                            rectMode = false;
                            channelMode = false;
                            rulerMode = false;
                          }
                          pendingTrend = null;
                        }),
                      ),
                      _indChip(
                        'Fib',
                        fibMode,
                        const Color(0xFFFFD166),
                        () => setState(() {
                          alertMode = false;
                          fibMode = !fibMode;
                          if (fibMode) {
                            drawMode = false;
                            trendMode = false;
                            rectMode = false;
                            channelMode = false;
                            rulerMode = false;
                          }
                          pendingFib = null;
                        }),
                      ),
                      _indChip(
                        'Sess',
                        sessionShadingOn,
                        const Color(0xFF5B8DEF),
                        () => setState(
                            () => sessionShadingOn = !sessionShadingOn),
                      ),
                      _indChip(
                        'PD/PW',
                        prevLevelsOn,
                        const Color(0xFFB78CFF),
                        () =>
                            setState(() => prevLevelsOn = !prevLevelsOn),
                      ),
                      _indChip(
                        'Rect',
                        rectMode,
                        const Color(0xFF6FD3E0),
                        () => setState(() {
                          alertMode = false;
                          rectMode = !rectMode;
                          if (rectMode) {
                            drawMode = false;
                            trendMode = false;
                            fibMode = false;
                            channelMode = false;
                            rulerMode = false;
                          }
                          pendingRect = null;
                        }),
                      ),
                      _indChip(
                        'Chan',
                        channelMode,
                        const Color(0xFF9B8CFF),
                        () => setState(() {
                          alertMode = false;
                          channelMode = !channelMode;
                          if (channelMode) {
                            drawMode = false;
                            trendMode = false;
                            fibMode = false;
                            rectMode = false;
                            rulerMode = false;
                          }
                          pendingChannel = null;
                          channelStage = 0;
                        }),
                      ),
                      _indChip(
                        'Ruler',
                        rulerMode,
                        const Color(0xFFF5C242),
                        () => setState(() {
                          alertMode = false;
                          rulerMode = !rulerMode;
                          if (rulerMode) {
                            drawMode = false;
                            trendMode = false;
                            fibMode = false;
                            rectMode = false;
                            channelMode = false;
                          }
                          pendingRuler = null;
                        }),
                      ),
                      _indChip(
                        'Magnet',
                        magnetOn,
                        const Color(0xFF5EE0A0),
                        () => setState(() => magnetOn = !magnetOn),
                      ),
                    ],
                  ),
                ),
              ),
              if (loading)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFF5C242),
                  ),
                ),
              if (_hasDrawings) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: _confirmClearAll,
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.delete_sweep,
                      size: 18,
                      color: Color(0xFFF27EA9),
                    ),
                  ),
                ),
              ],
              if (!widget.expand) ...[
                const SizedBox(width: 6),
                InkWell(
                  onTap: () async {
                    final layout = await Navigator.of(context)
                        .push<Map<String, dynamic>>(
                          MaterialPageRoute(
                            builder: (_) => FullscreenChartPage(
                              loader: widget.loader,
                              livePrice: chartPrice,
                              rangeMode: usingRange,
                              onAlertPrice: widget.onAlertPrice,
                              initialLayout: layoutSnapshot(),
                              marketUpdates: widget.marketUpdates,
                              marketSnapshot: widget.marketSnapshot,
                            ),
                          ),
                        );
                    if (mounted && layout != null) {
                      setState(() => usingRange = layout['rangeMode'] == true);
                      applyPreset(layout);
                    }
                  },
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(
                      Icons.fullscreen,
                      size: 18,
                      color: Color(0xFF8A93A6),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          const SizedBox(height: 6),
          _legend(dim),
          if (market.positions.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Text(
                market.summary,
                style: const TextStyle(fontSize: 10, color: Color(0xFF8A93A6)),
              ),
            ),
          if ((rsiOn && candles.length <= rsiPeriod) ||
              (emaOn && candles.length < emaPeriod) ||
              (macdOn && candles.length < macdSlow + macdSignalPeriod - 1))
            const Text(
              'More candle history needed for selected indicators.',
              style: TextStyle(fontSize: 10, color: Color(0xFF8A93A6)),
            ),
          const SizedBox(height: 4),
          if (widget.expand)
            Expanded(child: _body())
          else
            SizedBox(
              // TradingView feel: the chart dominates the screen. When a
              // parent bounds our height (embedded panels, test harnesses),
              // leave room for the header/toolbar/legend chrome instead of
              // overflowing.
              height: () {
                // TradingView feel: the chart dominates the screen. Applies
                // when the parent lets us grow (the trade page scrolls);
                // bounded embeds keep the compact 220px chart.
                if (rootCons.maxHeight.isFinite) {
                  return 220 + _rsiHeight + _macdHeight;
                }
                return math.max(
                      MediaQuery.of(context).size.height * 0.55,
                      340.0,
                    ) +
                    _rsiHeight +
                    _macdHeight;
              }(),
              child: _body(),
            ),
          if (!widget.expand && candles.length >= 50) _biasStrip(),
            ],
          ),
        );
      },
    );
  }

  /// Trend bias strip (spec: S/R + trend readout). Rule-based read of the
  /// candles and drawn levels already on the chart - reasons listed, never
  /// a prediction.
  Widget _biasStrip() {
    const green = Color(0xFF5EE0A0);
    const red = Color(0xFFFF6B6B);
    const dim = Color(0xFF8A93A6);
    final r = analyzeBias(candles, hLines.map((e) => e.price).toList());
    final color = r.bias == TrendBias.bullish
        ? green
        : r.bias == TrendBias.bearish
        ? red
        : dim;
    final label = r.bias == TrendBias.bullish
        ? 'Bullish'
        : r.bias == TrendBias.bearish
        ? 'Bearish'
        : 'Neutral';
    return GestureDetector(
      onTap: () => setState(() => biasExpanded = !biasExpanded),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          Row(
            children: [
              Icon(Icons.circle, size: 8, color: color),
              const SizedBox(width: 6),
              const Text(
                'Trend bias: ',
                style: TextStyle(color: dim, fontSize: 11),
              ),
              Text(
                label,
                style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const Spacer(),
              Icon(
                biasExpanded ? Icons.expand_less : Icons.expand_more,
                size: 16,
                color: dim,
              ),
            ],
          ),
          if (biasExpanded) ...[
            const SizedBox(height: 4),
            for (final f in r.factors)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      f.score > 0 ? '+' : (f.score < 0 ? '-' : '·'),
                      style: TextStyle(
                        color: f.score > 0 ? green : (f.score < 0 ? red : dim),
                        fontSize: 11,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        f.text,
                        style: const TextStyle(
                          color: Color(0xFFB9C0CE),
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            const Text(
              'Rule-based read of the current chart. Not a prediction.',
              style: TextStyle(
                color: dim,
                fontSize: 10,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _indChip(String label, bool on, Color color, VoidCallback tap) =>
      GestureDetector(
        onTap: tap,
        child: Container(
          margin: const EdgeInsets.only(right: 4),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
          decoration: BoxDecoration(
            color: on ? color.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: on ? color : const Color(0xFF2A3140)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: on ? color : const Color(0xFF8A93A6),
              fontSize: 10,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );

  Widget _legend(Color dim) {
    Candle? c;
    if (selected != null && _drawn.isNotEmpty) {
      c = _drawn[selected!.clamp(0, _drawn.length - 1)];
    } else if (candles.isNotEmpty) {
      c = _liveCandles.last; // forming bar folded with the live quote
    }
    if (error != null) {
      return Text(
        error!,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(color: Color(0xFFE0654F), fontSize: 11),
      );
    }
    if (c == null) {
      return Text(
        widget.loader == null
            ? 'Candle feed not configured. Add your Twelve Data key in API settings.'
            : 'Loading real candles...',
        style: TextStyle(color: dim, fontSize: 11),
      );
    }
    final up = c.close >= c.open;
    final col = up ? const Color(0xFF2EC27E) : const Color(0xFFE0654F);
    String f(double v) => v.toStringAsFixed(2);
    return Text(
      'O ${f(c.open)}  H ${f(c.high)}  L ${f(c.low)}  C ${f(c.close)}',
      style: TextStyle(color: col, fontSize: 11, fontFamily: 'Roboto'),
    );
  }

  Widget _body() {
    if (widget.loader == null) {
      return const Center(
        child: Text(
          'No candle source configured.\nReal data only - no demo bars.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
        ),
      );
    }
    if (candles.isEmpty && loading) {
      return const Center(
        child: Text(
          'Fetching candles from Twelve Data...',
          style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
        ),
      );
    }
    if (candles.isEmpty) {
      // The legend above the chart already shows the error detail.
      return const Center(
        child: Text(
          'No candles returned',
          textAlign: TextAlign.center,
          style: const TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, cons) {
        final chartGesture = GestureDetector(
          // Draw mode keeps pan for drag-moving levels; outside Draw, a
          // one-finger drag scrolls the chart and pinch zooms it. Crosshair
          // mode (MT5) owns the drag: it moves the crosshair instead.
          onPanDown: drawMode
              ? (d) => _dragLineStart(
                  d.localPosition,
                  Size(cons.maxWidth, cons.maxHeight),
                )
              : null,
          onPanUpdate: drawMode
              ? (d) => _dragLineUpdate(
                  d.localPosition,
                  Size(cons.maxWidth, cons.maxHeight),
                )
              : null,
          onPanEnd: drawMode ? (_) => _dragLineEnd() : null,
          onScaleStart: drawMode || rectMode || channelMode || rulerMode
              ? null
              : (d) {
                  _stopKinetic();
                  _gesturePointers = d.pointerCount;
                  _axisDrag = d.pointerCount == 1 &&
                      d.localFocalPoint.dx >= cons.maxWidth - rightPad;
                  _axisStartY = d.localFocalPoint.dy;
                  _axisStartScale = _priceScale;
                  _panStartScroll = scrollCandles;
                  _panStartX = d.localFocalPoint.dx;
                  _scaleStartVC = _vc.toDouble();
                  // Focal-anchored pinch: remember which candle sits under
                  // the focal point so it stays put while zooming.
                  final plotW0 = cons.maxWidth - rightPad;
                  final frac0 =
                      plotW0 > 0 ? d.localFocalPoint.dx / plotW0 : 0.5;
                  _scaleStartIndexFloat =
                      (_drawn.length - _vc - scrollCandles) +
                          frac0 * _vc;
                },
          onScaleUpdate: drawMode || rectMode || channelMode || rulerMode
              ? null
              : (d) {
                  final n = _drawn.length;
                  if (n == 0) return;
                  if (crosshairMode && d.pointerCount == 1) {
                    // MT5 crosshair mode: the drag moves the crosshair.
                    setState(() => crosshairPos = d.localFocalPoint);
                    return;
                  }
                  if (_axisDrag) {
                    // Price-axis drag: vertical stretch around the mid price
                    // (TradingView price-scale behavior). Down = expand.
                    setState(() {
                      _priceScale = (_axisStartScale *
                              math.exp(
                                  (d.localFocalPoint.dy - _axisStartY) *
                                      0.004))
                          .clamp(0.2, 20.0);
                    });
                    return;
                  }
                  if (d.pointerCount >= 2) {
                    setState(() {
                      final v = (_scaleStartVC / d.scale).round();
                      final vcNew = v < 8 ? 8 : (v > n ? n : v);
                      visibleOverride = vcNew;
                      // Keep the candle under the original focal point
                      // stationary (TradingView pinch feel).
                      final plotW = cons.maxWidth - rightPad;
                      final frac =
                          plotW > 0 ? _panStartX / plotW : 0.5;
                      final maxScroll =
                          (n - vcNew) > 0 ? (n - vcNew).toDouble() : 0.0;
                      scrollCandles = (n -
                              vcNew -
                              (_scaleStartIndexFloat - frac * vcNew))
                          .clamp(-5.0, maxScroll);
                    });
                  } else {
                    final plotW = cons.maxWidth - 52.0;
                    final step = plotW / _vc;
                    if (step <= 0) return;
                    setState(() {
                      final maxScroll = (n - _vc) > 0
                          ? (n - _vc).toDouble()
                          : 0.0;
                      scrollCandles =
                          (_panStartScroll +
                                  (d.localFocalPoint.dx - _panStartX) / step)
                              .clamp(-5.0, maxScroll);
                    });
                  }
                },
          onScaleEnd: drawMode || rectMode || channelMode || rulerMode
              ? null
              : (d) {
                  if (!_axisDrag && !crosshairMode && _gesturePointers == 1) {
                    _startKinetic(
                        d.velocity.pixelsPerSecond.dx,
                        cons.maxWidth - rightPad);
                  }
                  _axisDrag = false;
                },
          onTapDown: (d) {
            if (crosshairMode) {
              setState(() => crosshairPos = d.localPosition);
              return;
            }
            if (trendMode) {
              _trendAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            } else if (fibMode) {
              _fibAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            } else if (rectMode) {
              _rectAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            } else if (channelMode) {
              _channelAt(
                  d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            } else if (rulerMode) {
              _rulerAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            } else {
              _pick(d.localPosition, cons.maxWidth);
            }
          },
          onTapUp: (d) {
            // TradingView-style double-tap reset (manual detection: a real
            // onDoubleTap recognizer would delay every single tap in the
            // gesture arena). Chart area only, plain browse mode only.
            if (!drawMode &&
                !trendMode &&
                !fibMode &&
                !rectMode &&
                !channelMode &&
                !rulerMode &&
                !crosshairMode &&
                !alertMode &&
                d.localPosition.dx < cons.maxWidth - rightPad) {
              final now = DateTime.now();
              if (now.difference(_lastChartTap).inMilliseconds < 300) {
                _lastChartTap = DateTime.fromMillisecondsSinceEpoch(0);
                setState(() {
                  visibleOverride = null;
                  scrollCandles = 0;
                  _priceScale = 1.0;
                });
                return;
              }
              _lastChartTap = now;
            }
            // Draw-mode add/remove lives on tap-UP so a drag-move (pan wins
            // the arena) never deletes the line being moved.
            if (!drawMode &&
                !trendMode &&
                !fibMode &&
                widget.onAlertPrice != null &&
                (alertMode || d.localPosition.dx >= cons.maxWidth - rightPad)) {
              final price = _priceAtY(
                d.localPosition.dy,
                Size(cons.maxWidth, cons.maxHeight),
              );
              if (price != null && price.isFinite && price > 0)
                widget.onAlertPrice!(double.parse(price.toStringAsFixed(2)));
            }
            if (drawMode) {
              _drawAt(d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            }
          },
          onLongPressStart: (d) {
            // Press-and-hold crosshair (TradingView-style) when the hold
            // does not land on an existing drawing; line editing unchanged.
            if (!drawMode &&
                !trendMode &&
                !fibMode &&
                !rectMode &&
                !channelMode &&
                !rulerMode &&
                !alertMode &&
                !_anyDrawingHit(
                    d.localPosition, Size(cons.maxWidth, cons.maxHeight))) {
              setState(() {
                _longPressCrosshair = true;
                crosshairMode = true;
                crosshairPos = d.localPosition;
              });
            } else {
              _editLineAt(
                  d.localPosition, Size(cons.maxWidth, cons.maxHeight));
            }
          },
          onLongPressMoveUpdate: (d) {
            if (_longPressCrosshair) {
              setState(() => crosshairPos = d.localPosition);
            }
          },
          onLongPressEnd: (_) {
            _longPressCrosshair = false; // crosshair stays until toggled off
          },
          child: CustomPaint(
            size: Size(cons.maxWidth, cons.maxHeight),
            painter: CandlePainter(
              candles: _liveCandles,
              sessionShading: sessionShadingOn,
              prevDayHL: prevLevelsOn ? previousDayHL(candles) : null,
              prevWeekHL: prevLevelsOn ? previousWeekHL(candles) : null,
              priceScale: _priceScale,
              firstVisible: _fv,
              visibleCount: _vc,
              livePrice: chartPrice,
              now: _chartNow(),
              reserveTopLeft: widget.chromeless && widget.expand,
              showCountdown: market.fresh,
              bid: market.bid,
              ask: showAskLine ? market.ask : null,
              strategySegments: strategySegments,
              crosshair: crosshairMode ? crosshairPos : null,
              chartStyle: chartStyle,
              positions: market.positions,
              macdSlow: macdSlow,
              macdSignalPeriod: macdSignalPeriod,
              selected: selected,
              hLines: hLines,
              trendLines: trendLines,
              pendingTrend: pendingTrend,
              rects: rects,
              pendingRect: pendingRect,
              channels: channels,
              pendingChannel: pendingChannel,
              rulers: rulers,
              pendingRuler: pendingRuler,
              fibs: fibs,
              pendingFib: pendingFib,
              extraEmas: {for (final p in extraEmas) p: ema(candles, p)},
              bands: bollingerOn ? bollinger(candles) : null,
              sma: smaOn ? sma(candles, 20) : null,
              sma200: sma200On ? sma(candles, 200) : null,
              smaPeriod: 20,
              ema: emaOn ? ema(candles, emaPeriod) : null,
              emaPeriod: emaPeriod,
              rsi: rsiOn ? rsi(candles, rsiPeriod) : null,
              macdLine: macdOn
                  ? macd(
                      candles,
                      fast: macdFast,
                      slow: macdSlow,
                      signalPeriod: macdSignalPeriod,
                    ).$1
                  : null,
              macdSignal: macdOn
                  ? macd(
                      candles,
                      fast: macdFast,
                      slow: macdSlow,
                      signalPeriod: macdSignalPeriod,
                    ).$2
                  : null,
              macdHist: macdOn
                  ? macd(
                      candles,
                      fast: macdFast,
                      slow: macdSlow,
                      signalPeriod: macdSignalPeriod,
                    ).$3
                  : null,
              rsiPeriod: rsiPeriod,
            ),
          ),
        );
        // MT5 "Go to..." chip: appears when the chart is scrolled back;
        // tapping returns to the newest bar and re-pins auto-scroll.
        return Stack(
          children: [
            Positioned.fill(child: chartGesture),
            if (scrollCandles > 0.5)
              Positioned(
                right: 8,
                bottom: 8,
                child: InkWell(
                  onTap: () => setState(() => scrollCandles = 0),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232A35),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: const Color(0xFFFFD166)),
                    ),
                    child: const Text(
                      'Go to \u25B6|',
                      style: TextStyle(
                        color: Color(0xFFFFD166),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  void _pick(Offset pos, double width) {
    final plotW = width - rightPad;
    if (plotW <= 0 || _drawn.isEmpty) return;
    final n = _drawn.length;
    var i = (_fv + (pos.dx / plotW) * _vc).floor();
    if (i < 0) i = 0;
    if (i > n - 1) i = n - 1;
    setState(() => selected = i);
  }

  /// Index of a trend line within ~10px of the tap (pixel space), else -1.
  int _trendHit(Offset pos, Size plotSize, double hi, double lo) {
    if (trendLines.isEmpty || candles.length < 2) return -1;
    final plotW = plotSize.width - rightPad;
    final plotH = plotSize.height;
    final n = candles.length;
    double yOf(double v) => plotH * (1 - (v - lo) / (hi - lo));
    double idxAt(DateTime t) {
      final t0 = candles.first.time.millisecondsSinceEpoch;
      final tN = candles.last.time.millisecondsSinceEpoch;
      if (tN == t0) return 0;
      return (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
    }

    final stepI = plotW / _vc;
    for (int k = 0; k < trendLines.length; k++) {
      final l = trendLines[k];
      final x1 = stepI * (idxAt(l.t1) - _fv + 0.5);
      final x2 = stepI * (idxAt(l.t2) - _fv + 0.5);
      if ((x2 - x1).abs() < 1e-6) continue;
      final y1 = yOf(l.p1), y2 = yOf(l.p2);
      final m = (y2 - y1) / (x2 - x1);
      final yAtTap = y1 + m * (pos.dx - x1);
      if ((yAtTap - pos.dy).abs() < 10) return k;
    }
    return -1;
  }

  /// Trend mode: first tap anchors one end (candle time + price), second
  /// tap completes the line. Anchored by time so it tracks the market.
  /// Magnet snap: pull an anchor price to the nearest high/low of the
  /// candle under it when close enough (TradingView magnet behavior).
  double _snapPrice(double price, int candleIdx, double hi, double lo) {
    if (!magnetOn || candleIdx < 0 || candleIdx >= candles.length) {
      return price;
    }
    final range = hi - lo;
    if (range <= 0) return price;
    final threshold = range * 0.025;
    final c = candles[candleIdx];
    var best = price;
    var bestD = threshold;
    for (final cand in [c.high, c.low]) {
      final d = (cand - price).abs();
      if (d < bestD) {
        bestD = d;
        best = cand;
      }
    }
    return best;
  }

  /// Shared anchor resolution for the two-anchor drawing tools: maps a tap
  /// to (candle time, snapped price), or null when off the plot.
  (DateTime, double)? _anchorAt(Offset pos, Size size) {
    final plotW = size.width - rightPad;
    const bottomPad = 16.0;
    final paneH =
        chartPaneHeight(size.height, _rsiHeight > 0, _macdHeight > 0);
    final rsiH = _rsiHeight > 0 ? paneH : 0.0;
    final macdH = _macdHeight > 0 ? paneH : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH || pos.dx < 0 || pos.dx > plotW) {
      return null;
    }
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final scaled = _applyPriceScale(hi, lo);
    hi = scaled.$1;
    lo = scaled.$2;
    var price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final n = candles.length;
    var i = (_fv + (pos.dx / plotW) * _vc).floor();
    if (i < 0) i = 0;
    if (i > n - 1) i = n - 1;
    price = _snapPrice(price, i, hi, lo);
    return (candles[i].time, price);
  }

  void _rectAt(Offset pos, Size size) {
    final a = _anchorAt(pos, size);
    if (a == null) return;
    setState(() {
      final p = pendingRect;
      if (p == null) {
        pendingRect = TrendLine(a.$1, a.$2, a.$1, a.$2);
      } else {
        _pushUndo();
        rects.add(TrendLine(p.t1, p.p1, a.$1, a.$2));
        pendingRect = null;
        _saveRects();
      }
    });
  }

  void _channelAt(Offset pos, Size size) {
    final a = _anchorAt(pos, size);
    if (a == null) return;
    setState(() {
      if (channelStage == 0) {
        pendingChannel = Channel(a.$1, a.$2, a.$1, a.$2, 0);
        channelStage = 1;
      } else if (channelStage == 1) {
        final p = pendingChannel!;
        pendingChannel = Channel(p.t1, p.p1, a.$1, a.$2, 0);
        channelStage = 2;
      } else {
        final p = pendingChannel!;
        // Third tap: parallel line passes through this price at its time.
        // dp is the price offset of the parallel line (constant in price).
        final t1ms = p.t1.millisecondsSinceEpoch;
        final t2ms = p.t2.millisecondsSinceEpoch;
        final ams = a.$1.millisecondsSinceEpoch;
        final onLine = t2ms == t1ms
            ? p.p2
            : p.p1 + (p.p2 - p.p1) * (ams - t1ms) / (t2ms - t1ms);
        _pushUndo();
        channels.add(Channel(p.t1, p.p1, p.t2, p.p2, a.$2 - onLine));
        pendingChannel = null;
        channelStage = 0;
        _saveChannels();
      }
    });
  }

  void _rulerAt(Offset pos, Size size) {
    final a = _anchorAt(pos, size);
    if (a == null) return;
    setState(() {
      final p = pendingRuler;
      if (p == null) {
        pendingRuler = TrendLine(a.$1, a.$2, a.$1, a.$2);
      } else {
        _pushUndo();
        rulers.add(TrendLine(p.t1, p.p1, a.$1, a.$2));
        pendingRuler = null;
        _saveRulers();
      }
    });
  }

  void _trendAt(Offset pos, Size size) {
    if (candles.isEmpty) return;
    const bottomPad = 16.0;
    final paneH = chartPaneHeight(size.height, _rsiHeight > 0, _macdHeight > 0);
    final rsiH = _rsiHeight > 0 ? paneH : 0.0;
    final macdH = _macdHeight > 0 ? paneH : 0.0;
    final plotW = size.width - rightPad;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH || pos.dx < 0 || pos.dx > plotW) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final scaled = _applyPriceScale(hi, lo);
    hi = scaled.$1;
    lo = scaled.$2;
    var price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final n = candles.length;
    var i = (_fv + (pos.dx / plotW) * _vc).floor();
    if (i < 0) i = 0;
    if (i > n - 1) i = n - 1;
    price = _snapPrice(price, i, hi, lo);
    final t = candles[i].time;
    setState(() {
      final p = pendingTrend;
      if (p == null) {
        pendingTrend = TrendLine(t, price, t, price);
      } else {
        if (t == p.t1) return; // same candle - ignore
        _pushUndo();
        trendLines.add(TrendLine(p.t1, p.p1, t, price));
        pendingTrend = null;
        _saveTrends();
      }
    });
  }

  /// Index of a fib whose level line passes within ~10px of the tap.
  int _fibHit(Offset pos, Size plotSize, double hi, double lo) {
    if (fibs.isEmpty) return -1;
    const fibFs = [0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0];
    final plotH = plotSize.height;
    double yOf(double v) => plotH * (1 - (v - lo) / (hi - lo));
    for (int k = 0; k < fibs.length; k++) {
      final f = fibs[k];
      for (final frac in fibFs) {
        final price = f.p2 + (f.p1 - f.p2) * frac;
        if ((yOf(price) - pos.dy).abs() < 10) return k;
      }
    }
    return -1;
  }

  /// Fib mode: first tap anchors one swing point, second tap completes the
  /// retracement. Levels are derived from the two anchor prices only.
  void _fibAt(Offset pos, Size size) {
    if (candles.isEmpty) return;
    const bottomPad = 16.0;
    final paneH = chartPaneHeight(size.height, _rsiHeight > 0, _macdHeight > 0);
    final rsiH = _rsiHeight > 0 ? paneH : 0.0;
    final macdH = _macdHeight > 0 ? paneH : 0.0;
    final plotW = size.width - rightPad;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH || pos.dx < 0 || pos.dx > plotW) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final scaled = _applyPriceScale(hi, lo);
    hi = scaled.$1;
    lo = scaled.$2;
    var price = lo + (1 - pos.dy / plotH) * (hi - lo);
    final n = candles.length;
    var i = (_fv + (pos.dx / plotW) * _vc).floor();
    if (i < 0) i = 0;
    if (i > n - 1) i = n - 1;
    price = _snapPrice(price, i, hi, lo);
    final t = candles[i].time;
    setState(() {
      final p = pendingFib;
      if (p == null) {
        pendingFib = TrendLine(t, price, t, price);
      } else {
        if (t == p.t1) return; // same candle - ignore
        _pushUndo();
        fibs.add(TrendLine(p.t1, p.p1, t, price));
        pendingFib = null;
        _saveFibs();
      }
    });
  }

  /// Shared y->price mapping for draw gestures.
  double? _priceAtY(double dy, Size size) {
    if (candles.isEmpty) return null;
    const bottomPad = 16.0;
    final paneH = chartPaneHeight(size.height, _rsiHeight > 0, _macdHeight > 0);
    final rsiH = _rsiHeight > 0 ? paneH : 0.0;
    final macdH = _macdHeight > 0 ? paneH : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (dy < 0 || dy > plotH) return null;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final scaled = _applyPriceScale(hi, lo);
    hi = scaled.$1;
    lo = scaled.$2;
    return lo + (1 - dy / plotH) * (hi - lo);
  }

  /// Spec 9 (move): in Draw mode, dragging from an existing level moves it
  /// to follow the finger; the new price saves when the drag ends.
  void _dragLineStart(Offset pos, Size size) {
    final price = _priceAtY(pos.dy, size);
    if (price == null) return;
    double hi = -double.infinity, lo = double.infinity;
    for (final c in candles) {
      hi = hi > c.high ? hi : c.high;
      lo = lo < c.low ? lo : c.low;
    }
    final range = hi - lo;
    final hit = hLines.indexWhere(
      (l) => (l.price - price).abs() < range * 0.02,
    );
    if (hit >= 0) _pushUndo();
    setState(() => _dragLineIdx = hit >= 0 ? hit : null);
  }

  void _dragLineUpdate(Offset pos, Size size) {
    final idx = _dragLineIdx;
    if (idx == null) return;
    final price = _priceAtY(pos.dy, size);
    if (price == null) return;
    setState(() => hLines[idx] = DrawnLine(price, hLines[idx].name));
  }

  void _dragLineEnd() {
    if (_dragLineIdx == null) return;
    setState(() => _dragLineIdx = null);
    _saveLines();
  }

  /// Draw mode: convert the tap's y position to a price and add a
  /// horizontal line; tapping near an existing line removes it.
  void _drawAt(Offset pos, Size size) {
    if (candles.isEmpty) return;
    const bottomPad = 16.0;
    final paneH = chartPaneHeight(size.height, _rsiHeight > 0, _macdHeight > 0);
    final rsiH = _rsiHeight > 0 ? paneH : 0.0;
    final macdH = _macdHeight > 0 ? paneH : 0.0;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (pos.dy < 0 || pos.dy > plotH) return;
    var (hi, lo) = _visiblePriceRange();
    final pad = ((hi - lo) * 0.05).clamp(0.01, double.infinity);
    hi += pad;
    lo -= pad;
    final scaled = _applyPriceScale(hi, lo);
    hi = scaled.$1;
    lo = scaled.$2;
    final price = lo + (1 - pos.dy / plotH) * (hi - lo);
    // remove if tapping within 1% of range of an existing line
    final range = hi - lo;
    final hit = hLines.indexWhere(
      (l) => (l.price - price).abs() < range * 0.02,
    );
    setState(() {
      if (hit >= 0) {
        _pushUndo();
        hLines.removeAt(hit);
      } else {
        _pushUndo();
        hLines.add(DrawnLine(price, 'Level ${hLines.length + 1}'));
      }
    });
    _saveLines();
  }
}

/// One strategy level in candle-INDEX space (chart draws candles equally
/// spaced, so the painter works in indices, not timestamps).
class StrategyLevelSegment {
  final double price;
  final bool isHigh;
  final int startIdx;
  final int endIdx;
  final bool broken;
  const StrategyLevelSegment({
    required this.price,
    required this.isHigh,
    required this.startIdx,
    required this.endIdx,
    this.broken = false,
  });
}

class CandlePainter extends CustomPainter {
  final List<Candle> candles;
  final double? livePrice;

  /// Editor overlay occupies the top-left; level labels stay clear of it.
  final bool reserveTopLeft;
  final double? bid;
  final double? ask;
  final List<StrategyLevelSegment> strategySegments;
  final int? selected;
  final Offset? crosshair;
  final List<double>? sma;
  final int smaPeriod;
  final List<double>? sma200;
  final List<double>? ema;
  final int emaPeriod;
  final List<double>? rsi;
  final int rsiPeriod;
  final List<double>? macdLine;
  final List<double>? macdSignal;
  final List<double>? macdHist;
  final List<DrawnLine> hLines;
  final List<TrendLine> trendLines;
  final TrendLine? pendingTrend;
  final List<TrendLine> rects;
  final TrendLine? pendingRect;
  final List<Channel> channels;
  final Channel? pendingChannel;
  final List<TrendLine> rulers;
  final TrendLine? pendingRuler;
  final List<TrendLine> fibs;
  final TrendLine? pendingFib;
  final Map<int, List<double>> extraEmas;
  final (List<double>, List<double>, List<double>)? bands;
  final ChartStyle chartStyle;
  final List<ChartPosition> positions;
  final int macdSlow, macdSignalPeriod;
  final int firstVisible;
  final int visibleCount;
  final bool sessionShading;
  final (double, double)? prevDayHL;
  final (double, double)? prevWeekHL;
  final double priceScale;

  /// Wall clock for the candle-close countdown; null hides the countdown.
  final DateTime? now;
  final bool showCountdown;

  CandlePainter({
    required this.candles,
    this.chartStyle = ChartStyle.candles,
    this.sessionShading = false,
    this.prevDayHL,
    this.prevWeekHL,
    this.now,
    this.showCountdown = false,
    this.priceScale = 1.0,
    this.positions = const [],
    this.macdSlow = 26,
    this.macdSignalPeriod = 9,
    this.firstVisible = 0,
    this.visibleCount = 0,
    this.livePrice,
    this.reserveTopLeft = false,
    this.bid,
    this.ask,
    this.strategySegments = const [],
    this.selected,
    this.crosshair,
    this.hLines = const [],
    this.trendLines = const [],
    this.pendingTrend,
    this.rects = const [],
    this.pendingRect,
    this.channels = const [],
    this.pendingChannel,
    this.rulers = const [],
    this.pendingRuler,
    this.fibs = const [],
    this.pendingFib,
    this.extraEmas = const {},
    this.bands,
    this.sma,
    this.smaPeriod = 20,
    this.sma200,
    this.ema,
    this.emaPeriod = 50,
    this.rsi,
    this.rsiPeriod = 14,
    this.macdLine,
    this.macdSignal,
    this.macdHist,
  });

  /// 4127.45 -> "4,127.45" (TradingView-style thousands grouping).
  static String fmtAxisPrice(double v) {
    final s = v.toStringAsFixed(2);
    final dot = s.indexOf('.');
    final intPart = dot < 0 ? s : s.substring(0, dot);
    final rest = dot < 0 ? '' : s.substring(dot);
    final buf = StringBuffer();
    for (var i = 0; i < intPart.length; i++) {
      if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
      buf.write(intPart[i]);
    }
    return '$buf$rest';
  }

  static const bull = Color(0xFF26A69A);
  static const bear = Color(0xFFEF5350);
  static const grid = Color(0xFF161C26);
  static const axis = Color(0xFF8A93A6);
  static const gold = Color(0xFFF5C242);

  @override
  void paint(Canvas canvas, Size size) {
    const rightPad = 52.0;
    const bottomPad = 16.0;
    final paneH = chartPaneHeight(
      size.height,
      rsi != null && rsi!.isNotEmpty,
      macdLine != null && macdLine!.isNotEmpty,
    );
    final rsiH = rsi != null && rsi!.isNotEmpty ? paneH : 0.0;
    final macdH = macdLine != null && macdLine!.isNotEmpty ? paneH : 0.0;
    final plotW = size.width - rightPad;
    final plotH = size.height - bottomPad - rsiH - macdH;
    if (candles.isEmpty || plotW <= 0 || plotH <= 0) return;
    // True black chart background (user request).
    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);

    final n0 = candles.length;
    final vc0 = visibleCount <= 0 || visibleCount > n0 ? n0 : visibleCount;
    var fv0 = firstVisible;
    if (fv0 < 0) fv0 = 0;
    if (fv0 + vc0 > n0) fv0 = n0 - vc0 < 0 ? 0 : n0 - vc0;
    double hi = -double.infinity, lo = double.infinity;
    for (int i = fv0; i < fv0 + vc0 && i < n0; i++) {
      final c = candles[i];
      hi = math.max(hi, c.high);
      lo = math.min(lo, c.low);
    }
    if (livePrice != null) {
      hi = math.max(hi, livePrice!);
      lo = math.min(lo, livePrice!);
    }
    for (final hl in [prevDayHL, prevWeekHL]) {
      if (hl == null) continue;
      hi = math.max(hi, hl.$1);
      lo = math.min(lo, hl.$2);
    }
    final pad = math.max((hi - lo) * 0.05, 0.01);
    hi += pad;
    lo -= pad;
    if (priceScale != 1.0) {
      final mid = (hi + lo) / 2, half = (hi - lo) / 2 * priceScale;
      hi = mid + half;
      lo = mid - half;
    }
    double y(double v) => plotH * (1 - (v - lo) / (hi - lo));

    // grid + price labels (TradingView-style): faint dotted grid on round
    // price steps, dense comma-formatted labels, minor axis ticks.
    final labelStyle = TextStyle(
      color: axis,
      fontSize: 10,
      fontFamily: 'Roboto',
      height: 1,
    );
    double niceStep(double range) {
      final target = range / 6;
      if (target <= 0 || !target.isFinite) return 1;
      final mag =
          math.pow(10, (math.log(target) / math.ln10).floor()).toDouble();
      final t = target / mag;
      final s = t < 1.5 ? 1.0 : t < 3.5 ? 2.0 : t < 7.5 ? 5.0 : 10.0;
      return s * mag;
    }

    final stepG = niceStep(hi - lo);
    final tickPaint = Paint()
      ..color = axis.withValues(alpha: 0.45)
      ..strokeWidth = 1;
    final lpY = livePrice == null ? null : y(livePrice!);
    for (double v = (lo / stepG).ceil() * stepG; v <= hi; v += stepG) {
      final yy = y(v);
      if (yy < 0 || yy > plotH) continue;
      // The last-price pill + candle-close countdown occupy this band on the
      // axis; a grid label behind them reads as a collision.
      if (lpY != null && (yy - lpY).abs() < 34) continue;
      for (int m = 1; m < 5; m++) {
        final my = y(v + stepG * m / 5);
        if (my >= 0 && my <= plotH) {
          canvas.drawLine(
              Offset(plotW + 1, my), Offset(plotW + 4, my), tickPaint);
        }
      }
      final tp = TextPainter(
        text: TextSpan(text: fmtAxisPrice(v), style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          plotW + 6,
          (yy - tp.height / 2).clamp(0.0, size.height - tp.height),
        ),
      );
    }

    // Axis pills are collected through the paint and rendered at the end
    // with vertical de-collision (TradingView stacks overlapping tags).
    final axisPills = <(double, Color, Color, bool)>[];
    void priceTag(double price, Color bg, Color fg) {
      axisPills.add((price, bg, fg, false));
    }



    // Candle OHLC is immutable provider history. The separate quote marker
    // must never rewrite old candles after a market/data gap.
    final eff =
        chartStyle == ChartStyle.heikinAshi ? _heikinAshi(candles) : candles;
    final n = eff.length;
    final step = plotW / vc0;
    final bodyW = math.max(step * 0.55, 1.5);
    final iEnd = fv0 + vc0 < n ? fv0 + vc0 : n;
    final closePath = Path();
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, plotW, plotH));
    if (sessionShading) {
      // Translucent vertical bands per market session (UTC reference
      // windows, matching the sessions strip). Overlaps blend.
      const bandColors = {
        ChartSession.asia: Color(0x0D2EC4B6),
        ChartSession.london: Color(0x0F5B8DEF),
        ChartSession.newYork: Color(0x0DF5A142),
      };
      for (final entry in bandColors.entries) {
        final paint = Paint()..color = entry.value;
        int? bandStart;
        for (int i = fv0; i <= iEnd; i++) {
          final active = i < iEnd &&
              sessionsAt(candles[i].time).contains(entry.key);
          if (active && bandStart == null) {
            bandStart = i;
          } else if (!active && bandStart != null) {
            canvas.drawRect(
              Rect.fromLTRB(
                step * (bandStart - fv0),
                0,
                step * (i - fv0),
                plotH,
              ),
              paint,
            );
            bandStart = null;
          }
        }
      }
    }
    for (int i = fv0; i < iEnd; i++) {
      final c = eff[i];
      final up = c.close >= c.open;
      final paint = Paint()..color = up ? bull : bear;
      final cx = step * (i - fv0 + 0.5);
      if (chartStyle == ChartStyle.line) {
        if (i == fv0) {
          closePath.moveTo(cx, y(c.close));
        } else {
          closePath.lineTo(cx, y(c.close));
        }
        continue;
      }
      canvas.drawLine(
        Offset(cx, y(c.high)),
        Offset(cx, y(c.low)),
        paint..strokeWidth = 1,
      );
      if (chartStyle == ChartStyle.bars) {
        canvas.drawLine(
          Offset(cx - bodyW / 2, y(c.open)),
          Offset(cx, y(c.open)),
          paint,
        );
        canvas.drawLine(
          Offset(cx, y(c.close)),
          Offset(cx + bodyW / 2, y(c.close)),
          paint,
        );
        continue;
      }
      final top = y(math.max(c.open, c.close));
      final bot = y(math.min(c.open, c.close));
      canvas.drawRect(
        Rect.fromLTRB(
          cx - bodyW / 2,
          top,
          cx + bodyW / 2,
          math.max(bot, top + 1),
        ),
        paint,
      );
    }

    if (chartStyle == ChartStyle.line)
      canvas.drawPath(
        closePath,
        Paint()
          ..color = gold
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );
    canvas.restore();
    // Previous day/week high-low reference lines (NY-close sessions,
    // TradingView/OANDA style). Dashed, subtle, labeled at the left edge.
    for (final spec in [
      (prevDayHL?.$1, 'PDH', const Color(0xFF9AA7BD)),
      (prevDayHL?.$2, 'PDL', const Color(0xFF9AA7BD)),
      (prevWeekHL?.$1, 'PWH', const Color(0xFFB78CFF)),
      (prevWeekHL?.$2, 'PWL', const Color(0xFFB78CFF)),
    ]) {
      final price = spec.$1;
      if (price == null) continue;
      final yy = y(price);
      if (yy < 0 || yy > plotH) continue;
      final label = !reserveTopLeft || yy > 110;
      final lp = Paint()
        ..color = spec.$3.withValues(alpha: 0.75)
        ..strokeWidth = 1;
      for (double x = 0; x < plotW; x += 10) {
        canvas.drawLine(Offset(x, yy), Offset(math.min(x + 5, plotW), yy), lp);
      }
      if (label) {
        final tp = TextPainter(
          text: TextSpan(
            text: '${spec.$2} ${price.toStringAsFixed(2)}',
            style: TextStyle(
              color: spec.$3,
              fontSize: 9,
              fontFamily: 'Roboto',
              height: 1,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final ty = (yy - tp.height - 2).clamp(0.0, plotH - tp.height);
        tp.paint(canvas, Offset(4, ty));
      }
      priceTag(price, spec.$3, Colors.black);
    }
    // Display-only paper trade levels. Off-screen levels get explicit edge labels;
    // they never expand the range or masquerade as a price within the view.
    final used = <double>[];
    for (var i = 0; i < positions.length; i++) {
      final p = positions[i];
      for (final level in [
        (
          p.entry,
          '${i + 1} ${p.buy ? 'BUY' : 'SELL'} entry',
          const Color(0xFF4EA1FF),
        ),
        (p.stop, '${i + 1} SL', bear),
        (p.target, '${i + 1} TP', bull),
      ]) {
        final price = level.$1;
        if (price == null || !price.isFinite || price <= 0) continue;
        final yy = y(price);
        final inside = yy >= 0 && yy <= plotH;
        if (inside) {
          for (double x = 0; x < plotW; x += 8)
            canvas.drawLine(
              Offset(x, yy),
              Offset(math.min(x + 4, plotW), yy),
              Paint()..color = level.$3.withValues(alpha: 0.7),
            );
          priceTag(price, level.$3, Colors.white);
          continue;
        }
        final labelY = overlayLabelY(yy, plotH, used);
        if (labelY == null) continue;
        used.add(labelY);
        final label = TextPainter(
          text: TextSpan(
            text:
                '${inside
                    ? ''
                    : yy < 0
                    ? 'Above: '
                    : 'Below: '}${level.$2} ${price.toStringAsFixed(2)}',
            style: TextStyle(
              color: level.$3,
              fontFamily: 'Roboto',
              fontSize: 9,
              backgroundColor: const Color(0xFF0E1116),
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: plotW);
        label.paint(canvas, Offset(3, labelY));
      }
    }

    // indicator overlays (aligned: value[i] pairs with candle[period-1+i])
    final stepI = plotW / vc0;
    void drawLine(List<double> series, int period, Color color) {
      if (series.isEmpty) return;
      final paint = Paint()
        ..color = color
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (int i = 0; i < series.length; i++) {
        final idx = period - 1 + i;
        if (idx >= n) break;
        final x = stepI * (idx - fv0 + 0.5);
        final yy = y(series[i]);
        if (i == 0) {
          path.moveTo(x, yy);
        } else {
          path.lineTo(x, yy);
        }
      }
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, 0, plotW, plotH));
      canvas.drawPath(path, paint);
      canvas.restore();
    }

    if (sma != null) drawLine(sma!, smaPeriod, const Color(0xFF4EA1FF));
    if (sma200 != null) drawLine(sma200!, 200, const Color(0xFF6FD3E0));
    if (ema != null) drawLine(ema!, emaPeriod, const Color(0xFFFF9F43));

    const emaColors = {
      9: Color(0xFFB78CFF),
      21: Color(0xFFFFD166),
      200: Color(0xFF70D6FF),
    };
    for (final entry in extraEmas.entries)
      drawLine(entry.value, entry.key, emaColors[entry.key] ?? gold);
    if (bands != null) {
      drawLine(bands!.$1, 20, const Color(0xFF95D5B2));
      drawLine(bands!.$2, 20, const Color(0xFF52B788));
      drawLine(bands!.$3, 20, const Color(0xFF52B788));
    }

    // custom strategy levels (user request): 1H high/low markers, each
    // segment ending where price broke the level. Clipped to the plot:
    // levels outside the visible price range are skipped entirely so they
    // never draw over the header (real-phone report, v1.0.97).
    final levelLabelYs = <double>[];
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, plotW, plotH));
    for (final seg in strategySegments) {
      if (seg.endIdx < fv0 || seg.startIdx >= iEnd) continue;
      final x1 = stepI * (seg.startIdx - fv0 + 0.5);
      final x2 = math.min(stepI * (seg.endIdx - fv0 + 0.5), plotW);
      final yy = y(seg.price);
      if (yy < 0 || yy > plotH) continue;
      final col = seg.isHigh
          ? const Color(0xFFF48FB1)
          : const Color(0xFF80DEEA);
      final p = Paint()
        ..color = seg.broken ? col.withValues(alpha: 0.45) : col
        ..strokeWidth = 1;
      double dx = math.max(x1, 0.0);
      while (dx < x2) {
        canvas.drawLine(
          Offset(dx, yy),
          Offset(math.min(dx + 3, x2), yy),
          p,
        );
        dx += 6;
      }
      if (!seg.broken) {
        final tp = TextPainter(
          text: TextSpan(
            text: seg.price.toStringAsFixed(2),
            style: TextStyle(
              color: col,
              fontSize: 8,
              fontFamily: 'Roboto',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // keep labels readable: drop one that would collide with a label
        // already drawn at nearly the same height
        if (levelLabelYs.any((v) => (v - yy).abs() < tp.height + 2)) {
          continue;
        }
        levelLabelYs.add(yy);
        final lx = (math.max(x1, 0) + 2)
            .clamp(0.0, math.max(0.0, plotW - tp.width - 2))
            .toDouble();
        tp.paint(canvas, Offset(lx, yy - tp.height - 1));
      }
    }
    canvas.restore();

    // MT5 free crosshair: vertical+horizontal lines at the finger, price
    // tag on the right axis, bar date/time tag on the bottom axis.
    final ch = crosshair;
    if (ch != null) {
      final dash = Paint()
        ..color = Colors.white.withOpacity(0.85)
        ..strokeWidth = 0.7;
      canvas.drawLine(Offset(ch.dx, 0), Offset(ch.dx, plotH), dash);
      canvas.drawLine(Offset(0, ch.dy), Offset(plotW, ch.dy), dash);
      final chPrice = lo + (plotH - ch.dy) / plotH * (hi - lo);
      if (ch.dy >= 0 && ch.dy <= plotH) {
        final tp = TextPainter(
          text: TextSpan(
            text: chPrice.toStringAsFixed(2),
            style: const TextStyle(
              color: Colors.black,
              fontSize: 9,
              fontFamily: 'Roboto',
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final ty = (ch.dy - tp.height / 2).clamp(0.0, size.height - tp.height);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(plotW + 2, ty - 2, tp.width + 8, tp.height + 4),
            const Radius.circular(3),
          ),
          Paint()..color = const Color(0xFFB0BEC5),
        );
        tp.paint(canvas, Offset(plotW + 6, ty));
      }
      final bi = fv0 + (ch.dx / step).floor();
      if (bi >= fv0 && bi < iEnd) {
        final t = eff[bi].time.toLocal();
        String two(int v) => v.toString().padLeft(2, '0');
        final label = '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 9,
              fontFamily: 'Roboto',
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final tx = (ch.dx - tp.width / 2).clamp(0.0, plotW - tp.width - 8);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(tx - 4, plotH + 2, tp.width + 8, tp.height + 4),
            const Radius.circular(3),
          ),
          Paint()..color = const Color(0xFFB0BEC5),
        );
        tp.paint(canvas, Offset(tx, plotH + 4));
      }
    }

    // crosshair
    if (selected != null && selected! < n) {
      final c = candles[selected!];
      final cx = step * (selected! - fv0 + 0.5);
      final cy = y(c.close);
      final dash = Paint()
        ..color = axis.withOpacity(0.6)
        ..strokeWidth = 0.5;
      canvas.drawLine(Offset(cx, 0), Offset(cx, plotH), dash);
      canvas.drawLine(Offset(0, cy), Offset(plotW, cy), dash);
    }

    // last price line + tag (TradingView-style white dotted line + pill,
    // candle-close countdown beneath the pill)
    final lp = livePrice ?? candles.last.close;
    final lpy = y(lp);
    final dashPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.85)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, lpy), Offset(plotW, lpy), dashPaint);
    final tagTp = TextPainter(
      text: TextSpan(
        text: fmtAxisPrice(lp),
        style: const TextStyle(
          color: Colors.black,
          fontSize: 10,
          fontFamily: 'Roboto',
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    axisPills.add((lp, Colors.white, Colors.black, true));
    // MetaTrader-style bid/ask lines: bid is the chart's price basis (drawn
    // above); ask gets its own line + right-axis tag when the BBO feed has it.
    final askP = ask;
    if (askP != null && askP.isFinite && askP > lo && askP < hi) {
      const askColor = Color(0xFFFF8A80);
      priceTag(askP, askColor, Colors.black);
    }

    // Render axis pills top-to-bottom, bumping overlaps down (last-price
    // pill keeps priority placement via stable order on ties).
    double lpBottom = -1, lpCenterX = 0;
    if (axisPills.isNotEmpty) {
      axisPills.sort((a, b) {
        final c = y(a.$1).compareTo(y(b.$1));
        return c != 0 ? c : (b.$4 ? 1 : 0) - (a.$4 ? 1 : 0);
      });
      var bottom = -1e9;
      for (final pill in axisPills) {
        final tp = TextPainter(
          text: TextSpan(
            text: fmtAxisPrice(pill.$1),
            style: TextStyle(
              color: pill.$3,
              fontSize: 10,
              fontFamily: 'Roboto',
              fontWeight: FontWeight.w700,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        var ty = y(pill.$1) - tp.height / 2 - 2;
        if (ty < bottom + 2) ty = bottom + 2;
        if (ty + tp.height + 4 > plotH) {
          ty = math.max(0.0, plotH - tp.height - 4);
        }
        final r = RRect.fromRectAndRadius(
          Rect.fromLTWH(plotW + 2, ty, tp.width + 8, tp.height + 4),
          const Radius.circular(3),
        );
        canvas.drawRRect(r, Paint()..color = pill.$2);
        tp.paint(canvas, Offset(plotW + 6, ty + 2));
        bottom = ty + tp.height + 4;
        if (pill.$4) {
          lpBottom = bottom;
          lpCenterX = plotW + 2 + (tp.width + 8) / 2;
        }
      }
    }
    if (showCountdown && lpBottom >= 0 && eff.length >= 2 && now != null) {
      final barMs = eff.last.time.millisecondsSinceEpoch -
          eff[eff.length - 2].time.millisecondsSinceEpoch;
      final remMs =
          eff.last.time.millisecondsSinceEpoch + barMs - now!.millisecondsSinceEpoch;
      if (barMs > 0 && remMs > 0) {
        final s = remMs ~/ 1000;
        final cdText = s >= 3600
            ? '${s ~/ 3600}:${((s % 3600) ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}'
            : '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';
        final cd = TextPainter(
          text: TextSpan(
            text: cdText,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontFamily: 'Roboto',
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        // Skip the countdown when the axis strip is too narrow to hold it
        // (inverted clamp range would throw).
        if (plotW + 2 <= size.width - cd.width && size.height >= cd.height) {
          final cx = (lpCenterX - cd.width / 2)
              .clamp(plotW + 2, size.width - cd.width);
          final cy = (lpBottom + 4).clamp(0.0, size.height - cd.height);
          cd.paint(canvas, Offset(cx, cy));
        }
      }
    }

    // user-drawn horizontal lines
    final hlPaint = Paint()
      ..color = const Color(0xFF5EE0A0)
      ..strokeWidth = 1;
    for (final l in hLines) {
      if (l.price < lo || l.price > hi) continue;
      final yy = y(l.price);
      canvas.drawLine(Offset(0, yy), Offset(plotW, yy), hlPaint);
      priceTag(l.price, const Color(0xFF5EE0A0), Colors.black);
    }

    // trend lines (anchored by candle time, extended to the plot edges)
    if (n >= 2 && (trendLines.isNotEmpty || pendingTrend != null)) {
      final tlPaint = Paint()
        ..color = const Color(0xFF6FD3E0)
        ..strokeWidth = 1.2;
      double idxAt(DateTime t) {
        final t0 = candles.first.time.millisecondsSinceEpoch;
        final tN = candles.last.time.millisecondsSinceEpoch;
        if (tN == t0) return 0;
        return (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
      }

      final stepT = plotW / vc0;
      void drawTrend(TrendLine l, bool dashed) {
        final x1 = stepT * (idxAt(l.t1) - fv0 + 0.5);
        final x2 = stepT * (idxAt(l.t2) - fv0 + 0.5);
        if ((x2 - x1).abs() < 1e-6) return;
        final y1 = y(l.p1), y2 = y(l.p2);
        final m = (y2 - y1) / (x2 - x1);
        final ya = y1 - m * x1; // y at x=0
        final yb = y1 + m * (plotW - x1); // y at x=plotW
        if (dashed) {
          double dx = 0;
          const dw = 6.0, gw = 4.0;
          final total = plotW;
          while (dx < total) {
            final xStart = dx;
            final xEnd = math.min(dx + dw, total);
            canvas.drawLine(
              Offset(xStart, ya + m * xStart),
              Offset(xEnd, ya + m * xEnd),
              tlPaint,
            );
            dx += dw + gw;
          }
        } else {
          canvas.drawLine(Offset(0, ya), Offset(plotW, yb), tlPaint);
        }
      }

      for (final l in trendLines) {
        drawTrend(l, false);
      }
      if (pendingTrend != null) {
        final p = pendingTrend!;
        final x = stepT * (idxAt(p.t1) - fv0 + 0.5);
        final py = y(p.p1);
        canvas.drawCircle(Offset(x, py), 3, tlPaint);
      }
    }

    // rectangle zones (teal, translucent fill)
    if (n >= 2 && (rects.isNotEmpty || pendingRect != null)) {
      final rBorder = Paint()
        ..color = const Color(0xFF6FD3E0)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      final rFill = Paint()..color = const Color(0x1A6FD3E0);
      final t0 = candles.first.time.millisecondsSinceEpoch;
      final tN = candles.last.time.millisecondsSinceEpoch;
      double rIdx(DateTime t) =>
          tN == t0 ? 0 : (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
      final stepR = plotW / vc0;
      void drawZone(TrendLine r) {
        final x1 = stepR * (rIdx(r.t1) - fv0 + 0.5);
        final x2 = stepR * (rIdx(r.t2) - fv0 + 0.5);
        final rect = Rect.fromLTRB(
          math.min(x1, x2),
          y(math.max(r.p1, r.p2)),
          math.max(x1, x2),
          y(math.min(r.p1, r.p2)),
        );
        canvas.drawRect(rect, rFill);
        canvas.drawRect(rect, rBorder);
      }

      for (final r in rects) {
        drawZone(r);
      }
      if (pendingRect != null) drawZone(pendingRect!);
    }

    // parallel channels (violet): main line extended, parallel offset dp,
    // translucent fill between the anchors
    if (n >= 2 && (channels.isNotEmpty || pendingChannel != null)) {
      final chPaint = Paint()
        ..color = const Color(0xFF9B8CFF)
        ..strokeWidth = 1.2;
      final chFill = Paint()..color = const Color(0x149B8CFF);
      final t0 = candles.first.time.millisecondsSinceEpoch;
      final tN = candles.last.time.millisecondsSinceEpoch;
      double cIdx(DateTime t) =>
          tN == t0 ? 0 : (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
      final stepC = plotW / vc0;
      void drawChannel(Channel ch, bool pending) {
        final x1 = stepC * (cIdx(ch.t1) - fv0 + 0.5);
        final x2 = stepC * (cIdx(ch.t2) - fv0 + 0.5);
        if ((x2 - x1).abs() < 1e-6) {
          canvas.drawCircle(Offset(x1, y(ch.p1)), 3, chPaint);
          return;
        }
        final y1 = y(ch.p1), y2 = y(ch.p2);
        final m = (y2 - y1) / (x2 - x1);
        final off = y(ch.p2 + ch.dp) - y(ch.p2);
        canvas.drawLine(
            Offset(0, y1 - m * x1), Offset(plotW, y1 + m * (plotW - x1)),
            chPaint);
        if (!pending || ch.dp != 0) {
          canvas.drawLine(
              Offset(0, y1 - m * x1 + off),
              Offset(plotW, y1 + m * (plotW - x1) + off),
              chPaint);
          if (ch.dp != 0) {
            final path = Path()
              ..moveTo(x1, y1)
              ..lineTo(x2, y2)
              ..lineTo(x2, y2 + off)
              ..lineTo(x1, y1 + off)
              ..close();
            canvas.drawPath(path, chFill);
          }
        }
      }

      for (final ch in channels) {
        drawChannel(ch, false);
      }
      if (pendingChannel != null) drawChannel(pendingChannel!, true);
    }

    // rulers (gold dashed + delta label)
    if (n >= 2 && (rulers.isNotEmpty || pendingRuler != null)) {
      final rPaint = Paint()
        ..color = const Color(0xFFF5C242)
        ..strokeWidth = 1.2;
      final t0 = candles.first.time.millisecondsSinceEpoch;
      final tN = candles.last.time.millisecondsSinceEpoch;
      double uIdx(DateTime t) =>
          tN == t0 ? 0 : (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
      final stepU = plotW / vc0;
      void drawRuler(TrendLine r, bool pending) {
        final x1 = stepU * (uIdx(r.t1) - fv0 + 0.5);
        final x2 = stepU * (uIdx(r.t2) - fv0 + 0.5);
        final y1 = y(r.p1), y2 = y(r.p2);
        // dashed segment
        final dx = x2 - x1, dy = y2 - y1;
        final len = math.sqrt(dx * dx + dy * dy);
        if (len < 2) {
          canvas.drawCircle(Offset(x1, y1), 3, rPaint);
          return;
        }
        final ux = dx / len, uy = dy / len;
        var d = 0.0;
        while (d < len) {
          final e = math.min(d + 6, len);
          canvas.drawLine(
            Offset(x1 + ux * d, y1 + uy * d),
            Offset(x1 + ux * e, y1 + uy * e),
            rPaint,
          );
          d = e + 4;
        }
        if (pending) return;
        final dp = r.p2 - r.p1;
        final pct = r.p1 != 0 ? dp / r.p1 * 100 : 0.0;
        final bars = (uIdx(r.t2) - uIdx(r.t1)).round().abs();
        final span = r.t2.difference(r.t1).abs();
        final spanTxt = span.inDays >= 1
            ? '${span.inDays}d ${span.inHours % 24}h'
            : '${span.inHours}h ${span.inMinutes % 60}m';
        final label =
            '${dp >= 0 ? '+' : ''}${dp.toStringAsFixed(2)} (${pct.toStringAsFixed(2)}%)  $bars bars  $spanTxt';
        final tp = TextPainter(
          text: TextSpan(
            text: label,
            style: const TextStyle(
              color: Color(0xFF0F1115),
              fontSize: 10,
              fontFamily: 'Roboto',
              height: 1,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        final mx = (x1 + x2) / 2, my = (y1 + y2) / 2;
        final bx = (mx - tp.width / 2 - 6).clamp(0.0, plotW - tp.width - 12);
        final by = (my - tp.height - 10).clamp(0.0, plotH - tp.height - 8);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(bx, by, tp.width + 12, tp.height + 8),
            const Radius.circular(4),
          ),
          Paint()..color = const Color(0xE6F5C242),
        );
        tp.paint(canvas, Offset(bx + 6, by + 4));
      }

      for (final r in rulers) {
        drawRuler(r, false);
      }
      if (pendingRuler != null) drawRuler(pendingRuler!, true);
    }

    // fibonacci retracements: horizontal levels between the two anchors,
    // extended right from the leftmost anchor
    if (n >= 2 && (fibs.isNotEmpty || pendingFib != null)) {
      const fibFs = [0.0, 0.236, 0.382, 0.5, 0.618, 0.786, 1.0];
      final fibPaint = Paint()
        ..color = const Color(0xCCFFD166)
        ..strokeWidth = 1;
      double idxAtF(DateTime t) {
        final t0 = candles.first.time.millisecondsSinceEpoch;
        final tN = candles.last.time.millisecondsSinceEpoch;
        if (tN == t0) return 0;
        return (t.millisecondsSinceEpoch - t0) / (tN - t0) * (n - 1);
      }

      final stepF = plotW / vc0;
      for (final f in fibs) {
        final xStart =
            stepF * (math.min(idxAtF(f.t1), idxAtF(f.t2)) - fv0 + 0.5);
        for (final frac in fibFs) {
          final price = f.p2 + (f.p1 - f.p2) * frac;
          if (price < lo || price > hi) continue;
          final yy = y(price);
          canvas.drawLine(Offset(xStart, yy), Offset(plotW, yy), fibPaint);
          final pct = (frac * 100);
          final label =
              '${pct == pct.roundToDouble() ? pct.toInt() : pct.toStringAsFixed(1)}% ${price.toStringAsFixed(2)}';
          final tp = TextPainter(
            text: TextSpan(
              text: label,
              style: const TextStyle(
                color: Color(0xCCFFD166),
                fontSize: 8,
                fontFamily: 'Roboto',
              ),
            ),
            textDirection: TextDirection.ltr,
          )..layout();
          tp.paint(canvas, Offset(plotW - tp.width - 2, yy - tp.height - 1));
        }
      }
      if (pendingFib != null) {
        final p = pendingFib!;
        final x = stepF * (idxAtF(p.t1) - fv0 + 0.5);
        canvas.drawCircle(Offset(x, y(p.p1)), 3, fibPaint);
      }
    }

    // RSI sub-pane
    if (rsiH > 0 && rsi != null) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, plotH + 8, plotW, rsiH));
      final top = plotH + 8;
      final h = rsiH - 8;
      final rp = Paint()..color = grid;
      canvas.drawRect(
        Rect.fromLTWH(0, top, plotW, h),
        rp..color = const Color(0xFF141923),
      );
      double ry(double v) => top + h * (1 - v / 100);
      final band = Paint()..color = const Color(0xFF232A35);
      canvas.drawLine(Offset(0, ry(70)), Offset(plotW, ry(70)), band);
      canvas.drawLine(Offset(0, ry(30)), Offset(plotW, ry(30)), band);
      final rPaint = Paint()
        ..color = const Color(0xFFB78CFF)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke;
      final path = Path();
      for (int i = 0; i < rsi!.length; i++) {
        final idx = rsiPeriod + i;
        if (idx >= n) break;
        final x = stepI * (idx - fv0 + 0.5);
        final yy = ry(rsi![i]);
        if (i == 0) {
          path.moveTo(x, yy);
        } else {
          path.lineTo(x, yy);
        }
      }
      canvas.drawPath(path, rPaint);
      final lbl = TextPainter(
        text: TextSpan(
          text: 'RSI ${rsi!.last.toStringAsFixed(1)}',
          style: const TextStyle(
            color: Color(0xFFB78CFF),
            fontSize: 9,
            fontFamily: 'Roboto',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      lbl.paint(canvas, Offset(4, top + 2));
      canvas.restore();
    }

    // time labels
    final tf = TextStyle(color: axis, fontSize: 9, fontFamily: 'Roboto');
    for (int t = 0; t < 4; t++) {
      final i = fv0 + ((vc0 - 1) * t / 3).round();
      final c = candles[i];
      final sameDay =
          c.time.day == candles.last.time.day &&
          c.time.month == candles.last.time.month;
      final s = sameDay
          ? '${c.time.hour.toString().padLeft(2, '0')}:${c.time.minute.toString().padLeft(2, '0')}'
          : '${c.time.month}/${c.time.day}';
      final tp = TextPainter(
        text: TextSpan(text: s, style: tf),
        textDirection: TextDirection.ltr,
      )..layout();
      final tx = (step * (i - fv0 + 0.5) - tp.width / 2).clamp(
        0.0,
        plotW - tp.width,
      );
      tp.paint(canvas, Offset(tx, plotH + 3));
    }

    // MACD sub-pane (histogram + line/signal, real closes only)
    if (macdH > 0) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, plotH + 8 + rsiH, plotW, macdH));
      final top = plotH + 8 + rsiH;
      final h = macdH - 8;
      canvas.drawRect(
        Rect.fromLTWH(0, top, plotW, h),
        Paint()..color = const Color(0xFF141923),
      );
      double mn = 0, mx = 0;
      void ext(List<double>? s) {
        if (s == null) return;
        for (final v in s) {
          if (v < mn) mn = v;
          if (v > mx) mx = v;
        }
      }

      ext(macdLine);
      ext(macdSignal);
      ext(macdHist);
      if (mx - mn < 1e-9) mx = mn + 1;
      double my(double v) => top + h * (1 - (v - mn) / (mx - mn));
      canvas.drawLine(
        Offset(0, my(0)),
        Offset(plotW, my(0)),
        Paint()..color = const Color(0xFF232A35),
      );
      final stepI = plotW / vc0;
      if (macdHist != null) {
        for (int i = 0; i < macdHist!.length; i++) {
          final idx = macdSlow + macdSignalPeriod - 2 + i;
          if (idx >= n) break;
          final x = stepI * (idx - fv0 + 0.5);
          final v = macdHist![i];
          final y0 = my(0), y1 = my(v);
          canvas.drawRect(
            Rect.fromLTRB(
              x - 1.5,
              y0 < y1 ? y0 : y1,
              x + 1.5,
              y0 > y1 ? y0 : y1,
            ),
            Paint()..color = v >= 0 ? bull : bear,
          );
        }
      }
      void mline(List<double> s, int off, Color c) {
        final paint = Paint()
          ..color = c
          ..strokeWidth = 1.1
          ..style = PaintingStyle.stroke;
        final path = Path();
        for (int i = 0; i < s.length; i++) {
          final idx = off + i;
          if (idx >= n) break;
          final x = stepI * (idx - fv0 + 0.5);
          if (i == 0) {
            path.moveTo(x, my(s[i]));
          } else {
            path.lineTo(x, my(s[i]));
          }
        }
        canvas.drawPath(path, paint);
      }

      mline(macdLine!, macdSlow - 1, const Color(0xFF4EA1FF));
      if (macdSignal != null && macdSignal!.isNotEmpty) {
        mline(
          macdSignal!,
          macdSlow + macdSignalPeriod - 2,
          const Color(0xFFFF9F43),
        );
      }
      final label = TextPainter(
        text: TextSpan(
          text: 'MACD ${macdLine!.last.toStringAsFixed(2)}',
          style: const TextStyle(
            color: axis,
            fontSize: 9,
            fontFamily: 'Roboto',
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      label.paint(canvas, Offset(4, top + 2));
      canvas.restore();
    }
  }

  @override
  bool shouldRepaint(CandlePainter old) =>
      old.chartStyle != chartStyle ||
      old.positions != positions ||
      old.macdSlow != macdSlow ||
      old.macdSignalPeriod != macdSignalPeriod ||
      old.firstVisible != firstVisible ||
      old.visibleCount != visibleCount ||
      old.macdLine != macdLine ||
      old.macdSignal != macdSignal ||
      old.macdHist != macdHist ||
      old.candles != candles ||
      old.livePrice != livePrice ||
      old.now != now ||
      old.showCountdown != showCountdown ||
      old.selected != selected ||
      old.extraEmas != extraEmas ||
      old.bands != bands ||
      old.sma != sma ||
      old.strategySegments != strategySegments ||
      old.ema != ema ||
      old.rsi != rsi ||
      old.hLines != hLines ||
      old.fibs != fibs ||
      old.pendingFib != pendingFib ||
      old.trendLines != trendLines ||
      old.pendingTrend != pendingTrend;
}

/// Fullscreen chart (user request): same real candle source and live
/// price, landscape while open, orientation restored on close.
class FullscreenChartPage extends StatefulWidget {
  final CandleLoader? loader;
  final ValueChanged<double>? onAlertPrice;
  final double? livePrice;
  final bool rangeMode;
  final Map<String, dynamic>? initialLayout;
  final Listenable? marketUpdates;
  final ChartMarketSnapshot Function()? marketSnapshot;
  final VoidCallback? onReplay;
  final bool replayOn;

  /// Floating SELL/BUY pills over the chart (broker reference): the page
  /// reports the side; the caller opens its order flow.
  final ValueChanged<String>? onTradeSide;
  const FullscreenChartPage({
    super.key,
    this.loader,
    this.onAlertPrice,
    this.onReplay,
    this.replayOn = false,
    this.onTradeSide,
    this.livePrice,
    this.rangeMode = false,
    this.initialLayout,
    this.marketUpdates,
    this.marketSnapshot,
  });

  @override
  State<FullscreenChartPage> createState() => _FullscreenChartPageState();
}

class _FullscreenChartPageState extends State<FullscreenChartPage> {
  final chartKey = GlobalKey<CandleChartPanelState>();
  Timer? _clockTimer;

  /// Named chart templates (indicators/style/view), stored on-device.
  Map<String, Map<String, dynamic>> _templates = {};

  bool get _isTest => Platform.environment.containsKey('FLUTTER_TEST');

  @override
  void initState() {
    super.initState();
    // Portrait editor (broker reference layout).
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
    ]);
    if (!_isTest) {
      _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() {});
      });
    }
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('sona_chart_templates');
      if (raw == null) return;
      final m = jsonDecode(raw) as Map<String, dynamic>;
      setState(() {
        _templates = m.map(
            (k, v) => MapEntry(k, Map<String, dynamic>.from(v as Map)));
      });
    } catch (_) {}
  }

  Future<void> _saveTemplates() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('sona_chart_templates', jsonEncode(_templates));
    } catch (_) {}
  }

  Future<void> _openTemplates() async {
    final st = chartKey.currentState;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDlg) => AlertDialog(
          backgroundColor: const Color(0xFF151A22),
          title: const Text('Templates',
              style: TextStyle(color: Colors.white, fontSize: 15)),
          content: SizedBox(
            width: 320,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  dense: true,
                  leading: const Icon(Icons.save_outlined,
                      color: Colors.white70),
                  title: const Text('Save current as template',
                      style: TextStyle(color: Colors.white)),
                  onTap: () async {
                    Navigator.of(ctx).pop();
                    await _saveTemplateAs();
                  },
                ),
                if (_templates.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'No saved templates yet. A template remembers the chart '
                      'style, indicators and zoom - not drawings.',
                      style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
                    ),
                  )
                else
                  for (final name in _templates.keys.toList())
                    ListTile(
                      dense: true,
                      title: Text(name,
                          style: const TextStyle(color: Colors.white)),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline,
                            color: Color(0xFFF27EA9), size: 20),
                        onPressed: () async {
                          _templates.remove(name);
                          await _saveTemplates();
                          setDlg(() {});
                          setState(() {});
                        },
                      ),
                      onTap: () {
                        final layout = _templates[name];
                        if (st != null && layout != null) {
                          st.applyPreset(Map<String, dynamic>.from(layout));
                        }
                        Navigator.of(ctx).pop();
                      },
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _saveTemplateAs() async {
    final st = chartKey.currentState;
    if (st == null) return;
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF151A22),
        title: const Text('Template name',
            style: TextStyle(color: Colors.white, fontSize: 15)),
        content: TextField(
          controller: controller,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: const InputDecoration(
            hintText: 'e.g. Scalp 5m EMA',
            hintStyle: TextStyle(color: Color(0xFF8A93A6)),
          ),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    _templates[name] = st.layoutSnapshot();
    await _saveTemplates();
    setState(() {});
  }

  @override
  void dispose() {
    _clockTimer?.cancel();
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  static const _dim = Color(0xFF8A93A6);
  static const _active = Color(0xFF2E5CFF);

  void _pop() {
    Navigator.of(context).pop(chartKey.currentState?.layoutSnapshot());
  }

  /// Exactly one drawing mode at a time (mirrors the toolbar chips).
  void _mode(void Function(CandleChartPanelState st) apply) {
    final st = chartKey.currentState;
    if (st == null) return;
    st.setState(() {
      st.alertMode = false;
      st.drawMode = false;
      st.trendMode = false;
      st.fibMode = false;
      st.rectMode = false;
      st.channelMode = false;
      st.rulerMode = false;
      apply(st);
    });
  }

  Widget _toolIcon(IconData icon,
      {bool active = false, bool enabled = true, VoidCallback? onTap}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(8),
        child: Container(
          width: 34,
          height: 34,
          decoration: BoxDecoration(
            color: active ? _active : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(
            icon,
            size: 19,
            color: !enabled
                ? _dim.withValues(alpha: 0.35)
                : active
                    ? Colors.white
                    : Colors.white70,
          ),
        ),
      ),
    );
  }

  String _clockText() {
    final now = _isTest ? DateTime(2026, 10, 7, 15, 40, 2) : DateTime.now();
    final off = now.timeZoneOffset;
    final sign = off.isNegative ? '-' : '+';
    final oh = off.abs().inHours, om = off.abs().inMinutes % 60;
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(now.hour)}:${two(now.minute)}:${two(now.second)} '
        'UTC$sign$oh${om == 0 ? '' : ':${two(om)}'}';
  }

  @override
  Widget build(BuildContext context) {
    const bg = Colors.black;
    return PopScope<Map<String, dynamic>>(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) _pop();
      },
      child: Scaffold(
        backgroundColor: bg,
        body: SafeArea(
          child: AnimatedBuilder(
            animation:
                widget.marketUpdates ?? const AlwaysStoppedAnimation(0),
            builder: (_, __) {
              final st = chartKey.currentState;
              if (st == null) {
                // The panel attaches after the first frame; rebuild once it
                // does so the timeframe label fills in.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (mounted) setState(() {});
                });
              }
              final snap = widget.marketSnapshot?.call();
              final bid = snap?.bid ?? widget.livePrice;
              final ask = snap?.ask ?? widget.livePrice;
              final spread =
                  (bid != null && ask != null) ? (ask - bid).abs() : null;
              return Column(
                children: [
                  // ---- top bar: X | symbol | search | layout ----
                  Padding(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: Row(
                      children: [
                        IconButton(
                          icon: const Icon(Icons.close, color: Colors.white),
                          onPressed: _pop,
                        ),
                        const Icon(Icons.widgets,
                            color: Color(0xFFF5C242), size: 18),
                        const SizedBox(width: 6),
                        const Text(
                          'GOLD',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Icon(Icons.keyboard_arrow_down,
                            color: Colors.white70),
                        const Spacer(),
                        const Icon(Icons.search,
                            color: Color(0x558A93A6)), // single instrument
                        const SizedBox(width: 14),
                        const Icon(Icons.space_dashboard_outlined,
                            color: Color(0x558A93A6)), // templates pending
                        const SizedBox(width: 6),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF1C2230)),
                  // ---- tool row ----
                  SizedBox(
                    height: 44,
                    child: Row(
                      children: [
                        const SizedBox(width: 8),
                        PopupMenuButton<String>(
                          onSelected: (code) {
                            final range = code.startsWith('range:');
                            st?.applyChartSelection(range: range, code: code);
                            setState(() {});
                          },
                          itemBuilder: (_) => [
                            for (final iv in intervals)
                              PopupMenuItem(value: iv.code, child: Text(iv.label)),
                            const PopupMenuDivider(),
                            for (final r in tradeRanges)
                              PopupMenuItem(value: r.code, child: Text(r.label)),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 8),
                            child: Text(
                              st?.interval.label ?? '',
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 13),
                            ),
                          ),
                        ),
                        _vr(),
                        IconButton(
                          icon: const Icon(Icons.candlestick_chart,
                              color: Colors.white70, size: 20),
                          onPressed: () => st?.cycleChartStyle(),
                        ),
                        _vr(),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.functions,
                              color: Colors.white70, size: 20),
                          onSelected: (v) {
                            if (st == null) return;
                            st.setState(() {
                              switch (v) {
                                case 'sma':
                                  st.smaOn = !st.smaOn;
                                case 'ema':
                                  st.emaOn = !st.emaOn;
                                case 'sma200':
                                  st.sma200On = !st.sma200On;
                                case 'rsi':
                                  st.rsiOn = !st.rsiOn;
                                case 'macd':
                                  st.macdOn = !st.macdOn;
                              }
                            });
                          },
                          itemBuilder: (_) => [
                            _indItem('sma', 'SMA 20', st?.smaOn),
                            _indItem('ema', 'EMA 50', st?.emaOn),
                            _indItem('sma200', 'SMA 200', st?.sma200On),
                            _indItem('rsi', 'RSI 14', st?.rsiOn),
                            _indItem('macd', 'MACD', st?.macdOn),
                          ],
                        ),
                        _vr(),
                        IconButton(
                          icon: const Icon(Icons.grid_view,
                              color: Colors.white70, size: 20),
                          onPressed: _openTemplates,
                        ),
                        _vr(),
                        const Icon(Icons.add, color: Color(0x558A93A6)),
                        _vr(),
                        IconButton(
                          icon: Icon(
                            Icons.undo,
                            size: 20,
                            color: st?.canUndo == true
                                ? Colors.white70
                                : const Color(0x558A93A6),
                          ),
                          onPressed: () {
                            st?.undo();
                            setState(() {});
                          },
                        ),
                        IconButton(
                          icon: Icon(
                            Icons.redo,
                            size: 20,
                            color: st?.canRedo == true
                                ? Colors.white70
                                : const Color(0x558A93A6),
                          ),
                          onPressed: () {
                            st?.redo();
                            setState(() {});
                          },
                        ),
                        const Spacer(),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF1C2230)),
                  // ---- chart + left toolbar ----
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Container(
                          width: 46,
                          decoration: const BoxDecoration(
                            border: Border(
                              right:
                                  BorderSide(color: Color(0xFF1C2230)),
                            ),
                          ),
                          child: SingleChildScrollView(
                            child: Column(
                              children: [
                                const SizedBox(height: 4),
                                _toolIcon(Icons.add,
                                    active: st?.crosshairMode == true,
                                    onTap: () => st?.setState(() =>
                                        st.crosshairMode =
                                            !st.crosshairMode)),
                                _toolIcon(Icons.show_chart,
                                    active: st?.trendMode == true,
                                    onTap: () =>
                                        _mode((s) => s.trendMode = true)),
                                _toolIcon(Icons.multiline_chart,
                                    active: st?.channelMode == true,
                                    onTap: () =>
                                        _mode((s) => s.channelMode = true)),
                                _toolIcon(Icons.crop_square,
                                    active: st?.rectMode == true,
                                    onTap: () =>
                                        _mode((s) => s.rectMode = true)),
                                _toolIcon(Icons.percent,
                                    active: st?.fibMode == true,
                                    onTap: () =>
                                        _mode((s) => s.fibMode = true)),
                                _toolIcon(Icons.brush,
                                    active: st?.drawMode == true,
                                    onTap: () =>
                                        _mode((s) => s.drawMode = true)),
                                _toolIcon(Icons.text_fields, enabled: false),
                                _toolIcon(Icons.emoji_emotions_outlined,
                                    enabled: false),
                                const Divider(
                                    color: Color(0xFF1C2230), height: 14),
                                _toolIcon(Icons.straighten,
                                    active: st?.rulerMode == true,
                                    onTap: () =>
                                        _mode((s) => s.rulerMode = true)),
                                _toolIcon(Icons.zoom_in, enabled: false),
                                const Divider(
                                    color: Color(0xFF1C2230), height: 14),
                                _toolIcon(Icons.vertical_align_center,
                                    active: st?.magnetOn == true,
                                    onTap: () => st?.setState(
                                        () => st.magnetOn = !st.magnetOn)),
                                _toolIcon(Icons.lock_outline, enabled: false),
                                _toolIcon(Icons.remove_red_eye_outlined,
                                    enabled: false),
                                _toolIcon(Icons.add_alert,
                                    active: st?.alertMode == true,
                                    onTap: () =>
                                        _mode((s) => s.alertMode = true)),
                                if (widget.onReplay != null)
                                  _toolIcon(Icons.play_circle_outline,
                                      active: widget.replayOn,
                                      onTap: widget.onReplay),
                                _toolIcon(Icons.delete_outline,
                                    onTap: () =>
                                        st?.clearDrawingsConfirmed()),
                                const SizedBox(height: 4),
                              ],
                            ),
                          ),
                        ),
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: CandleChartPanel(
                                  key: chartKey,
                                  initialLayout: widget.initialLayout,
                                  marketUpdates: widget.marketUpdates,
                                  marketSnapshot: widget.marketSnapshot,
                                  loader: widget.loader,
                                  onAlertPrice: widget.onAlertPrice,
                                  onReplay: widget.onReplay,
                                  replayOn: widget.replayOn,
                                  livePrice: widget.livePrice,
                                  expand: true,
                                  chromeless: true,
                                  rangeMode: widget.rangeMode,
                                ),
                              ),
                              // symbol + price overlay
                              Positioned(
                                top: 8,
                                left: 10,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'GOLD · ${st?.interval.label ?? ''}',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                    if (widget.livePrice != null)
                                      _changeLine(st),
                                  ],
                                ),
                              ),
                              // floating SELL/BUY pills
                              if (widget.onTradeSide != null &&
                                  bid != null &&
                                  ask != null)
                                Positioned(
                                  top: 56,
                                  left: 10,
                                  child: Row(
                                    children: [
                                      _tradePill('SELL', bid,
                                          const Color(0xFFE5486C)),
                                      if (spread != null)
                                        Padding(
                                          padding: const EdgeInsets
                                              .symmetric(horizontal: 8),
                                          child: Text(
                                            spread.toStringAsFixed(2),
                                            style: const TextStyle(
                                                color: Colors.white70,
                                                fontSize: 12),
                                          ),
                                        ),
                                      _tradePill('BUY', ask,
                                          const Color(0xFF26A69A)),
                                    ],
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Divider(height: 1, color: Color(0xFF1C2230)),
                  // ---- bottom bar: Date Range | clock | auto ----
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        const SizedBox(width: 10),
                        const Icon(Icons.star_border,
                            color: Color(0x558A93A6), size: 20),
                        const SizedBox(width: 10),
                        PopupMenuButton<String>(
                          onSelected: (code) {
                            st?.applyChartSelection(range: true, code: code);
                            setState(() {});
                          },
                          itemBuilder: (_) => [
                            for (final r in tradeRanges)
                              PopupMenuItem(
                                  value: r.code, child: Text(r.label)),
                          ],
                          child: const Row(
                            children: [
                              Text('Date Range',
                                  style: TextStyle(
                                      color: Colors.white70, fontSize: 13)),
                              Icon(Icons.arrow_drop_down,
                                  color: Colors.white70),
                            ],
                          ),
                        ),
                        const Spacer(),
                        Text(
                          _clockText(),
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13),
                        ),
                        const Spacer(),
                        const Text('auto',
                            style: TextStyle(
                                color: Colors.white70, fontSize: 13)),
                        const SizedBox(width: 10),
                        const Icon(Icons.settings_outlined,
                            color: Color(0x558A93A6), size: 20),
                        const SizedBox(width: 12),
                      ],
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _vr() =>
      const VerticalDivider(width: 12, color: Color(0xFF1C2230));

  /// Reference-style change figure: price, then +/- change and percent
  /// against the first bar of the last candle's UTC day.
  Widget _changeLine(CandleChartPanelState? st) {
    final px = widget.livePrice!;
    double? open;
    final cs = st?.candles;
    if (cs != null && cs.isNotEmpty) {
      final lastDay = cs.last.time.toUtc();
      final dayStart =
          DateTime.utc(lastDay.year, lastDay.month, lastDay.day);
      for (final c in cs.reversed) {
        if (c.time.toUtc().isBefore(dayStart)) break;
        open = c.open;
      }
    }
    final chg = open == null ? null : px - open;
    final pct = open == null || open == 0 ? null : chg! / open * 100;
    final up = (chg ?? 0) >= 0;
    final color =
        chg == null ? const Color(0xFF26A69A) : (up ? const Color(0xFF26A69A) : const Color(0xFFEF5350));
    return Row(
      children: [
        Text(
          CandlePainter.fmtAxisPrice(px),
          style: TextStyle(color: color, fontSize: 12),
        ),
        if (chg != null && pct != null) ...[
          const SizedBox(width: 6),
          Text(
            '${up ? '+' : ''}${chg.toStringAsFixed(2)} '
            '(${up ? '+' : ''}${pct.toStringAsFixed(2)}%)',
            style: TextStyle(color: color, fontSize: 12),
          ),
        ],
      ],
    );
  }

  PopupMenuItem<String> _indItem(String v, String label, bool? on) =>
      PopupMenuItem(
        value: v,
        child: Row(
          children: [
            Icon(on == true ? Icons.check_box : Icons.check_box_outline_blank,
                size: 18, color: on == true ? Colors.tealAccent : _dim),
            const SizedBox(width: 8),
            Text(label),
          ],
        ),
      );

  Widget _tradePill(String side, double price, Color color) {
    return Material(
      color: color,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () {
          _pop();
          widget.onTradeSide!(side.toLowerCase());
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          child: Column(
            children: [
              Text(
                CandlePainter.fmtAxisPrice(price),
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
                ),
              ),
              Text(
                side,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

(String, int) tradeRangeSpec(String code) => switch (code) {
  'range:1H' => ('1min', 120),
  'range:1D' => ('15min', 120),
  'range:1W' => ('1h', 200),
  'range:1M' => ('4h', 200),
  'range:3M' => ('1day', 120),
  'range:1Y' => ('1day', 400),
  _ => (code, 120),
};
Duration tradeRangeDuration(String code) => switch (code) {
  'range:1H' => const Duration(hours: 1),
  'range:1D' => const Duration(days: 1),
  'range:1W' => const Duration(days: 7),
  'range:1M' => const Duration(days: 30),
  'range:3M' => const Duration(days: 90),
  'range:1Y' => const Duration(days: 365),
  _ => const Duration(days: 1),
};
List<Candle> trimTradeRange(List<Candle> data, String code) {
  // Candle intervals describe bar spacing, not a history window. Preserve the
  // provider's full history for indicator warmup; only explicit ranges trim.
  if (!code.startsWith('range:') || data.isEmpty) return data;
  final from = data.last.time.subtract(tradeRangeDuration(code));
  return data.where((c) => !c.time.isBefore(from)).toList();
}
