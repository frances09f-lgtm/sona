import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:sona/execution_ledger.dart';

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    final path = await Directory.systemTemp.createTemp('sona-ledger-test');
    await databaseFactory.setDatabasesPath(path.path);
  });
  test(
    'concurrent claims submit only once and preserve uncertain outcomes',
    () async {
      final claims = await Future.wait(
        List.generate(
          12,
          (_) => ExecutionLedger.claim('same', 1000, 4000, 'SL hit'),
        ),
      );
      expect(claims.where((x) => x).length, 1);
      expect(await ExecutionLedger.pendingCount(), 1);
      expect(await ExecutionLedger.claim('same', 2000, 3990, 'retry'), isFalse);
      await ExecutionLedger.reconcile([
        {'id': 'same', 'status': 'closed'},
      ]);
      expect(await ExecutionLedger.pendingCount(), 0);
      expect(await ExecutionLedger.claim('same', 3000, 3990, 'retry'), isFalse);
    },
  );
  test('only a definite rejection releases a claim', () async {
    expect(
      await ExecutionLedger.claim('rejected', 1000, 4000, 'manual'),
      isTrue,
    );
    await ExecutionLedger.rejected('rejected');
    expect(
      await ExecutionLedger.claim('rejected', 1000, 4000, 'manual'),
      isTrue,
    );
    await ExecutionLedger.confirmed('rejected');
    await ExecutionLedger.rejected('rejected');
    expect(
      await ExecutionLedger.claim('rejected', 1000, 4000, 'manual'),
      isFalse,
    );
  });
}
