import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'market_data/market_data_config.dart';
import 'market_data/models.dart';
import 'market_data/twelve_data_candles.dart';

const _kBg = Color(0xFF0F1115);
const _kCard = Color(0xFF171A21);
const _kBorder = Color(0xFF232834);
const _kDim = Color(0xFF8A93A5);
const _kGreen = Color(0xFF2ECC71);
const _kRed = Color(0xFFFF5A5F);
const _kGold = Color(0xFFF5C242);

/// Replay speeds in candles per second (user chose 1x/2x/5x).
const practiceSpeeds = [1, 2, 5];
const practiceWindow = 60; // candles shown before the stop
const practiceHorizon = 5; // hidden candles that decide the round

enum PracticeOutcome { correct, wrong, flat }

/// A flat close scores nothing - it is not a wrong pick.
PracticeOutcome practiceOutcome(String pick, double entry, double exit) {
  final move = exit - entry;
  if (move == 0) return PracticeOutcome.flat;
  final wentUp = move > 0;
  final pickedUp = pick == 'up';
  return wentUp == pickedUp ? PracticeOutcome.correct : PracticeOutcome.wrong;
}

/// Random stop index: at least [window] candles visible before it and at
/// least [horizon] candles hidden after it. Null when history is too short.
int? practicePauseIndex(
  int length,
  Random rng, {
  int window = practiceWindow,
  int horizon = practiceHorizon,
}) {
  final max = length - horizon; // pause-1+horizon must stay in range
  if (max < window) return null;
  return window + rng.nextInt(max - window + 1);
}

/// Practice mode: replays real historical XAU/USD 15-minute candles fast,
/// stops on its own and asks up or down. Pure training - it never touches
/// the paper balance, positions, orders or the AI.
class PracticeScreen extends StatefulWidget {
  /// Injectable for tests; defaults to the app's own candle service.
  final Future<List<Candle>> Function()? loadCandles;

  /// Injectable for tests: fixed seed makes the random stop deterministic.
  final int? randomSeed;

  const PracticeScreen({super.key, this.loadCandles, this.randomSeed});

  @override
  State<PracticeScreen> createState() => _PracticeScreenState();
}

enum _Phase { idle, replaying, question, revealing, result }

class _PracticeScreenState extends State<PracticeScreen> {
  late final _rng = Random(widget.randomSeed);
  Timer? _timer;

  List<Candle>? _candles;
  String? _error;
  bool _loading = true;

  _Phase _phase = _Phase.idle;
  int _pause = 0;
  int _shown = 0;
  int _speed = 5;
  PracticeOutcome? _verdict;
  double _move = 0;

  int _right = 0;
  int _total = 0;
  int _streak = 0;
  int _best = 0;

  @override
  void initState() {
    super.initState();
    _load();
    SharedPreferences.getInstance().then((p) {
      final b = p.getInt('practice_best_streak') ?? 0;
      if (mounted && b != _best) setState(() => _best = b);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final loader = widget.loadCandles ??
          () => TwelveDataCandleService(apiKey: MarketDataConfig.apiKey)
              .fetchCandles(Instrument.xauUsd, interval: '15min', limit: 300);
      final cs = await loader();
      if (!mounted) return;
      setState(() {
        _candles = cs;
        _loading = false;
        _phase = _Phase.idle;
        _shown = 0;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  void _startRound() {
    final cs = _candles;
    if (cs == null) return;
    final pause = practicePauseIndex(cs.length, _rng);
    if (pause == null) {
      setState(() => _error =
          'Not enough candle history for a practice round (${cs.length} candles).');
      return;
    }
    _timer?.cancel();
    setState(() {
      _pause = pause;
      _shown = 0;
      _verdict = null;
      _phase = _Phase.replaying;
    });
    final ms = max(40, 1000 ~/ _speed);
    _timer = Timer.periodic(Duration(milliseconds: ms), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        _shown++;
        if (_shown >= practiceWindow) {
          t.cancel();
          _phase = _Phase.question;
        }
      });
    });
  }

  void _answer(String pick) {
    if (_phase != _Phase.question) return;
    setState(() => _phase = _Phase.revealing);
    _timer = Timer.periodic(const Duration(milliseconds: 350), (t) {
      if (!mounted) return t.cancel();
      setState(() {
        _shown++;
        if (_shown >= practiceWindow + practiceHorizon) {
          t.cancel();
          final cs = _candles!;
          final entry = cs[_pause - 1].close;
          final exit = cs[_pause - 1 + practiceHorizon].close;
          _move = exit - entry;
          _verdict = practiceOutcome(pick, entry, exit);
          if (_verdict != PracticeOutcome.flat) {
            _total++;
            if (_verdict == PracticeOutcome.correct) {
              _right++;
              _streak++;
              if (_streak > _best) {
                _best = _streak;
                SharedPreferences.getInstance().then(
                    (p) => p.setInt('practice_best_streak', _best));
              }
            } else {
              _streak = 0;
            }
          }
          _phase = _Phase.result;
        }
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _kBg,
      appBar: AppBar(
        backgroundColor: _kBg,
        elevation: 0,
        title: const Row(
          children: [
            _Badge(),
            SizedBox(width: 8),
            Text('XAU/USD · 15m', style: TextStyle(fontSize: 14)),
          ],
        ),
        actions: [
          Center(
            child: Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Text(
                'Score $_right/$_total'
                '${_streak > 1 ? ' · streak $_streak' : ''}'
                '${_best > 1 ? ' · best $_best' : ''}',
                style: const TextStyle(color: _kDim, fontSize: 12),
              ),
            ),
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : _error != null
                  ? _ErrorState(message: _error!, onRetry: _load)
                  : _buildReady(),
        ),
      ),
    );
  }

  Widget _buildReady() {
    final cs = _candles!;
    final start = _pause - practiceWindow;
    final visible = _phase == _Phase.idle
        ? const <Candle>[]
        : cs.sublist(start, start + _shown);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: _kBg,
              border: Border.all(color: _kBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Stack(
              children: [
                Positioned.fill(
                  child: CustomPaint(
                    painter: _PracticeChartPainter(
                      visible,
                      markLast: _phase != _Phase.idle,
                    ),
                  ),
                ),
                if (_phase == _Phase.idle)
                  const Center(
                    child: Text(
                      'Press Start replay',
                      style: TextStyle(color: _kDim),
                    ),
                  ),
                if (_phase == _Phase.question)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _AskBar(
                      onUp: () => _answer('up'),
                      onDown: () => _answer('down'),
                    ),
                  ),
                if (_phase == _Phase.result && _verdict != null)
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: _ResultBar(outcome: _verdict!, move: _move),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: _kGold,
                foregroundColor: const Color(0xFF10182A),
                minimumSize: const Size(120, 44),
              ),
              onPressed:
                  _phase == _Phase.replaying || _phase == _Phase.revealing
                      ? null
                      : _startRound,
              child: Text(
                _phase == _Phase.idle
                    ? 'Start replay'
                    : (_phase == _Phase.replaying ||
                            _phase == _Phase.revealing)
                        ? 'Replaying...'
                        : 'New round',
              ),
            ),
            const Spacer(),
            for (final s in practiceSpeeds)
              Padding(
                padding: const EdgeInsets.only(left: 4),
                child: _SpeedChip(
                  label: '${s}x',
                  selected: _speed == s,
                  onTap: () => setState(() => _speed = s),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        const Text(
          'Real historical candles replayed offline for practice. The '
          'candles after the stop stay hidden until you answer. No '
          'connection to your paper balance, positions or orders - '
          'scores are training feedback, not a signal.',
          style: TextStyle(color: _kDim, fontSize: 12),
        ),
      ],
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge();
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: _kGold,
          borderRadius: BorderRadius.circular(4),
        ),
        child: const Text(
          'PRACTICE',
          style: TextStyle(
            color: Color(0xFF10182A),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.8,
          ),
        ),
      );
}

class _AskBar extends StatelessWidget {
  final VoidCallback onUp;
  final VoidCallback onDown;
  const _AskBar({required this.onUp, required this.onDown});
  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
        decoration: const BoxDecoration(
          color: Color(0xF00F1115),
          border: Border(top: BorderSide(color: _kBorder)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'Up or down from here?',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _AnswerButton(label: 'UP', color: _kGreen, onTap: onUp),
                const SizedBox(width: 10),
                _AnswerButton(label: 'DOWN', color: _kRed, onTap: onDown),
              ],
            ),
          ],
        ),
      );
}

class _ResultBar extends StatelessWidget {
  final PracticeOutcome outcome;
  final double move;
  const _ResultBar({required this.outcome, required this.move});
  @override
  Widget build(BuildContext context) {
    final flat = outcome == PracticeOutcome.flat;
    final ok = outcome == PracticeOutcome.correct;
    final text = flat
        ? 'Flat - price unchanged over the next $practiceHorizon candles, round not scored'
        : '${ok ? 'Correct' : 'Wrong'} - it moved '
            '${move >= 0 ? '+' : ''}${move.toStringAsFixed(2)} USD/oz '
            'over the next $practiceHorizon candles';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
      decoration: const BoxDecoration(
        color: Color(0xF00F1115),
        border: Border(top: BorderSide(color: _kBorder)),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: TextStyle(
          color: flat ? _kDim : (ok ? _kGreen : _kRed),
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _AnswerButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;
  const _AnswerButton(
      {required this.label, required this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: color,
          foregroundColor:
              color == _kGreen ? const Color(0xFF10182A) : Colors.white,
          minimumSize: const Size(110, 44),
        ),
        onPressed: onTap,
        child: Text(label, style: const TextStyle(fontWeight: FontWeight.w700)),
      );
}

class _SpeedChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _SpeedChip(
      {required this.label, required this.selected, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          constraints: const BoxConstraints(minHeight: 44, minWidth: 40),
          alignment: Alignment.center,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF1B2440) : _kCard,
            border: Border.all(color: selected ? _kGold : _kBorder),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: selected ? _kGold : _kDim,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});
  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, color: _kDim, size: 40),
            const SizedBox(height: 12),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(color: _kDim),
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: onRetry, child: const Text('Retry')),
          ],
        ),
      );
}

class _PracticeChartPainter extends CustomPainter {
  final List<Candle> candles;
  final bool markLast;
  _PracticeChartPainter(this.candles, {required this.markLast});

  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()..color = _kBg;
    canvas.drawRect(Offset.zero & size, bg);
    if (candles.isEmpty) return;

    const padL = 8.0, padR = 64.0, padT = 14.0, padB = 22.0;
    final cw = size.width - padL - padR;
    final ch = size.height - padT - padB;
    var lo = double.infinity, hi = -double.infinity;
    for (final c in candles) {
      if (c.low < lo) lo = c.low;
      if (c.high > hi) hi = c.high;
    }
    final rng = (hi - lo) == 0 ? 1.0 : (hi - lo);
    double y(double p) => padT + ch * (1 - (p - lo) / rng);

    final grid = Paint()
      ..color = _kBorder
      ..strokeWidth = 1;
    const labelStyle = TextStyle(
        color: _kDim, fontSize: 11, fontFamily: 'Roboto');
    for (var i = 1; i < 5; i++) {
      final gy = padT + ch * i / 5;
      canvas.drawLine(Offset(padL, gy), Offset(size.width - padR, gy), grid);
      final price = lo + rng * (1 - i / 5);
      _text(canvas, price.toStringAsFixed(1), labelStyle,
          Offset(size.width - padR + 6, gy - 6));
    }

    final n = candles.length;
    final bw = cw / n;
    for (var i = 0; i < n; i++) {
      final c = candles[i];
      final x = padL + i * bw + bw / 2;
      final up = c.close >= c.open;
      final paint = Paint()..color = up ? _kGreen : _kRed;
      paint.strokeWidth = max(1.0, bw * 0.12);
      canvas.drawLine(Offset(x, y(c.high)), Offset(x, y(c.low)), paint);
      final top = y(max(c.open, c.close));
      var bot = y(min(c.open, c.close));
      if (bot - top < 1.5) bot = top + 1.5;
      canvas.drawRect(
          Rect.fromLTRB(x - bw * 0.32, top, x + bw * 0.32, bot), paint);
    }

    if (markLast) {
      final last = candles.last.close;
      final ly = y(last);
      final dash = Paint()
        ..color = _kGold
        ..strokeWidth = 1.5;
      var x = padL;
      while (x < size.width - padR) {
        canvas.drawLine(Offset(x, ly),
            Offset(min(x + 5, size.width - padR), ly), dash);
        x += 9;
      }
      _text(canvas, last.toStringAsFixed(2),
          const TextStyle(
              color: _kGold, fontSize: 11, fontFamily: 'Roboto'),
          Offset(size.width - padR + 6, ly - 6));
    }

    final first = candles.first.time.toLocal();
    _text(
      canvas,
      '${first.day} ${_month(first.month)} ${first.year}',
      labelStyle,
      Offset(padL, padT + ch + 6),
    );
  }

  String _month(int m) => const [
        'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
        'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
      ][m - 1];

  void _text(Canvas canvas, String s, TextStyle style, Offset at) {
    final tp = TextPainter(
      text: TextSpan(text: s, style: style),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, at);
  }

  @override
  bool shouldRepaint(_PracticeChartPainter old) =>
      old.candles != candles || old.markLast != markLast;
}
