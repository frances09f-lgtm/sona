import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../market_data/models.dart';

enum ChartStyle {
  candles('Candles'),
  line('Line'),
  bars('Bars');

  final String label;
  const ChartStyle(this.label);
}

bool validChartCandle(Candle c) =>
    [c.open, c.high, c.low, c.close].every((p) => p.isFinite && p > 0) &&
    c.high >= c.low &&
    c.high >= c.open &&
    c.high >= c.close &&
    c.low <= c.open &&
    c.low <= c.close;

/// A display-only snapshot; this module has no execution callbacks.
class ChartPosition {
  final bool buy;
  final double entry, quantity;
  final double? stop, target, pnl;
  const ChartPosition({
    required this.buy,
    required this.entry,
    required this.quantity,
    this.stop,
    this.target,
    this.pnl,
  });
  static ChartPosition? fromRecord(
    Map<String, dynamic> record, {
    double? mark,
    bool fresh = false,
  }) {
    double? number(dynamic v) =>
        v is num && v.isFinite && v > 0 ? v.toDouble() : null;
    final entry = number(record['entry']), qty = number(record['qty']);
    if (record['status'] != 'open' ||
        entry == null ||
        qty == null ||
        !['buy', 'sell'].contains(record['direction']))
      return null;
    final buy = record['direction'] == 'buy';
    final pnl = fresh && mark != null && mark.isFinite && mark > 0
        ? (mark - entry) * qty * (buy ? 1 : -1)
        : null;
    return ChartPosition(
      buy: buy,
      entry: entry,
      quantity: qty,
      stop: number(record['sl']),
      target: number(record['tp']),
      pnl: pnl?.isFinite == true ? pnl : null,
    );
  }
}

class ChartMarketSnapshot {
  final double? price;
  final bool fresh;
  final List<ChartPosition> positions;
  const ChartMarketSnapshot({
    this.price,
    this.fresh = true,
    this.positions = const [],
  });
  String get summary =>
      'Paper · display only · ' +
      positions
          .asMap()
          .entries
          .map((e) {
            final p = e.value;
            final result = fresh && p.pnl != null
                ? '${p.pnl! >= 0 ? '+' : '-'}\$${p.pnl!.abs().toStringAsFixed(2)}'
                : 'PnL unavailable (no fresh quote)';
            return '${e.key + 1} ${p.buy ? 'BUY' : 'SELL'} ${p.quantity} oz $result';
          })
          .join(' · ');
}

class IndicatorSettingsDialog extends StatefulWidget {
  final List<int> values;
  const IndicatorSettingsDialog({super.key, required this.values});
  @override
  State<IndicatorSettingsDialog> createState() =>
      _IndicatorSettingsDialogState();
}

class _IndicatorSettingsDialogState extends State<IndicatorSettingsDialog> {
  late final controllers = widget.values
      .map((v) => TextEditingController(text: '$v'))
      .toList();
  String? error;
  @override
  void dispose() {
    for (final c in controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Indicator settings'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text(
            'Periods: 2–200 candles. Toggle each indicator in the Indicators menu. Layout presets save these values.',
          ),
          for (var i = 0; i < controllers.length; i++)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: TextField(
                key: ValueKey('indicator-period-$i'),
                controller: controllers[i],
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText: [
                    'EMA period',
                    'RSI period',
                    'MACD fast',
                    'MACD slow',
                    'MACD signal',
                  ][i],
                ),
              ),
            ),
          if (error != null)
            Text(
              error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          final v = controllers
              .map((c) => int.tryParse(c.text.trim()) ?? 0)
              .toList();
          if (v.any((n) => n < 2 || n > 200) || v[2] >= v[3]) {
            setState(
              () => error = 'Use 2–200; MACD fast must be less than slow.',
            );
            return;
          }
          Navigator.pop(context, v);
        },
        child: const Text('Apply'),
      ),
    ],
  );
}

/// Reserve a useful price plot even in a short landscape viewport.
double chartPaneHeight(double height, bool rsi, bool macd) {
  final count = (rsi ? 1 : 0) + (macd ? 1 : 0);
  return count == 0 ? 0 : math.min(64.0, math.max(0.0, (height - 96) / count));
}

/// Closest non-overlapping label slot; lines remain at their actual prices.
double? overlayLabelY(double preferred, double plotHeight, List<double> used) {
  final maxY = math.max(0.0, plotHeight - 12.0);
  final start = preferred.clamp(0.0, maxY).toDouble();
  for (var step = 0; step <= (plotHeight / 12).ceil(); step++) {
    for (final direction in step == 0 ? [1] : [-1, 1]) {
      final y = start + step * direction * 12;
      if (y < 0 || y > maxY) continue;
      if (used.every((v) => (v - y).abs() >= 12)) return y;
    }
  }
  return null;
}
