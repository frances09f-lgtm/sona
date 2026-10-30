import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protection.dart';

/// Settings > Stop loss & take profit: the rule Sona uses for the SL/TP of
/// trades it places itself (AI auto-trade and a sure Advice trade).
/// Manual tickets keep the prices typed in. Paper trading only.
class ProtectionSettingsScreen extends StatefulWidget {
  /// Live entry price for the example line (null = a 4,038 gold example).
  final double? examplePrice;

  /// 15-minute ATR for the example (null = $8, a typical gold value).
  final double? exampleAtr;
  const ProtectionSettingsScreen({
    super.key,
    this.examplePrice,
    this.exampleAtr,
  });

  @override
  State<ProtectionSettingsScreen> createState() =>
      _ProtectionSettingsScreenState();
}

class _ProtectionSettingsScreenState extends State<ProtectionSettingsScreen> {
  ProtectionSettings _s = ProtectionSettings.defaults;
  SharedPreferences? _prefs;

  @override
  void initState() {
    super.initState();
    SharedPreferences.getInstance().then((p) {
      if (!mounted) return;
      setState(() {
        _prefs = p;
        _s = ProtectionSettings.read(p);
      });
    }).catchError((_) {});
  }

  Future<void> _set(ProtectionSettings s) async {
    final clean = s.sanitized();
    setState(() => _s = clean);
    final p = _prefs;
    if (p != null) await clean.save(p);
  }

  static String _money(double v) => v.toStringAsFixed(2);

  Widget _slider({
    required String label,
    required String value,
    required double current,
    required (double, double) range,
    required double step,
    required ValueChanged<double> onChanged,
    String? help,
  }) {
    final divisions = ((range.$2 - range.$1) / step).round();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(child: Text(label)),
              Text(value, style: const TextStyle(fontWeight: FontWeight.w700)),
            ],
          ),
          Slider(
            value: current.clamp(range.$1, range.$2).toDouble(),
            min: range.$1,
            max: range.$2,
            divisions: divisions,
            label: value,
            onChanged: (v) {
              final snapped = (v / step).round() * step;
              onChanged(double.parse(snapped.toStringAsFixed(2)));
            },
          ),
          if (help != null)
            Text(
              help,
              style: const TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final price = widget.examplePrice ?? 4038.0;
    final atr = widget.exampleAtr ?? 8.0;
    final buy = computeProtection(
      buy: true,
      entry: price,
      atr: atr,
      settings: _s,
    );
    final sell = computeProtection(
      buy: false,
      entry: price,
      atr: atr,
      settings: _s,
    );
    final atrMode = _s.mode == StopMode.atr;
    return Scaffold(
      appBar: AppBar(title: const Text('Stop loss & take profit')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Used for the SL/TP of trades Sona places itself (AI auto-trade and a sure Advice trade). Manual orders keep the prices you type. Paper trading only.',
              style: TextStyle(color: Color(0xFF8A93A6), fontSize: 12),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Wrap(
              spacing: 8,
              children: [
                ChoiceChip(
                  key: const Key('prot-mode-atr'),
                  label: const Text('ATR based'),
                  selected: atrMode,
                  onSelected: (_) => _set(_s.copyWith(mode: StopMode.atr)),
                ),
                ChoiceChip(
                  key: const Key('prot-mode-pct'),
                  label: const Text('% of price'),
                  selected: !atrMode,
                  onSelected: (_) => _set(_s.copyWith(mode: StopMode.percent)),
                ),
              ],
            ),
          ),
          if (atrMode)
            _slider(
              label: 'Stop distance (x ATR, 15m candles)',
              value: '${_s.atrMultiple.toStringAsFixed(1)}x',
              current: _s.atrMultiple,
              range: ProtectionSettings.atrMultipleRange,
              step: 0.1,
              onChanged: (v) => _set(_s.copyWith(atrMultiple: v)),
              help: '1.0-1.5x is a normal intraday stop. Falls back to % of price when there are too few candles.',
            ),
          _slider(
            label: atrMode ? 'Fallback stop (% of price)' : 'Stop distance (% of price)',
            value: '${_s.stopPct.toStringAsFixed(2)}%',
            current: _s.stopPct,
            range: ProtectionSettings.stopPctRange,
            step: 0.05,
            onChanged: (v) => _set(_s.copyWith(stopPct: v)),
          ),
          _slider(
            label: 'Maximum stop (% of price)',
            value: '${_s.maxStopPct.toStringAsFixed(2)}%',
            current: _s.maxStopPct,
            range: ProtectionSettings.maxStopPctRange,
            step: 0.05,
            onChanged: (v) => _set(_s.copyWith(maxStopPct: v)),
            help: 'The stop is never further than this from entry.',
          ),
          _slider(
            label: 'Take profit (reward : risk)',
            value: '1 : ${_s.riskReward.toStringAsFixed(1)}',
            current: _s.riskReward,
            range: ProtectionSettings.riskRewardRange,
            step: 0.1,
            onChanged: (v) => _set(_s.copyWith(riskReward: v)),
            help: 'TP distance = this x the stop distance.',
          ),
          SwitchListTile(
            title: const Text('Use a tighter AI stop'),
            subtitle: const Text(
              'If the AI puts the stop just past a chart level closer than the rule (but at least half an ATR away), use it. A wider AI stop is never used.',
            ),
            value: _s.useAiStop,
            onChanged: (v) => _set(_s.copyWith(useAiStop: v)),
          ),
          Card(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Example: gold at ${_money(price)}, 15m ATR \$${_money(atr)}',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Buy: SL ${_money(buy.sl)} (-\$${_money(buy.risk)}) · TP ${_money(buy.tp)} (+\$${_money((buy.tp - price).abs())})',
                    key: const Key('prot-example-buy'),
                  ),
                  Text(
                    'Sell: SL ${_money(sell.sl)} (+\$${_money(sell.risk)}) · TP ${_money(sell.tp)} (-\$${_money((sell.tp - price).abs())})',
                    key: const Key('prot-example-sell'),
                  ),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: OutlinedButton(
              onPressed: () => _set(ProtectionSettings.defaults),
              child: const Text('Reset to defaults'),
            ),
          ),
        ],
      ),
    );
  }
}
