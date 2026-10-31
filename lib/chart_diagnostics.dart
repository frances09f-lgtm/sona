import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'bridge.dart';
import 'chart/chart_tools.dart';
import 'market_data/candle_debug.dart';

/// Test-build diagnostics: shows exactly how the chart's candles arrived -
/// the provider's raw first/last bars before any app parsing, the quote
/// freshness that gates the forming-bar fold, and build identity - so the
/// long-wick report can be settled against runtime facts instead of
/// screenshots. Privacy: API keys and request URLs never appear (the sink
/// sanitizes), nothing is written to disk here, and nothing leaves the
/// device unless the user taps Copy.
class ChartDiagnosticsScreen extends StatelessWidget {
  final ChartMarketSnapshot? snapshot;

  const ChartDiagnosticsScreen({super.key, required this.snapshot});

  Future<(String, String)> _version() async {
    final info = await PackageInfo.fromPlatform();
    return (info.version, info.buildNumber);
  }

  Future<String> _quoteAge() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(OroBridge.snapshotKey);
    if (raw == null) return 'no stored quote';
    try {
      final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      final at = m['quoteAt'];
      if (at is! num || at <= 0) return 'no stored quote time';
      final when = DateTime.fromMillisecondsSinceEpoch(at.toInt());
      final age = DateTime.now().difference(when);
      return '${when.toLocal()} (${age.inMinutes} min ago)';
    } catch (_) {
      return 'unreadable stored quote';
    }
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 128,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Expanded(child: Text(value)),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    final snap = snapshot;
    final foldActive = (snap?.fresh ?? false) &&
        (snap?.price?.isFinite ?? false) &&
        (snap?.price ?? 0) > 0;
    final foldReason = snap == null
        ? 'unknown from this screen - open the chart for the live state'
        : (foldActive
            ? 'active: quote fresh, forming bar folds live ticks'
            : 'inactive: quote stale/unavailable, provider bars untouched');
    final ticksText = snap == null
        ? 'unknown from this screen'
        : '${snap.liveTicks?.length ?? 0}';
    final quoteText = snap == null
        ? 'unknown from this screen - stored quote time below'
        : 'bid ${snap.bid ?? '-'} / ask ${snap.ask ?? '-'}';

    return Scaffold(
      appBar: AppBar(title: const Text('Chart diagnostics')),
      body: FutureBuilder<(String, String)>(
        future: _version(),
        builder: (context, ver) {
          final version = ver.data?.$1 ?? '…';
          final build = ver.data?.$2 ?? '…';
          final report = StringBuffer()
            ..writeln('Sona chart diagnostics')
            ..writeln('version: $version+$build')
            ..writeln('candle source: ${CandleDebugSink.source ?? 'none yet'}')
            ..writeln(
                'fetch at (UTC): ${CandleDebugSink.fetchAtUtc?.toIso8601String() ?? 'none yet'}')
            ..writeln('payload bars: ${CandleDebugSink.totalValues}')
            ..writeln('fold: $foldReason')
            ..writeln('quote: $quoteText')
            ..writeln('live ticks buffered: $ticksText')
            ..writeln(
                'last error: ${CandleDebugSink.lastError ?? 'none'}')
            ..writeln('raw first bars:')
            ..writeln(CandleDebugSink.rawHead.join('\n'))
            ..writeln('raw last bars:')
            ..writeln(CandleDebugSink.rawTail.join('\n'));

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _row('Build', '$version+$build'),
              _row('Candle source', CandleDebugSink.source ?? 'none yet'),
              _row(
                'Fetch at (UTC)',
                CandleDebugSink.fetchAtUtc?.toIso8601String() ?? 'none yet',
              ),
              _row('Payload bars', '${CandleDebugSink.totalValues}'),
              _row('Forming-bar fold', foldReason),
              _row('Quote', quoteText),
              FutureBuilder<String>(
                future: _quoteAge(),
                builder: (context, q) =>
                    _row('Quote stamped', q.data ?? '…'),
              ),
              _row('Live ticks buffered', ticksText),
              _row('Last fetch error', CandleDebugSink.lastError ?? 'none'),
              const SizedBox(height: 12),
              const Text('Raw first bars (pre-parse):',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SelectableText(
                CandleDebugSink.rawHead.isEmpty
                    ? 'none captured yet - reopen the chart to fetch'
                    : CandleDebugSink.rawHead.join('\n'),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.3),
              ),
              const SizedBox(height: 12),
              const Text('Raw last bars (pre-parse):',
                  style: TextStyle(fontWeight: FontWeight.w600)),
              SelectableText(
                CandleDebugSink.rawTail.isEmpty
                    ? 'none captured yet - reopen the chart to fetch'
                    : CandleDebugSink.rawTail.join('\n'),
                style: const TextStyle(
                    fontFamily: 'monospace', fontSize: 12, height: 1.3),
              ),
              const SizedBox(height: 20),
              FilledButton.icon(
                icon: const Icon(Icons.copy),
                label: const Text('Copy report'),
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: report.toString()));
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Diagnostics copied')),
                    );
                  }
                },
              ),
              const SizedBox(height: 8),
              const Text(
                'Stays on this device unless you paste it somewhere. '
                'No API keys or request URLs are included.',
                style: TextStyle(fontSize: 12, color: Colors.grey),
              ),
            ],
          );
        },
      ),
    );
  }
}
