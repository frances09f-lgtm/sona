import 'package:sqflite/sqflite.dart';

/// Atomic device-wide event claims, shared by foreground and worker isolates.
/// Close IDs are immutable, so these tombstones deliberately do not expire.
class NotificationClaims {
  static Future<Database> _database() async {
    final directory = await getDatabasesPath();
    return openDatabase(
      '$directory/sona_notifications_v1.db',
      version: 1,
      onCreate: (db, version) => db.execute(
        'CREATE TABLE events(event_key TEXT PRIMARY KEY, claimed_at INTEGER NOT NULL)',
      ),
    );
  }

  static Future<bool> claim(String key) async {
    final db = await _database();
    return db.transaction((tx) async {
      await tx.rawInsert(
        'INSERT OR IGNORE INTO events(event_key, claimed_at) VALUES (?, ?)',
        [key, DateTime.now().millisecondsSinceEpoch],
      );
      final rows = await tx.rawQuery('SELECT changes() AS affected');
      return rows.single['affected'] == 1;
    });
  }
}
