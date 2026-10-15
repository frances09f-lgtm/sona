import 'dart:math';
import 'dart:convert';

/// Additional fields round-trip through the existing journal's note column.
/// No backend column assumptions, and no guessed quantity on old records.
const _marker = '\n[sona-journal-v2:';
Map<String, dynamic> decodeJournal(Map<String, dynamic> raw) {
  final out = Map<String, dynamic>.from(raw);
  final note = raw['note']?.toString() ?? '';
  final index = note.lastIndexOf(_marker);
  if (index >= 0 && note.endsWith(']')) {
    try {
      final data = jsonDecode(
        utf8.decode(
          base64Url.decode(
            note.substring(index + _marker.length, note.length - 1),
          ),
        ),
      );
      if (data is Map &&
          data['schema'] == 2 &&
          (data['qty'] == null || positiveNumber(data['qty']) != null) &&
          finiteNumber(data['costs']) != null &&
          (data['costs'] as num) >= 0 &&
          data['setup'] is String &&
          ['manual', 'calculated'].contains(data['pnl_mode'])) {
        for (final key in ['schema', 'qty', 'costs', 'setup', 'pnl_mode']) {
          out[key] = data[key];
        }
        out['note'] = note.substring(0, index);
      }
    } catch (_) {
      /* Malformed metadata is retained verbatim. */
    }
  }
  out['size_known'] = positiveNumber(out['qty']) != null;
  return out;
}

Map<String, dynamic> encodeJournal(Map<String, dynamic> raw) {
  final out = Map<String, dynamic>.from(raw);
  final data = <String, dynamic>{
    'schema': 2,
    'qty': raw['qty'],
    'costs': raw['costs'] ?? 0,
    'setup': raw['setup'] ?? '',
    'pnl_mode': raw['pnl_mode'] ?? 'manual',
  };
  out['note'] =
      '${raw['note'] ?? ''}$_marker${base64Url.encode(utf8.encode(jsonEncode(data)))}]';
  for (final key in [
    'schema',
    'qty',
    'costs',
    'setup',
    'pnl_mode',
    'size_known',
  ]) {
    out.remove(key);
  }
  return out;
}

double? finiteNumber(dynamic n) =>
    n is num && n.toDouble().isFinite ? n.toDouble() : null;
double? positiveNumber(dynamic n) {
  final value = finiteNumber(n);
  return value != null && value > 0 ? value : null;
}

double? journalNet({
  required String side,
  required double entry,
  required double exit,
  required double qty,
  required double costs,
}) {
  if (!['buy', 'sell'].contains(side) ||
      !entry.isFinite ||
      entry <= 0 ||
      !exit.isFinite ||
      exit <= 0 ||
      !qty.isFinite ||
      qty <= 0 ||
      !costs.isFinite ||
      costs < 0)
    return null;
  final result = (exit - entry) * (side == 'buy' ? 1 : -1) * qty - costs;
  return result.isFinite ? result : null;
}

class PerformanceRecord {
  final String id, source, setup;
  final DateTime at;
  final double pnl;
  final bool sizeKnown;
  const PerformanceRecord(
    this.id,
    this.source,
    this.setup,
    this.at,
    this.pnl,
    this.sizeKnown,
  );
}

List<PerformanceRecord> performanceRecords(
  List<Map<String, dynamic>> trades,
  List<Map<String, dynamic>> positions, {
  String source = 'paper',
  DateTime? from,
  DateTime? through,
}) {
  final records = <PerformanceRecord>[];
  final seen = <String>{};
  final input = source == 'manual' ? trades : positions;
  for (final raw in input) {
    if (source != 'manual' && raw['status'] != 'closed') continue;
    final t = source == 'manual' ? decodeJournal(raw) : raw;
    final at = DateTime.tryParse(
      t[source == 'manual' ? 'traded_at' : 'closed_at']?.toString() ?? '',
    );
    final pnl = finiteNumber(t['pnl']);
    final id = t['id']?.toString() ?? '';
    if (id.isEmpty ||
        !seen.add(id) ||
        at == null ||
        pnl == null ||
        (from != null && at.isBefore(from)) ||
        (through != null && at.isAfter(through)))
      continue;
    records.add(
      PerformanceRecord(
        id,
        source,
        t['setup']?.toString() ?? '',
        at,
        pnl,
        positiveNumber(t['qty']) != null,
      ),
    );
  }
  records.sort((a, b) => a.at.compareTo(b.at));
  return records;
}

Map<String, double> performanceBySetup(List<PerformanceRecord> records) {
  final out = <String, double>{};
  for (final r in records) {
    final key = r.setup.trim().isEmpty ? 'Untagged' : r.setup.trim();
    out[key] = (out[key] ?? 0) + r.pnl;
  }
  return out;
}

String newJournalId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final h = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-${h.substring(16, 20)}-${h.substring(20)}';
}
