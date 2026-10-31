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
  }) {
    source = sourceName;
    fetchAtUtc = DateTime.now().toUtc();
    totalValues = values.length;
    lastError = null;
    List<String> encode(Iterable<dynamic> items) => [
          for (final v in items)
            const JsonEncoder.withIndent('  ').convert(v),
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
    source = null;
    fetchAtUtc = null;
    totalValues = 0;
    rawHead = const [];
    rawTail = const [];
    lastError = null;
  }
}
