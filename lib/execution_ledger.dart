import 'package:sqflite/sqflite.dart';

/// Device-wide atomic claims shared by UI and WorkManager isolates. A timeout
/// is deliberately NOT retried: the server may already have accepted the close.
/// Cross-device/true always-on execution still requires the backend adapter.
class ExecutionLedger {
  static Future<Database> _database() async {
    final directory = await getDatabasesPath();
    return openDatabase(
      '$directory/sona_execution_v1.db',
      version: 1,
      onCreate: (db, version) => db.execute('''CREATE TABLE closes(
        position_id TEXT PRIMARY KEY, state TEXT NOT NULL,
        quote_at INTEGER NOT NULL, fill REAL NOT NULL,
        reason TEXT NOT NULL, observed_at INTEGER NOT NULL)'''),
    );
  }

  static Future<bool> claim(
    String id,
    int quoteAt,
    double fill,
    String reason,
  ) async {
    final db = await _database();
    return db.transaction((tx) async {
      final old = await tx.query(
        'closes',
        where: 'position_id = ?',
        whereArgs: [id],
      );
      if (old.isNotEmpty) return false;
      await tx.insert('closes', {
        'position_id': id,
        'state': 'pending',
        'quote_at': quoteAt,
        'fill': fill,
        'reason': reason,
        'observed_at': DateTime.now().millisecondsSinceEpoch,
      });
      return true;
    });
  }

  static Future<void> confirmed(String id) async {
    final db = await _database();
    await db.update(
      'closes',
      {'state': 'confirmed'},
      where: 'position_id = ?',
      whereArgs: [id],
    );
  }

  static Future<void> rejected(String id) async {
    final db = await _database();
    await db.delete(
      'closes',
      where: 'position_id = ? AND state = ?',
      whereArgs: [id, 'pending'],
    );
  }

  static Future<void> reconcile(List<Map<String, dynamic>> positions) async {
    for (final position in positions) {
      if (position['status'] == 'closed')
        await confirmed(position['id'].toString());
    }
  }

  static Future<int> pendingCount() async {
    final db = await _database();
    return Sqflite.firstIntValue(
          await db.rawQuery(
            "SELECT count(*) FROM closes WHERE state = 'pending'",
          ),
        ) ??
        0;
  }
}
