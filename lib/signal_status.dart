import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Diagnostics-only record of the latest signal check. Fixed-vocabulary
/// outcome codes and counts only: no keys, URLs, exception text or reply
/// bodies are ever stored. Written by both the foreground chart path and
/// the background worker so the Chart diagnostics screen can show what
/// actually happened. Reading or writing it never changes a gate.
class SignalStatus {
  static const String prefsKey = 'tj_signal_status_v1';

  /// Allowed outcome codes (anything else is stored as 'other').
  static const Set<String> outcomes = {
    'no_setup_needed', // both direction slots already filled
    'no_candidates', // detection found no fresh pivot
    'gap_wait', // a qualification call happened < 15 min ago
    'asked_ai_added', // AI call made, a box was drawn
    'asked_ai_declined', // AI call made, reply declined every candidate
    'ai_no_reply', // AI call made, no usable reply (missing key, rate limit, failure)
    'no_quote', // worker: no live quote
    'no_candles', // worker: no candle data
  };

  static Future<void> record(
    SharedPreferences prefs, {
    required String path, // 'foreground' | 'worker'
    required String outcome,
    int? candidates,
    int? buyCandidates,
    int? sellCandidates,
    bool? groqKeyPresent,
    int? nowMs,
  }) async {
    try {
      final m = <String, dynamic>{
        'at': nowMs ?? DateTime.now().millisecondsSinceEpoch,
        'path': path == 'worker' ? 'worker' : 'foreground',
        'outcome': outcomes.contains(outcome) ? outcome : 'other',
        if (candidates != null) 'cand': candidates,
        if (buyCandidates != null) 'buy': buyCandidates,
        if (sellCandidates != null) 'sell': sellCandidates,
        if (groqKeyPresent != null) 'key': groqKeyPresent,
      };
      await prefs.setString(prefsKey, jsonEncode(m));
    } catch (_) {
      // Diagnostics must never affect the signal pass.
    }
  }

  /// Human lines for the diagnostics report. [minGap] is the enforced gap
  /// between AI qualification calls (shared stamp tj_signal_qual_last_ms).
  static List<String> describe(
    SharedPreferences prefs, {
    required int nowMs,
    required Duration minGap,
  }) {
    final out = <String>[];
    final raw = prefs.getString(prefsKey);
    if (raw == null) {
      out.add('last check: none recorded yet on this device');
    } else {
      try {
        final m = Map<String, dynamic>.from(jsonDecode(raw) as Map);
        final at = DateTime.fromMillisecondsSinceEpoch((m['at'] as num).toInt());
        final ageMin = (nowMs - at.millisecondsSinceEpoch) ~/ 60000;
        out.add('last check: ${at.toLocal()} ($ageMin min ago), '
            'path ${m['path']}');
        out.add('outcome: ${m['outcome']}');
        if (m['cand'] != null) {
          out.add('candidates: ${m['cand']} (buy ${m['buy'] ?? '-'}, '
              'sell ${m['sell'] ?? '-'})');
        }
        if (m['key'] != null) {
          out.add('Groq key present at that check: ${m['key'] == true ? 'yes' : 'no'}');
        }
      } catch (_) {
        out.add('last check: unreadable record');
      }
    }
    final last = prefs.getInt('tj_signal_qual_last_ms') ?? 0;
    if (last <= 0) {
      out.add('last AI qualification call: none recorded');
    } else {
      final since = nowMs - last;
      final waitMin = ((minGap.inMilliseconds - since) / 60000).ceil();
      out.add('last AI qualification call: '
          '${DateTime.fromMillisecondsSinceEpoch(last).toLocal()} '
          '(${since ~/ 60000} min ago); '
          '${waitMin > 0 ? 'next allowed in $waitMin min' : 'next call allowed now'}');
    }
    return out;
  }
}
