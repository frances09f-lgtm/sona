import 'package:flutter_test/flutter_test.dart';
import 'package:sona/journal_record.dart';
import 'package:sona/analytics.dart';

void main() {
  test('long and short net uses quantity and deducts costs once', () {
    expect(
      journalNet(side: 'buy', entry: 4000, exit: 4010, qty: 2, costs: 3),
      17,
    );
    expect(
      journalNet(side: 'sell', entry: 4000, exit: 3990, qty: .5, costs: 1),
      4,
    );
    expect(
      journalNet(side: 'buy', entry: 4001, exit: 4000, qty: 1, costs: 0),
      -1,
    );
    expect(
      journalNet(
        side: 'buy',
        entry: 4000,
        exit: 4010,
        qty: double.nan,
        costs: 1,
      ),
      isNull,
    );
  });
  test('journal envelope survives backend retaining only original fields', () {
    final original = <String, dynamic>{
      'id': 'a',
      'entry': 4000,
      'exit': 4010,
      'qty': 2.0,
      'costs': 3.0,
      'pnl': 17.0,
      'setup': 'Breakout',
      'pnl_mode': 'calculated',
      'note': 'Ω note\nOriginal',
    };
    final encoded = encodeJournal(original);
    expect(encoded.containsKey('qty'), isFalse);
    final decoded = decodeJournal(encoded);
    expect(decoded['qty'], 2);
    expect(decoded['costs'], 3);
    expect(decoded['note'], original['note']);
    expect(decoded['setup'], 'Breakout');
    expect(decoded['pnl'], 17);
    expect(decoded['size_known'], isTrue);
    expect(decodeJournal(encodeJournal(decoded))['note'], original['note']);
  });
  test('legacy records keep exact recorded pnl with unknown size', () {
    final legacy = decodeJournal({'id': 'old', 'pnl': 10.0, 'note': 'kept'});
    expect(legacy['pnl'], 10);
    expect(legacy['qty'], isNull);
    expect(legacy['size_known'], isFalse);
    expect(decodeJournal(encodeJournal(legacy))['qty'], isNull);
  });
  test('manual net override stays net, not charged twice', () {
    final data = decodeJournal(
      encodeJournal({
        'qty': 2.0,
        'costs': 3.0,
        'pnl': 17.0,
        'pnl_mode': 'manual',
        'note': '',
      }),
    );
    expect(data['pnl'], 17);
    expect(data['pnl_mode'], 'manual');
  });
  test('corrupt metadata is never stripped', () {
    const note = 'Keep this\n[sona-journal-v2:not-json]';
    expect(decodeJournal({'note': note})['note'], note);
  });
  test('separate sources date filters chronological drawdown and tags', () {
    final manual = [
      {
        'id': 'a',
        'pnl': 20,
        'traded_at': '2026-10-01T12:00:00Z',
        'setup': 'breakout',
        'qty': 2,
      },
      {
        'id': 'b',
        'pnl': -30,
        'traded_at': '2026-10-02T12:00:00Z',
        'setup': 'breakout',
        'qty': 2,
      },
      {'id': 'a', 'pnl': 20, 'traded_at': '2026-10-01T12:00:00Z'},
      {'id': 'bad', 'pnl': double.nan, 'traded_at': '2026-10-01T12:00:00Z'},
      {'id': 'noDate', 'pnl': 10},
    ];
    final paper = [
      {
        'id': 'p',
        'status': 'closed',
        'pnl': 50,
        'closed_at': '2026-10-03T12:00:00Z',
        'qty': 1,
      },
    ];
    expect(performanceRecords(manual, paper).single.pnl, 50);
    final records = performanceRecords(manual, paper, source: 'manual');
    expect(records.length, 2);
    expect(performanceBySetup(records)['breakout'], -10);
    expect(maxDrawdown(100, records.map((r) => r.pnl).toList()), 30);
    expect(
      performanceRecords(
        manual,
        paper,
        source: 'manual',
        from: DateTime.utc(2026, 10, 2),
      ).length,
      1,
    );
  });
  test('new ids are unique version4 UUIDs', () {
    final ids = List.generate(200, (_) => newJournalId());
    expect(ids.toSet().length, 200);
    expect(
      ids.every(
        (id) => RegExp(
          r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
        ).hasMatch(id),
      ),
      isTrue,
    );
  });
}
