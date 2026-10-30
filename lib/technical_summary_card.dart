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
/// time and whether that candle is still forming or completed - never the
/// fetch time. A feed failure shows DISCONNECTED with the provider's own
/// message (including quota errors); a market that is closed/quiet
/// (weekend or nightly break) shows that instead - the two are never
/// conflated, and nothing is faked. This is context from chart data, not
/// a trade signal or financial advice.
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
  static const _intervals = TechnicalSummaryCardView.intervals;

  String _chip = '15m';
  TechnicalSummary? _summary;

  /// Time of the latest candle the summary was computed from (device-local,
  /// converted by the candle service). Drives the "as of" label.
  DateTime? _asOf;
  String? _error; // feed failed: DISCONNECTED, provider message included
  bool _marketQuiet = false; // market closed/quiet: distinct from _error
  bool _loading = false;
  Timer? _timer;

  /// Short per-timeframe cache so flipping chips inside one refresh window
  /// does not spend extra Twelve Data credits. The free plan's daily and
  /// per-minute credit budget is shared with the chart, AI brain, advice
  /// and backtests, and this card does not know their usage - so it keeps
  /// its own requests to one per refresh per timeframe and shows quota
  /// errors honestly when the shared budget runs out.
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
          final msg =
              e.toString().replaceFirst('MarketDataException: ', '');
          _error = _summary == null
              ? 'DISCONNECTED - $msg'
              : 'DISCONNECTED - $msg Showing the last read.';
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
    final span = TechnicalSummaryCardView.intervalSpan[interval] ??
        const Duration(minutes: 15);
    return DateTime.now().difference(asOf) > span * 3;
  }

  @override
  Widget build(BuildContext context) {
    return TechnicalSummaryCardView(
      chip: _chip,
      summary: _summary,
      asOf: _asOf,
      error: _error,
      marketQuiet: _marketQuiet,
      loading: _loading,
      keyMissing: MarketDataConfig.apiKey.isEmpty,
      onChipSelected: (chip) {
        setState(() => _chip = chip);
        _refresh();
      },
    );
  }
}

/// Pure presentation for the technical summary card: same widget the
/// stateful fetcher uses, rendered here with explicit state so tests can
/// capture exactly what the card shows in each situation.
class TechnicalSummaryCardView extends StatelessWidget {
  static const intervals = <String, String>{
    '15m': '15min',
    '1H': '1h',
    '1D': '1day',
  };
  static const intervalSpan = <String, Duration>{
    '15min': Duration(minutes: 15),
    '1h': Duration(hours: 1),
    '1day': Duration(days: 1),
  };

  final String chip;
  final TechnicalSummary? summary;
  final DateTime? asOf;
  final String? error;
  final bool marketQuiet;
  final bool loading;
  final bool keyMissing;
  final ValueChanged<String>? onChipSelected;

  /// Current time injection point for tests; defaults to DateTime.now().
  final DateTime Function() now;

  const TechnicalSummaryCardView({
    super.key,
    required this.chip,
    this.summary,
    this.asOf,
    this.error,
    this.marketQuiet = false,
    this.loading = false,
    this.keyMissing = false,
    this.onChipSelected,
    this.now = DateTime.now,
  });

  static String _fmtTime(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    const dim = Color(0xFF8A93A5);
    final s = summary;
    // Latest candle completed or still forming: a candle starting at asOf
    // closes at asOf + span; before that the read is on a forming candle.
    final span = intervalSpan[intervals[chip]] ?? const Duration(minutes: 15);
    final forming = asOf != null && now().isBefore(asOf!.add(span));
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
            if (loading)
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
            for (final c in intervals.keys) ...[
              ChoiceChip(
                label: Text(c),
                selected: chip == c,
                onSelected:
                    onChipSelected == null ? null : (_) => onChipSelected!(c),
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
          if (s != null && s.insufficientReason == null) ...[
            Center(
              child: TechnicalGauge(rating: s.rating, score: s.score),
            ),
            const SizedBox(height: 6),
            Center(
              child: Text(
                'Buy ${s.buyCount}  ·  Neutral ${s.neutralCount}  ·  Sell ${s.sellCount}',
                style: const TextStyle(color: dim, fontSize: 12),
              ),
            ),
            Center(
              child: Text(
                'Based on ${s.buyCount + s.sellCount + s.neutralCount} of '
                '$kTechSummaryMaxIndicators indicators'
                '${s.skippedCount > 0 ? ' - ${s.skippedCount} long-period average(s) need more candles' : ''}',
                style: const TextStyle(color: dim, fontSize: 11),
              ),
            ),
          ] else if (s?.insufficientReason != null)
            Text(
              'Not enough candles yet: ${s!.insufficientReason}',
              style: const TextStyle(color: dim, fontSize: 12),
            )
          else if (error == null)
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
          if (error != null)
            Text(
              error!,
              style: const TextStyle(color: Color(0xFFFF5A5F), fontSize: 12),
            )
          else if (marketQuiet)
            Text(
              'Market closed or quiet - showing the last read${asOf != null ? ' from ${_fmtTime(asOf!)}' : ''}.',
              style: const TextStyle(color: Color(0xFFF5C242), fontSize: 12),
            ),
          if (asOf != null)
            Text(
              'From Twelve Data XAU/USD $chip candles - latest candle '
              '${_fmtTime(asOf!)} (${forming ? 'still forming' : 'completed'}). '
              'Refreshes about every 5 min while this tab is open.',
              style: const TextStyle(color: dim, fontSize: 11),
            ),
        ],
      ],
    );
  }
}
