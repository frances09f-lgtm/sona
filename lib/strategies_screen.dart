import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'backtest.dart';
import 'chart/candle_chart.dart' show kChartSelectionRevPref;
import 'main.dart' show AppState, EquityPainter;
import 'market_data/market_data_config.dart';
import 'market_data/models.dart';
import 'market_data/twelve_data_candles.dart';
import 'strategy.dart';

const _bg = Color(0xFF0F1115);
const _card = Color(0xFF171A21);
const _dim = Color(0xFF8A93A6);
const _green = Color(0xFF2EC27E);
const _red = Color(0xFFE0654F);

/// Strategies home: the user's custom price-action strategies, each with
/// notes, a show-on-chart switch and a backtest run (user request Oct 21).
class StrategiesScreen extends StatefulWidget {
  final AppState app;
  const StrategiesScreen({super.key, required this.app});
  @override
  State<StrategiesScreen> createState() => _StrategiesScreenState();
}

class _StrategiesScreenState extends State<StrategiesScreen> {
  List<PriceActionStrategy> _items = [];
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final items = await StrategyStore.load();
    if (!mounted) return;
    setState(() {
      _items = items;
      _loaded = true;
    });
  }

  Future<void> _persist() async {
    await StrategyStore.save(_items);
    // Tell the chart to re-read strategies (same channel Settings uses).
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
      kChartSelectionRevPref,
      (prefs.getInt(kChartSelectionRevPref) ?? 0) + 1,
    );
    widget.app.refresh();
  }

  Future<void> _edit([PriceActionStrategy? existing]) async {
    final result = await Navigator.of(context).push<PriceActionStrategy>(
      MaterialPageRoute(builder: (_) => StrategyEditorScreen(existing: existing)),
    );
    if (result == null) return;
    setState(() {
      final i = _items.indexWhere((x) => x.id == result.id);
      if (i >= 0) {
        _items[i] = result;
      } else {
        _items.add(result);
      }
    });
    await _persist();
  }

  Future<void> _delete(PriceActionStrategy s) async {
    setState(() => _items.removeWhere((x) => x.id == s.id));
    await _persist();
  }

  Future<void> _runBacktest(PriceActionStrategy s) async {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    try {
      if (MarketDataConfig.apiKey.isEmpty) {
        throw StateError('Add your Twelve Data key in API settings first.');
      }
      // One month of 15-minute candles (~3000 bars) - the backtest window.
      final candles = await TwelveDataCandleService(
        apiKey: MarketDataConfig.apiKey,
      ).fetchCandles(Instrument.xauUsd, interval: '15min', limit: 3000);
      final result = runBacktest(candles, s);
      if (!mounted) return;
      Navigator.of(context).pop(); // spinner
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => BacktestResultScreen(strategy: s, result: result),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      Navigator.of(context).pop(); // spinner
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Backtest failed: $e')),
      );
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _bg,
    appBar: AppBar(
      backgroundColor: _bg,
      title: const Text('Strategies'),
    ),
    floatingActionButton: FloatingActionButton(
      onPressed: () => _edit(),
      child: const Icon(Icons.add),
    ),
    body: !_loaded
        ? const Center(child: CircularProgressIndicator())
        : _items.isEmpty
            ? const Center(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Text(
                    'No strategies yet. Tap + to add your price-action '
                    'strategy: name, notes, and the 1H high/low rules it '
                    'marks on the chart and backtests.',
                    style: TextStyle(color: _dim),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            : ListView.separated(
                itemCount: _items.length,
                separatorBuilder: (_, __) =>
                    const Divider(height: 1, color: Color(0xFF232733)),
                itemBuilder: (_, i) {
                  final s = _items[i];
                  return ListTile(
                    title: Text(s.name),
                    subtitle: Text(
                      '${s.notes.isEmpty ? '1H high/low break' : s.notes}\n'
                      'Both directions: ${s.allowLong && s.allowShort ? 'yes' : (s.allowLong ? 'long only' : (s.allowShort ? 'short only' : 'off'))} · TP ${s.rrMultiple}R · marks last ${s.lookbackHours}h · hold to delete',
                      style: const TextStyle(color: _dim, fontSize: 12),
                    ),
                    isThreeLine: true,
                    trailing: Switch(
                      value: s.showOnChart,
                      onChanged: (v) {
                        setState(() => s.showOnChart = v);
                        _persist();
                      },
                    ),
                    onTap: () => _edit(s),
                    onLongPress: () async {
                      final ok = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text('Delete ${s.name}?'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: const Text('Cancel'),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                      if (ok == true) _delete(s);
                    },
                    leading: IconButton(
                      icon: const Icon(Icons.play_arrow, color: _green),
                      tooltip: 'Run backtest (1 month)',
                      onPressed: () => _runBacktest(s),
                    ),
                  );
                },
              ),
  );
}

/// Add/edit one strategy: name, free-text info, and the 1H high/low rule
/// parameters used for chart markers and the backtest.
class StrategyEditorScreen extends StatefulWidget {
  final PriceActionStrategy? existing;
  const StrategyEditorScreen({super.key, this.existing});
  @override
  State<StrategyEditorScreen> createState() => _StrategyEditorScreenState();
}

class _StrategyEditorScreenState extends State<StrategyEditorScreen> {
  late final TextEditingController _name;
  late final TextEditingController _notes;
  late final TextEditingController _lookback;
  late final TextEditingController _rr;
  late bool _long;
  late bool _short;
  late bool _showOnChart;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    _name = TextEditingController(text: e?.name ?? '');
    _notes = TextEditingController(text: e?.notes ?? '');
    _lookback = TextEditingController(text: '${e?.lookbackHours ?? 24}');
    _rr = TextEditingController(text: '${e?.rrMultiple ?? 2.0}');
    _long = e?.allowLong ?? true;
    _short = e?.allowShort ?? true;
    _showOnChart = e?.showOnChart ?? true;
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    final s = PriceActionStrategy(
      id: widget.existing?.id ??
          'st${DateTime.now().millisecondsSinceEpoch}',
      name: name,
      notes: _notes.text.trim(),
      showOnChart: _showOnChart,
      lookbackHours: int.tryParse(_lookback.text) ?? 24,
      allowLong: _long,
      allowShort: _short,
      rrMultiple: double.tryParse(_rr.text) ?? 2.0,
    );
    Navigator.of(context).pop(s);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: _bg,
    appBar: AppBar(
      backgroundColor: _bg,
      title: Text(widget.existing == null ? 'Add strategy' : 'Edit strategy'),
      actions: [TextButton(onPressed: _save, child: const Text('Save'))],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Strategy name'),
        ),
        TextField(
          controller: _notes,
          maxLines: 3,
          decoration: const InputDecoration(
            labelText: 'Info / rules / notes',
            hintText: 'e.g. mark the high and low of the 1H candle every '
                'hour; buy the high break, sell the low break',
          ),
        ),
        const SizedBox(height: 12),
        const Text('Rule: 1H high/low break',
            style: TextStyle(color: _dim, fontSize: 12)),
        TextField(
          controller: _lookback,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Mark levels for the last N hours',
          ),
        ),
        TextField(
          controller: _rr,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(
            labelText: 'Take profit (x the stop distance)',
            helperText: 'Stop is the opposite side of the signal hour candle',
          ),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Long (buy the hour-high break)'),
          value: _long,
          onChanged: (v) => setState(() => _long = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Short (sell the hour-low break)'),
          value: _short,
          onChanged: (v) => setState(() => _short = v),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Show levels on chart'),
          value: _showOnChart,
          onChanged: (v) => setState(() => _showOnChart = v),
        ),
      ],
    ),
  );
}

/// Backtest outcome over the fetched history. Display-only: never touches
/// the paper account or the journal.
class BacktestResultScreen extends StatelessWidget {
  final PriceActionStrategy strategy;
  final BacktestResult result;
  const BacktestResultScreen({
    super.key,
    required this.strategy,
    required this.result,
  });

  @override
  Widget build(BuildContext context) {
    final r = result;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: Text('Backtest: ${strategy.name}'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'BACKTEST - simulated on past candles, not a real trade result',
            style: TextStyle(color: _dim, fontSize: 11),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _stat('Trades', '${r.trades.length}'),
              _stat('Win rate', '${(r.winRate * 100).toStringAsFixed(0)}%'),
              _stat(
                'Net points',
                r.netPoints.toStringAsFixed(1),
                color: r.netPoints >= 0 ? _green : _red,
              ),
              _stat('Wins / losses', '${r.wins} / ${r.losses}'),
            ],
          ),
          const SizedBox(height: 16),
          if (r.trades.isNotEmpty)
            SizedBox(
              height: 160,
              child: CustomPaint(painter: EquityPainter(r.pnlSeries)),
            ),
          const SizedBox(height: 16),
          for (final t in r.trades.reversed)
            ListTile(
              dense: true,
              tileColor: _card,
              title: Text(
                '${t.long ? 'BUY' : 'SELL'} @ ${t.entry.toStringAsFixed(2)} -> ${t.exit.toStringAsFixed(2)}',
                style: const TextStyle(fontSize: 13),
              ),
              subtitle: Text(
                '${_fmtTime(t.entryTime)} -> ${_fmtTime(t.exitTime)} · ${t.exitReason}',
                style: const TextStyle(color: _dim, fontSize: 11),
              ),
              trailing: Text(
                '${t.pnlPoints >= 0 ? '+' : ''}${t.pnlPoints.toStringAsFixed(1)}',
                style: TextStyle(
                  color: t.pnlPoints >= 0 ? _green : _red,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _fmtTime(DateTime t) {
    final m = t.month.toString().padLeft(2, '0');
    final d = t.day.toString().padLeft(2, '0');
    final h = t.hour.toString().padLeft(2, '0');
    final min = t.minute.toString().padLeft(2, '0');
    return '$m/$d $h:$min';
  }

  Widget _stat(String label, String value, {Color? color}) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(8),
    ),
    child: Column(
      children: [
        Text(value,
            style: TextStyle(
                fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        Text(label, style: const TextStyle(color: _dim, fontSize: 11)),
      ],
    ),
  );
}
