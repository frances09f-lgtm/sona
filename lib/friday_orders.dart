import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// What the Friday order runner needs from Sona's app state. AppState is
/// adapted to this in main.dart; tests use a fake.
abstract class PaperDesk {
  bool get unlocked;

  /// A PIN is saved, so Sona is (or will be) unlocking by itself.
  bool get hasSavedPin;
  bool get priceFresh;
  List<Map<String, dynamic>> get positions;
  Future<void> refreshPrice();
  Future<void> refreshAccount();

  /// Sona's own manual-order path. Null = submitted; otherwise the reason.
  Future<String?> openPaper(String dir, double qty, double? tp, double? sl);

  /// Sona's own manual-close path ('closed', 'closed:+$1.00', or a reason).
  Future<String?> closePaper(Map<String, dynamic> t, {String? reason});
  String? marketClosed();
}

/// Executes ONE paper order Friday handed to Sona's bridge provider
/// (OroBridgeProvider "fridayTradeSubmit"), exactly once, through Sona's
/// own openPaper/closePaper, and writes the result Friday reads back.
///
/// Paper trading only. The order is consumed before execution, so a crash
/// or a second resume can never place it twice; Friday then reports an
/// unknown outcome instead of resending.
class FridayOrders {
  FridayOrders(
    this.prefs,
    this.desk, {
    int Function()? nowMs,
    this.step = const Duration(milliseconds: 250),
    this.unlockWait = const Duration(seconds: 20),
    this.priceWait = const Duration(seconds: 12),
  }) : _nowMs = nowMs ?? (() => DateTime.now().millisecondsSinceEpoch);

  static const orderKey = 'oro_friday_order';
  static const resultKey = 'oro_friday_result';
  static const maxAgeMs = 60000;
  static const closeReason = 'Closed from Friday';

  final SharedPreferences prefs;
  final PaperDesk desk;
  final int Function() _nowMs;
  final Duration step;
  final Duration unlockWait;
  final Duration priceWait;
  bool _running = false;

  /// Runs the waiting order, if any. True when a fresh order from Friday was
  /// executed (or refused) just now, so Sona can hand the screen back.
  Future<bool> processPending() async {
    if (_running) return false;
    _running = true;
    try {
      // The provider writes natively; refresh the Dart-side cache first.
      await prefs.reload();
      final raw = prefs.getString(orderKey);
      if (raw == null) return false;
      Map<String, dynamic> order;
      try {
        order = Map<String, dynamic>.from(jsonDecode(raw) as Map);
      } catch (_) {
        await prefs.remove(orderKey);
        return false;
      }
      // Consume first: exactly once.
      await prefs.remove(orderKey);
      final id = order['id']?.toString() ?? '';
      if (id.isEmpty) return false;
      final received = (order['receivedAt'] as num?)?.toInt() ?? 0;
      final age = _nowMs() - received;
      if (received <= 0 || age > maxAgeMs || age < -5000) {
        await _write(id, 'rejected',
            message: 'The order from Friday expired before Sona could run it. Nothing was placed.');
        return false;
      }
      await _write(id, 'working');
      try {
        await _execute(id, order);
      } catch (_) {
        await _write(id, 'rejected',
            message: 'Sona hit an error. Open Sona to check your positions before trying again.');
      }
      return true;
    } finally {
      _running = false;
    }
  }

  Future<void> _execute(String id, Map<String, dynamic> order) async {
    final ready = await _ready();
    if (ready != null) {
      await _write(id, 'rejected', message: ready);
      return;
    }
    if (order['op'] == 'open') {
      final side = order['side']?.toString() ?? '';
      final qty = (order['qty'] as num?)?.toDouble();
      final tp = (order['tp'] as num?)?.toDouble();
      final sl = (order['sl'] as num?)?.toDouble();
      if (!['buy', 'sell'].contains(side) || qty == null || !qty.isFinite || qty <= 0) {
        await _write(id, 'rejected', message: 'The order from Friday was incomplete. Nothing was placed.');
        return;
      }
      final before = {
        for (final p in desk.positions)
          if (p['status'] == 'open') p['id'].toString()
      };
      final err = await desk.openPaper(side, qty, tp, sl);
      if (err != null) {
        await _write(id, 'rejected', message: err);
        return;
      }
      final opened = desk.positions
          .where((p) => p['status'] == 'open' && !before.contains(p['id'].toString()))
          .toList();
      if (opened.isEmpty) {
        await _write(id, 'done',
            message: 'Sona submitted the order but could not read it back yet. Open Sona to see it.');
        return;
      }
      final p = opened.last;
      await _write(id, 'done', extra: {
        'fill': {
          'id': p['id']?.toString(),
          'side': p['direction'],
          'qty': p['qty'],
          'entry': p['entry'],
          'tp': p['tp'],
          'sl': p['sl'],
        },
      });
      return;
    }
    if (order['op'] == 'close') {
      final ids = [for (final v in (order['ids'] as List? ?? const [])) v.toString()];
      if (ids.isEmpty) {
        await _write(id, 'rejected', message: 'No trade was named to close. Nothing was closed.');
        return;
      }
      final closed = <Map<String, dynamic>>[];
      final failed = <Map<String, dynamic>>[];
      for (final tid in ids) {
        final t = desk.positions
            .where((p) => p['id'].toString() == tid)
            .firstOrNull;
        if (t == null || t['status'] != 'open') {
          failed.add({'id': tid, 'side': t?['direction'], 'qty': t?['qty'], 'reason': 'already closed or not found'});
          continue;
        }
        final r = await desk.closePaper(t, reason: closeReason);
        if (r != null && r.startsWith('closed')) {
          final after = desk.positions
              .where((p) => p['id'].toString() == tid)
              .firstOrNull;
          closed.add({
            'id': tid,
            'side': t['direction'],
            'qty': t['qty'],
            'entry': t['entry'],
            'exit': after?['exit'],
            'pnl': after?['pnl'],
          });
        } else {
          failed.add({
            'id': tid,
            'side': t['direction'],
            'qty': t['qty'],
            'reason': r ?? 'a close for this trade is already in progress',
          });
        }
      }
      if (closed.isEmpty) {
        await _write(id, 'rejected',
            message: failed.length == 1
                ? '${failed.first['reason']}'
                : 'None of the trades were closed.',
            extra: {'failed': failed});
      } else {
        await _write(id, 'done', extra: {'closed': closed, 'failed': failed});
      }
      return;
    }
    await _write(id, 'rejected', message: 'Unknown order from Friday. Nothing was done.');
  }

  /// Null when unlocked with a fresh quote; otherwise why not.
  Future<String?> _ready() async {
    if (!desk.unlocked) {
      if (!desk.hasSavedPin) {
        return 'Sona is locked. Open Sona, unlock your paper account with your PIN, then ask Friday again.';
      }
      final until = DateTime.now().add(unlockWait);
      while (!desk.unlocked && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(step);
      }
      if (!desk.unlocked) {
        return 'Sona could not unlock your paper account (check the internet connection). Nothing was done.';
      }
    }
    if (!desk.priceFresh) {
      final closed = desk.marketClosed();
      if (closed != null) return closed;
      await desk.refreshPrice();
      final until = DateTime.now().add(priceWait);
      while (!desk.priceFresh && DateTime.now().isBefore(until)) {
        await Future<void>.delayed(step);
      }
      if (!desk.priceFresh) {
        return desk.marketClosed() ??
            'Sona has no fresh live gold price right now. Nothing was done.';
      }
    }
    return null;
  }

  Future<void> _write(String id, String status,
      {String? message, Map<String, dynamic>? extra}) async {
    await prefs.setString(
      resultKey,
      jsonEncode({
        'id': id,
        'status': status,
        if (message != null) 'message': message,
        ...?extra,
        'at': _nowMs(),
      }),
    );
  }
}
