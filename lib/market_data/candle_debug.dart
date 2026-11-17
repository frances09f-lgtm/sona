import 'dart:convert';

/// Test-build diagnostics sink: remembers how the last candle fetch went,
/// including the provider's raw first/last bars BEFORE any parsing or
/// validation, so a chart diagnostics screen can show exactly what the
/// provider sent. Device-local, in-memory only - never written to disk,
/// never uploaded, and never includes API keys or request URLs.
class CandleDebugSink {
  static String? source;
  static DateTime? fetchAtUtc;
  static int totalValues = 0;
  static List<String> rawHead = const []; // first 3 raw entries, pre-parse
  static List<String> rawTail = const []; // last 3 raw entries, pre-parse
  static String? lastError; // sanitized: keys/URLs stripped
  static String? requestedInterval; // as requested from the provider, e.g. 5min

  static String sanitize(String text, {String secret = ''}) {
    var out = text;
    if (secret.isNotEmpty) out = out.replaceAll(secret, '[redacted]');
    // Never surface URLs (they can embed credentials in query strings).
    out = out.replaceAll(RegExp(r'https?://\S+'), '[url]');
    // Never surface long credential-like runs.
    out = out.replaceAll(RegExp(r'[A-Za-z0-9]{24,}'), '[redacted]');
    return out;
  }

  static void recordFetch({
    required String sourceName,
    required List<dynamic> values,
    String secret = '',
    String? interval,
  }) {
    source = sourceName;
    requestedInterval = interval;
    fetchAtUtc = DateTime.now().toUtc();
    totalValues = values.length;
    lastError = null;
    // Raw provider values pass through the same redaction as errors: a
    // misbehaving payload must never surface keys or URLs in the panel.
    List<String> encode(Iterable<dynamic> items) => [
          for (final v in items)
            sanitize(
              const JsonEncoder.withIndent('  ').convert(v),
              secret: secret,
            ),
        ];
    rawHead = encode(values.take(3));
    rawTail =
        values.length > 3 ? encode(values.sublist(values.length - 3)) : const [];
  }

  static void recordError(String sourceName, Object error, {String secret = ''}) {
    source = sourceName;
    fetchAtUtc = DateTime.now().toUtc();
    totalValues = 0;
    rawHead = const [];
    rawTail = const [];
    lastError = sanitize(error.toString(), secret: secret);
  }

  static void clear() {
    requestedInterval = null;
    source = null;
    fetchAtUtc = null;
    totalValues = 0;
    rawHead = const [];
    rawTail = const [];
    lastError = null;
  }

  /// Parses raw entries (pre-parse JSON text) into (time, open, close).
  static List<(DateTime, double, double)> _parseRaw(List<String> raw) {
    final out = <(DateTime, double, double)>[];
    for (final r in raw) {
      try {
        final m = jsonDecode(r) as Map;
        final dt = '${m['datetime']}';
        final t = DateTime.tryParse(dt.replaceFirst(' ', 'T') +
            (RegExp(r'(Z|[+-]\d\d:?\d\d)$').hasMatch(dt) ? '' : 'Z'));
        final o = double.tryParse('${m['open']}');
        final c = double.tryParse('${m['close']}');
        if (t != null && o != null && c != null) out.add((t.toUtc(), o, c));
      } catch (_) {}
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// Open minus previous close for consecutive captured bars (UTC times),
  /// computed from the raw values as received. Descriptive only: it does
  /// not say the provider is wrong, and no value is altered.
  static List<String> openVsPrevCloseLines() {
    final lines = <String>[];
    for (final group in [rawHead, rawTail]) {
      final bars = _parseRaw(group);
      for (var i = 1; i < bars.length; i++) {
        if (bars[i].$1.difference(bars[i - 1].$1).inMinutes > 5) continue;
        final d = bars[i].$2 - bars[i - 1].$3;
        lines.add('${bars[i].$1.toIso8601String()} open - prev close '
            '(${bars[i - 1].$1.toIso8601String()}) = ${d.toStringAsFixed(5)}');
      }
    }
    return lines.isEmpty
        ? const ['none (fewer than 2 adjacent raw bars captured)']
        : lines;
  }

  /// Newest captured raw bar as (UTC time, close), or null.
  static (DateTime, double)? newestRawClose() {
    final bars = _parseRaw([...rawHead, ...rawTail]);
    if (bars.isEmpty) return null;
    return (bars.last.$1, bars.last.$3);
  }

  /// Duration of the interval that was actually requested ('5min', '15min',
  /// '1h', '4h', '1day'), or null when unknown. Never assumed.
  static Duration? intervalDuration([String? code]) {
    final c = code ?? requestedInterval;
    if (c == null) return null;
    final m = RegExp(r'^(\d+)(min|h|day)$').firstMatch(c);
    if (m == null) return null;
    final n = int.parse(m.group(1)!);
    return switch (m.group(2)) {
      'min' => Duration(minutes: n),
      'h' => Duration(hours: n),
      _ => Duration(days: n),
    };
  }

  /// Compact-chart source label lives here instead of covering candles.
  /// This describes captured provider data, not an XM360 parity claim.
  static String latestBarStatus({DateTime? now}) {
    final newest = newestRawClose();
    final duration = intervalDuration();
    if (newest == null || duration == null) {
      return 'Last candle open/delay: unknown (no captured bar or interval). '
          'Candles: Twelve Data OHLC. Live bid/ask: Swissquote, separate feed.';
    }
    final delayed = (now ?? DateTime.now()).toUtc()
        .isAfter(newest.$1.add(duration * 2));
    return 'Last candle open (UTC): ${newest.$1.toIso8601String()}; '
        'delayed: ${delayed ? "yes" : "no"} (more than two requested intervals). '
        'Candles: Twelve Data OHLC. Live bid/ask: Swissquote, separate feed. '
        'No invented gap-fill bars.';
  }

  /// One line per captured raw bar: closed or still forming at fetch time,
  /// from bar start + the REQUESTED interval versus the fetch clock. A bar
  /// still forming at fetch will keep changing, so comparing it with a
  /// finished bar elsewhere is not a like-for-like check.
  static List<String> barStatusLines() {
    final d = intervalDuration();
    final at = fetchAtUtc;
    if (d == null || at == null) {
      return const ['bar status: unknown (interval or fetch time not recorded)'];
    }
    final bars = _parseRaw([...rawHead, ...rawTail]);
    return [
      'requested interval: $requestedInterval',
      for (final b in bars)
        '${b.$1.toIso8601String()} ${b.$1.add(d).isAfter(at) ? 'FORMING at fetch (closes ${b.$1.add(d).toIso8601String()})' : 'closed at fetch'}',
    ];
  }
}
