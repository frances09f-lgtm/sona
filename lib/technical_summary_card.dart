import 'dart:async';
import 'package:flutter/material.dart';
import 'market_data/market_data_config.dart';
import 'market_data/models.dart';
import 'market_data/twelve_data_candles.dart';
import 'technical_gauge.dart';
import 'technical_summary.dart';

/// "Technical summary" card (user request, 2026-10-30): a Strong sell ->
/// Strong buy gauge like his reference screenshot, computed by Sona from
/// its own candle data. His choices: analysis timeframe 15 minutes (chips
/// allow comparing 1H and 1D), placed in the AI tab, refreshed about every
/// 5 minutes while the tab is open.
///
/// Provenance and freshness are always on the card: the rating is computed
/// from Twelve Data XAU/USD candles and labeled with the LATEST CANDLE's
/// time, never just the fetch time. A feed failure shows DISCONNECTED; a
/// market that is closed/quiet (weekend or nightly break) shows that
/// instead - the two are never conflated, and nothing is faked. This is
/// context from chart data, not a trade signal or financial advice.
class TechnicalSummaryCard extends StatefulWidget {
  const TechnicalSummaryCard({super.key});

  @override
  State<TechnicalSummaryCard> createState() => _TechnicalSummaryCardState();
}

class _TechnicalSummaryCardState extends State<TechnicalSummaryCard>
    with WidgetsBindingObserver {
  /// Analysis timeframe options (chip label -> provider interval). The
  /// 15-minute default is the user's explicit pick; the refresh cadence
  /// (about every 5 minutes) is separate and applies to whichever
  /// timeframe is selected.
  static const _intervals = <String, String>{
    '15m': '15min',
    '1H': '1h',
    '1D': '1day',
  };
  static const _intervalSpan = <String, Duration>{
    '15min': Duration(minutes: 15),
    '1h': Duration(hours: 1),
    '1day': Duration(days: 1),
  };

  String _chip = '15m';
  TechnicalSummary? _summary;

  /// Time of the latest candle the summary was computed from (device-local,
  /// converted by the candle service). Drives the "as of" label.
  DateTime? _asOf;
  String? _error; // feed failed: DISCONNECTED
  bool _marketQuiet = false; // market closed/quiet: distinct from _error
  bool _loading = false;
  Timer? _timer;

  /// Short per-timeframe cache so flipping chips inside one refresh window
  /// does not spend extra Twelve Data credits (free plan: 8/min, 800/day,
  /// shared with the chart, AI brain and backtests).
  final Map<String, (TechnicalSummary, DateTime, DateTime)> _cache = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _startTimer();
    _refresh();
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // No background polling: the gauge refreshes only while the app is
    // foregrounded. A paused app shows its last computed read with its
    // "as of" time until reopened.
    if (state == AppLifecycleState.resumed) {
      _startTimer();
      _refresh();
    } else if (state == AppLifecycleState.paused) {
      _timer?.cancel();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(minutes: 5), (_) => _refresh());
  }

  Future<void> _refresh({bool force = false}) async {
    final interval = _intervals[_chip]!;
    if (MarketDataConfig.apiKey.isEmpty) {
      setState(() {
        _summary = null;
        _error = null;
        _marketQuiet = false;
      });
      return;
    }
    if (!force) {
      final hit = _cache[interval];
      if (hit != null &&
          DateTime.now().difference(hit.$3) < const Duration(minutes: 5)) {
        setState(() {
          _summary = hit.$1;
          _asOf = hit.$2;
          _error = null;
          _marketQuiet = _isQuiet(interval, hit.$2);
        });
        return;
      }
    }
    if (_loading) return;
    setState(() => _loading = true);
    try {
      final candles = await TwelveDataCandleService(
        apiKey: MarketDataConfig.apiKey,
      ).fetchCandles(Instrument.xauUsd, interval: interval, limit: 250);
      final summary = computeTechnicalSummary(candles);
      final asOf = candles.last.time;
      _cache[interval] = (summary, asOf, DateTime.now());
      if (mounted) {
        setState(() {
          _summary = summary;
          _asOf = asOf;
          _error = null;
          _marketQuiet = _isQuiet(interval, asOf);
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _summary == null
              ? 'DISCONNECTED - could not load candles.'
              : 'DISCONNECTED - could not load candles. Showing the last read.';
          _marketQuiet = false;
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Market closed or feed quiet: weekend (gold is closed Fri evening to
  /// Sun evening UTC) or the latest candle is older than three timeframe
  /// spans while a feed failure has NOT occurred (that is DISCONNECTED).
  bool _isQuiet(String interval, DateTime asOf) {
    final utc = DateTime.now().toUtc();
    if (utc.weekday == DateTime.saturday || utc.weekday == DateTime.sunday) {
      return true;
    }
    final span = _intervalSpan[interval] ?? const Duration(minutes: 15);
    return DateTime.now().difference(asOf) > span * 3;
  }

  String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    const dim = Color(0xFF8A93A5);
    final keyMissing = MarketDataConfig.apiKey.isEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.speed, color: dim, size: 20),
            const SizedBox(width: 8),
            const Expanded(
              child: Text(
                'Technical summary',
                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 15),
              ),
            ),
            if (_loading)
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
          ],
        ),
        const SizedBox(height: 4),
        const Text(
          "Sona's own indicator read of XAU/USD candles - not TradingView's "
          'rating. Context from chart data, not a trade signal or financial advice.',
          style: TextStyle(color: dim, fontSize: 12),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            for (final chip in _intervals.keys) ...[
              ChoiceChip(
                label: Text(chip),
                selected: _chip == chip,
                onSelected: (_) {
                  setState(() => _chip = chip);
                  _refresh();
                },
              ),
              const SizedBox(width: 8),
            ],
          ],
        ),
        const SizedBox(height: 10),
        if (keyMissing)
          const Text(
            'Add your Twelve Data key in API settings to load the summary.',
            style: TextStyle(color: dim, fontSize: 12),
          )
        else ...[
          if (_summary != null && _summary!.insufficientReason == null) ...[
            Center(
              child: TechnicalGauge(
                rating: _summary!.rating,
                score: _summary!.score,
              ),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                'Buy ${_summary!.buyCount}  ·  Neutral ${_summary!.neutralCount}  ·  Sell ${_summary!.sellCount}',
                style: const TextStyle(color: dim, fontSize: 12),
              ),
            ),
          ] else if (_summary?.insufficientReason != null)
            Text(
              'Not enough candles yet: ${_summary!.insufficientReason}',
              style: const TextStyle(color: dim, fontSize: 12),
            )
          else if (_error == null)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
          const SizedBox(height: 8),
          if (_error != null)
            Text(
              _error!,
              style: const TextStyle(color: Color(0xFFFF5A5F), fontSize: 12),
            )
          else if (_marketQuiet)
            Text(
              'Market closed or quiet - showing the last read${_asOf != null ? ' from ${_fmtTime(_asOf!)}' : ''}.',
              style: const TextStyle(color: Color(0xFFF5C242), fontSize: 12),
            ),
          if (_asOf != null)
            Text(
              'From Twelve Data XAU/USD $_chip candles - as of ${_fmtTime(_asOf!)}. '
              'Refreshes about every 5 min while this tab is open.',
              style: const TextStyle(color: dim, fontSize: 11),
            ),
        ],
      ],
    );
  }
}
