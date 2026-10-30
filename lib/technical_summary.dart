import 'chart/indicators.dart';
import 'market_data/models.dart';

/// Sona's own technical summary ("gauge") over REAL candles.
///
/// This is NOT TradingView's rating and must never be labeled as such.
/// A fixed, documented set of oscillators and moving averages each vote
/// buy (+1), neutral (0) or sell (-1); the mean vote maps to five buckets.
/// Rules are conventional technical-analysis readings, chosen and visible
/// here - the card lists every vote so nothing is a black box. It describes
/// what the data currently looks like; it is not a prediction, a
/// recommendation, or financial advice.
enum TechRating { strongSell, sell, neutral, buy, strongBuy }

String techRatingLabel(TechRating r) => switch (r) {
  TechRating.strongSell => 'Strong sell',
  TechRating.sell => 'Sell',
  TechRating.neutral => 'Neutral',
  TechRating.buy => 'Buy',
  TechRating.strongBuy => 'Strong buy',
};

/// Maps the mean vote in [-1, 1] to a bucket. Thresholds mirror the common
/// five-way summary convention: |score| < 0.1 neutral, < 0.5 directional,
/// otherwise strong.
TechRating techBucketForScore(double score) {
  if (score >= 0.5) return TechRating.strongBuy;
  if (score >= 0.1) return TechRating.buy;
  if (score > -0.1) return TechRating.neutral;
  if (score > -0.5) return TechRating.sell;
  return TechRating.strongSell;
}

class IndicatorVote {
  final String name;
  final int vote; // -1 sell, 0 neutral, +1 buy
  final String detail;
  const IndicatorVote(this.name, this.vote, this.detail);
}

/// Total indicators the summary can ever use: 7 oscillators + 6 SMA + 6
/// EMA. Indicators whose period exceeds the loaded candle count do not
/// vote and are counted in [TechnicalSummary.skippedCount] so the UI can
/// say exactly how many contributed.
const int kTechSummaryMaxIndicators = 19;

class TechnicalSummary {
  final TechRating rating;

  /// Mean vote in [-1, 1]; 0 when there are no votes.
  final double score;
  final List<IndicatorVote> oscillators;
  final List<IndicatorVote> movingAverages;

  /// Indicators that could not vote because their period exceeds the
  /// loaded candle count (e.g. SMA-200 on 60 candles). Transparently
  /// excluded - never filled with a neutral vote.
  final int skippedCount;

  /// Set when there were too few candles to compute anything; the UI shows
  /// this instead of a rating rather than guessing.
  final String? insufficientReason;

  const TechnicalSummary({
    required this.rating,
    required this.score,
    required this.oscillators,
    required this.movingAverages,
    this.insufficientReason,
    this.skippedCount = 0,
  });

  int get buyCount =>
      oscillators.where((v) => v.vote > 0).length +
      movingAverages.where((v) => v.vote > 0).length;
  int get sellCount =>
      oscillators.where((v) => v.vote < 0).length +
      movingAverages.where((v) => v.vote < 0).length;
  int get neutralCount =>
      oscillators.where((v) => v.vote == 0).length +
      movingAverages.where((v) => v.vote == 0).length;
}

/// Minimum candles the summary will work with. Long MAs that still do not
/// fit are skipped individually (they just do not vote).
const int kTechSummaryMinCandles = 60;

/// Computes the summary from CLOSED candles, oldest first, times UTC.
/// Pure function: no fetch, no clock, no hidden state.
TechnicalSummary computeTechnicalSummary(List<Candle> candles) {
  if (candles.length < kTechSummaryMinCandles) {
    return TechnicalSummary(
      rating: TechRating.neutral,
      score: 0,
      oscillators: const [],
      movingAverages: const [],
      insufficientReason:
          'Need at least $kTechSummaryMinCandles candles, have ${candles.length}',
    );
  }
  final price = candles.last.close;
  final osc = <IndicatorVote>[];
  final mas = <IndicatorVote>[];

  String f(double v) => v.toStringAsFixed(1);

  // ---- Oscillators ----

  // RSI(14): above 70 overbought (sell), below 30 oversold (buy).
  final r = rsi(candles, 14);
  if (r.isNotEmpty) {
    final v = r.last;
    final vote = v > 70 ? -1 : (v < 30 ? 1 : 0);
    osc.add(IndicatorVote('RSI(14)', vote, 'RSI ${f(v)}'));
  }

  // Stochastic %K(14,3) vs %D(3): %K above %D = upward momentum.
  final st = _stochastic(candles, 14, 3, 3);
  if (st != null) {
    final (k, d) = st;
    final vote = k > d ? 1 : (k < d ? -1 : 0);
    osc.add(IndicatorVote('Stoch(14,3,3)', vote, '%K ${f(k)} vs %D ${f(d)}'));
  }

  // CCI(20): beyond +/-100 = trending.
  final cc = _cci(candles, 20);
  if (cc != null) {
    final vote = cc > 100 ? 1 : (cc < -100 ? -1 : 0);
    osc.add(IndicatorVote('CCI(20)', vote, 'CCI ${f(cc)}'));
  }

  // ADX(14): +DI above -DI = buyers in control (direction only, not
  // strength); value reported so a weak trend is visible.
  final adx = _adx(candles, 14);
  if (adx != null) {
    final (a, pDi, mDi) = adx;
    final vote = pDi > mDi ? 1 : (pDi < mDi ? -1 : 0);
    osc.add(IndicatorVote(
        'ADX(14)', vote, 'ADX ${f(a)}, +DI ${f(pDi)} vs -DI ${f(mDi)}'));
  }

  // Momentum(10): close vs close 10 candles back.
  final m = candles.last.close - candles[candles.length - 11].close;
  osc.add(IndicatorVote(
      'Momentum(10)', m > 0 ? 1 : (m < 0 ? -1 : 0), 'Mom ${f(m)}'));

  // MACD(12,26,9): line above signal = upward momentum.
  final (line, signal, _) = macd(candles);
  if (line.isNotEmpty && signal.isNotEmpty) {
    final vote = line.last > signal.last
        ? 1
        : (line.last < signal.last ? -1 : 0);
    osc.add(IndicatorVote('MACD(12,26,9)', vote,
        'MACD ${f(line.last)} vs signal ${f(signal.last)}'));
  }

  // Williams %R(14): above -20 overbought (sell), below -80 oversold (buy).
  final wr = _williamsR(candles, 14);
  if (wr != null) {
    final vote = wr > -20 ? -1 : (wr < -80 ? 1 : 0);
    osc.add(IndicatorVote('Williams %R(14)', vote, '%R ${f(wr)}'));
  }

  // ---- Moving averages: price above the average = buy, below = sell ----
  // Comparisons use a relative epsilon: long EMAs accumulate float error
  // (~1e-12 at gold prices), which otherwise votes "sell" on a perfectly
  // flat tape. The epsilon is far below any real tick.
  int dirVote(double avg) {
    final eps = price.abs() * 1e-9;
    final d = price - avg;
    return d > eps ? 1 : (d < -eps ? -1 : 0);
  }

  for (final period in const [10, 20, 30, 50, 100, 200]) {
    final s = sma(candles, period);
    if (s.isNotEmpty) {
      final v = s.last;
      mas.add(IndicatorVote(
          'SMA($period)', dirVote(v), 'Price ${f(price)} vs SMA ${f(v)}'));
    }
    final e = ema(candles, period);
    if (e.isNotEmpty) {
      final v = e.last;
      mas.add(IndicatorVote(
          'EMA($period)', dirVote(v), 'Price ${f(price)} vs EMA ${f(v)}'));
    }
  }

  final votes = [...osc, ...mas];
  final score = votes.isEmpty
      ? 0.0
      : votes.fold<int>(0, (a, v) => a + v.vote) / votes.length;
  return TechnicalSummary(
    rating: techBucketForScore(score),
    score: score,
    oscillators: osc,
    movingAverages: mas,
    skippedCount: kTechSummaryMaxIndicators - votes.length,
  );
}

double _highest(List<Candle> cs) =>
    cs.fold(-double.infinity, (a, c) => a > c.high ? a : c.high);
double _lowest(List<Candle> cs) =>
    cs.fold(double.infinity, (a, c) => a < c.low ? a : c.low);

/// Stochastic %K (period, smoothed) and %D (signal SMA of %K).
(double, double)? _stochastic(
    List<Candle> candles, int period, int smoothK, int periodD) {
  if (candles.length < period + smoothK + periodD - 2) return null;
  final rawK = <double>[];
  for (int i = period - 1; i < candles.length; i++) {
    final win = candles.sublist(i - period + 1, i + 1);
    final hh = _highest(win), ll = _lowest(win);
    rawK.add(hh == ll ? 50.0 : (candles[i].close - ll) / (hh - ll) * 100);
  }
  if (rawK.length < smoothK + periodD - 1) return null;
  final kSmooth = <double>[];
  for (int i = smoothK - 1; i < rawK.length; i++) {
    kSmooth.add(
        rawK.sublist(i - smoothK + 1, i + 1).reduce((a, b) => a + b) /
            smoothK);
  }
  final d = kSmooth
          .sublist(kSmooth.length - periodD)
          .reduce((a, b) => a + b) /
      periodD;
  return (kSmooth.last, d);
}

/// Commodity Channel Index over typical price.
double? _cci(List<Candle> candles, int period) {
  if (candles.length < period) return null;
  final tps = [
    for (final c in candles) (c.high + c.low + c.close) / 3,
  ];
  final win = tps.sublist(tps.length - period);
  final mean = win.reduce((a, b) => a + b) / period;
  final md =
      win.fold<double>(0, (a, v) => a + (v - mean).abs()) / period;
  if (md == 0) return 0;
  return (tps.last - mean) / (0.015 * md);
}

/// Wilder ADX: returns (adx, +DI, -DI) using the last [period] smoothed
/// values seeded over the first [period] moves.
(double, double, double)? _adx(List<Candle> candles, int period) {
  if (candles.length < period * 2) return null;
  double tr = 0, pdm = 0, mdm = 0;
  for (int i = 1; i <= period; i++) {
    final (t, p, m) = _dm(candles[i - 1], candles[i]);
    tr += t;
    pdm += p;
    mdm += m;
  }
  double adx = 0;
  int count = 0;
  for (int i = period + 1; i < candles.length; i++) {
    final (t, p, m) = _dm(candles[i - 1], candles[i]);
    tr = tr - tr / period + t;
    pdm = pdm - pdm / period + p;
    mdm = mdm - mdm / period + m;
    if (tr == 0) continue;
    final pDi = 100 * pdm / tr, mDi = 100 * mdm / tr;
    final sum = pDi + mDi;
    final dx = sum == 0 ? 0.0 : 100 * (pDi - mDi).abs() / sum;
    if (count < period) {
      adx += dx;
      count++;
      if (count == period) adx = adx / period;
    } else {
      adx = (adx * (period - 1) + dx) / period;
    }
  }
  if (count < period || tr == 0) return null;
  return (adx, 100 * pdm / tr, 100 * mdm / tr);
}

/// True range and directional moves between two candles.
(double, double, double) _dm(Candle prev, Candle cur) {
  final up = cur.high - prev.high;
  final down = prev.low - cur.low;
  final tr = [
    cur.high - cur.low,
    (cur.high - prev.close).abs(),
    (cur.low - prev.close).abs(),
  ].reduce((a, b) => a > b ? a : b);
  final pdm = (up > down && up > 0) ? up : 0.0;
  final mdm = (down > up && down > 0) ? down : 0.0;
  return (tr, pdm, mdm);
}

/// Williams %R over [period] candles, in [-100, 0].
double? _williamsR(List<Candle> candles, int period) {
  if (candles.length < period) return null;
  final win = candles.sublist(candles.length - period);
  final hh = _highest(win), ll = _lowest(win);
  if (hh == ll) return -50;
  return (hh - candles.last.close) / (hh - ll) * -100;
}
