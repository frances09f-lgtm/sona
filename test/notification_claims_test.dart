import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sona/notification_claims.dart';
import 'package:sona/notifications.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final directory = await Directory.systemTemp.createTemp('sona-notify-test');
    await databaseFactory.setDatabasesPath(directory.path);
  });
  test('12 concurrent same-event claims have exactly one winner', () async {
    final result = await Future.wait(
      List.generate(12, (_) => NotificationClaims.claim('close:simultaneous')),
    );
    expect(result.where((x) => x).length, 1);
    expect(await NotificationClaims.claim('close:simultaneous'), isFalse);
    expect(await NotificationClaims.claim('close:other'), isTrue);
  });
  test(
    'explicit open snapshot preserves delayed genuine close without cutoff',
    () {
      final result = newlyClosedPositions(
        prev: [
          {'id': 'delayed', 'status': 'open'},
        ],
        positions: [
          {
            'id': 'delayed',
            'status': 'closed',
            'closed_at': '2026-11-01T00:00:00Z',
          },
        ],
        closedIds: {},
        lastRun: DateTime.utc(2026, 11, 5),
      );
      expect(result.length, 1);
    },
  );
}
