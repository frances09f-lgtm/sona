import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// A provider daily-session open, independent of the chart's loaded window.
class ProviderDayOpen {
  final double open;
  final String sessionDate, exchangeTimezone;
  const ProviderDayOpen(this.open, this.sessionDate, this.exchangeTimezone);
  static bool _zonesReady = false;
  static String dateAt(DateTime now, String zone) {
    if (!_zonesReady) {
      tzdata.initializeTimeZones();
      _zonesReady = true;
    }
    final d = tz.TZDateTime.from(now, tz.getLocation(zone));
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  bool currentAt(DateTime now) => dateAt(now, exchangeTimezone) == sessionDate;
  double? percent(double price, DateTime now, {required bool fresh}) =>
      fresh && currentAt(now) && price.isFinite && price > 0
      ? (price - open) / open * 100
      : null;
}

class ProviderDayOpenService {
  final http.Client client;
  final DateTime Function() now;
  ProviderDayOpenService({http.Client? client, DateTime Function()? now})
    : client = client ?? http.Client(),
      now = now ?? DateTime.now;
  ProviderDayOpen? _cached;
  String? _key;
  DateTime? _failedAt;
  Future<ProviderDayOpen?>? _pending;

  Future<ProviderDayOpen?> load(String apiKey) async {
    if (_key != apiKey) {
      _cached = null;
      _failedAt = null;
      _pending = null;
      _key = apiKey;
    }
    if (apiKey.isEmpty) return null;
    final at = now();
    if (_cached?.currentAt(at) == true) return _cached;
    _cached = null; // Yesterday must never masquerade as today's reference.
    if (_failedAt != null &&
        at.difference(_failedAt!) < const Duration(minutes: 5))
      return null;
    if (_pending != null) return _pending;
    final future = _fetch(apiKey, at);
    _pending = future;
    try {
      return await future;
    } finally {
      if (identical(_pending, future)) _pending = null;
    }
  }

  Future<ProviderDayOpen?> _fetch(String apiKey, DateTime at) async {
    try {
      // Daily timezone is defined by the provider, not the intraday UTC option.
      final uri = Uri.https('api.twelvedata.com', '/time_series', {
        'symbol': 'XAU/USD',
        'interval': '1day',
        'outputsize': '2',
        'apikey': apiKey,
      });
      final response = await client
          .get(uri)
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200)
        throw const FormatException('reference unavailable');
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      final zone = (body['meta'] as Map?)?['exchange_timezone'];
      if (zone is! String || zone.isEmpty)
        throw const FormatException('reference timezone missing');
      final today = ProviderDayOpen.dateAt(at, zone);
      for (final row in (body['values'] as List)) {
        if (row is! Map || row['datetime'] != today) continue;
        final open = double.tryParse('${row['open']}');
        if (open == null || !open.isFinite || open <= 0) continue;
        final ref = ProviderDayOpen(open, today, zone);
        // Do not cache a response across midnight while the request was in flight.
        if (_key == apiKey && ref.currentAt(now())) {
          _cached = ref;
          _failedAt = null;
          return ref;
        }
      }
    } catch (_) {
      /* no secrets or provider payload in UI/logs */
    }
    if (_key == apiKey) _failedAt = now();
    return null;
  }
}
