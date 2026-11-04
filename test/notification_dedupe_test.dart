import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/notifications.dart';

Map<String, dynamic> pos(
  String id,
  String status, {
  String direction = 'sell',
  double qty = 1.0,
  String? closedAt,
}) => {
  'id': id,
  'status': status,
  'direction': direction,
  'qty': qty,
  'closed_at': ?closedAt,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('encodeOpenPositionsSnapshot', () {
    test('stores open positions only, with status field', () {
      final snap = encodeOpenPositionsSnapshot([
        pos('a', 'open'),
        pos('b', 'closed', closedAt: '2026-11-04T10:00:00Z'),
        pos('c', 'open'),
      ]);
      final list = (jsonDecode(snap) as List).cast<Map<String, dynamic>>();
      expect(list.map((e) => e['id']), ['a', 'c']);
      expect(list.every((e) => e['status'] == 'open'), isTrue);
    });
  });

  group('parseServerTs', () {
    test('treats suffix-less timestamps as UTC', () {
      final t = parseServerTs('2026-11-04T10:00:00');
      expect(t, isNotNull);
      expect(t!.isUtc, isTrue);
    });
    test('parses Z and offset forms', () {
      expect(parseServerTs('2026-11-04T10:00:00Z')!.isUtc, isTrue);
      expect(parseServerTs('2026-11-04T10:00:00+00:00'), isNotNull);
    });
    test('null/empty -> null', () {
      expect(parseServerTs(null), isNull);
      expect(parseServerTs(''), isNull);
    });
  });

  group('newlyClosedPositions', () {
    final lastRun = DateTime.utc(2026, 11, 4, 10, 0);

    test('positions already closed at snapshot time never re-notify', () {
      // Legacy snapshot writers stored the FULL history (closed included,
      // some without a status field). None of these may notify.
      final prev = [
        pos('old1', 'closed'), // closed at snapshot
        {
          'id': 'old2',
          'direction': 'sell',
          'qty': 1.0,
        }, // no status (old writer)
      ];
      final positions = [
        pos('old1', 'closed', closedAt: '2026-11-01T08:00:00Z'),
        pos('old2', 'closed', closedAt: '2026-11-02T08:00:00Z'),
      ];
      final out = newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: {},
        lastRun: lastRun,
      );
      expect(out, isEmpty);
    });

    test('a genuine close after lastRun notifies exactly once', () {
      final prev = [pos('a', 'open'), pos('b', 'open')];
      final positions = [
        pos('a', 'open'),
        pos('b', 'closed', closedAt: '2026-11-04T10:05:00'),
      ];
      final out = newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: {},
        lastRun: lastRun,
      );
      expect(out.map((e) => e['id']), ['b']);
    });

    test('close before lastRun (while worker asleep) is not re-reported '
        'once the snapshot has caught up', () {
      final prev = [
        {'id': 'a'},
      ];
      final positions = [pos('a', 'closed', closedAt: '2026-11-04T09:00:00Z')];
      final out = newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: {},
        lastRun: lastRun,
      );
      expect(out, isEmpty);
    });

    test('close just before lastRun inside grace still reported '
        '(delayed genuine close is not silently lost)', () {
      final prev = [pos('a', 'open')];
      final positions = [
        // stamped 5 min before lastRun: stale fetch or clock skew
        pos('a', 'closed', closedAt: '2026-11-04T09:55:00Z'),
      ];
      final out = newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: {},
        lastRun: lastRun,
      );
      expect(out.map((e) => e['id']), ['a']);
    });

    test('close clearly before the grace window is old news', () {
      final prev = [
        {'id': 'a'},
      ];
      final positions = [
        pos('a', 'closed', closedAt: '2026-11-04T09:30:00Z'), // 30 min prior
      ];
      final out = newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: {},
        lastRun: lastRun,
      );
      expect(out, isEmpty);
    });

    test('worker-just-closed ids are excluded', () {
      final prev = [pos('a', 'open')];
      final positions = [pos('a', 'closed', closedAt: '2026-11-04T10:05:00Z')];
      final out = newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: {'a'},
        lastRun: lastRun,
      );
      expect(out, isEmpty);
    });

    test('position missing from current history cannot be verified', () {
      final prev = [pos('gone', 'open')];
      final out = newlyClosedPositions(
        prev: prev,
        positions: const [],
        closedIds: {},
        lastRun: lastRun,
      );
      expect(out, isEmpty);
    });

    test('duplicate prev ids collapse to one entry', () {
      final prev = [pos('a', 'open'), pos('a', 'open')];
      final positions = [pos('a', 'closed', closedAt: '2026-11-04T10:05:00Z')];
      final out = newlyClosedPositions(
        prev: prev,
        positions: positions,
        closedIds: {},
        lastRun: lastRun,
      );
      expect(out.length, 1);
    });
  });

  group('notified store', () {
    test('per-key add/has survives a second writer (cross-isolate)', () async {
      // Two SharedPreferences instances simulate the app isolate and the
      // WorkManager isolate: writes from one must not lose the other's.
      SharedPreferences.setMockInitialValues({});
      final appPrefs = await SharedPreferences.getInstance();
      await notifiedAdd(appPrefs, 'close:1');

      final workerPrefs = await SharedPreferences.getInstance();
      await workerPrefs.reload();
      await notifiedAdd(workerPrefs, 'close:2');

      await appPrefs.reload();
      expect(notifiedHas(appPrefs, 'close:1'), isTrue);
      expect(notifiedHas(appPrefs, 'close:2'), isTrue);
      expect(notifiedHas(appPrefs, 'close:3'), isFalse);
    });

    test(
      'legacy tj_notified map entries are still honored (7-day window)',
      () async {
        final recent = DateTime.now()
            .subtract(const Duration(days: 2))
            .toIso8601String();
        final ancient = DateTime.now()
            .subtract(const Duration(days: 10))
            .toIso8601String();
        SharedPreferences.setMockInitialValues({
          'tj_notified': jsonEncode({'close:x': recent, 'close:y': ancient}),
        });
        final prefs = await SharedPreferences.getInstance();
        expect(notifiedHas(prefs, 'close:x'), isTrue);
        expect(notifiedHas(prefs, 'close:y'), isFalse); // pruned window
        expect(notifiedHas(prefs, 'close:z'), isFalse);
      },
    );

    test('per-key mark wins over an absent legacy entry', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      await notifiedAdd(prefs, 'alert:1');
      await prefs.reload();
      expect(notifiedHas(prefs, 'alert:1'), isTrue);
    });

    test('unnotifiedOnly drops events claimed by the other isolate '
        'between check and post', () async {
      SharedPreferences.setMockInitialValues({});
      final workerPrefs = await SharedPreferences.getInstance();
      final pending = <(String, int, String, String)>[
        ('close:1', 1, 'Sona: position closed', 'Sell XAU/USD x1.00'),
        ('close:2', 2, 'Sona: position closed', 'Buy XAU/USD x1.00'),
      ];
      // The app isolate marks close:1 after the worker's first read.
      final appPrefs = await SharedPreferences.getInstance();
      await appPrefs.reload();
      await notifiedAdd(appPrefs, 'close:1');

      final fresh = await unnotifiedOnly(workerPrefs, pending);
      expect(fresh.map((e) => e.$1), ['close:2']);
    });

    test('notifiedPrune drops marks older than 30 days only', () async {
      SharedPreferences.setMockInitialValues({
        'tj_notified:close:old': DateTime.now()
            .subtract(const Duration(days: 31))
            .toIso8601String(),
        'tj_notified:close:new': DateTime.now().toIso8601String(),
        'unrelated': 'keep',
      });
      final prefs = await SharedPreferences.getInstance();
      await notifiedPrune(prefs);
      expect(prefs.getString('tj_notified:close:old'), isNull);
      expect(prefs.getString('tj_notified:close:new'), isNotNull);
      expect(prefs.getString('unrelated'), 'keep');
    });
  });
}
