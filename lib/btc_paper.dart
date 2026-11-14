import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// On-device BTC/USDT paper practice ledger.
///
/// Fully separate from the synced gold paper account (Supabase): BTC
/// positions, balance and history live only under [_prefsKey] on this phone.
/// No gold storage key, journal, position list or stat is ever touched.
class BtcPaperState extends ChangeNotifier {
  static const String _prefsKey = 'sona_btc_paper_v1';
  static const double leverage = 500.0;
  static const double startBalance = 10000.0;
  static const double minQty = 0.001;
  static const double qtyStep = 0.001;
  static const int maxHistory = 100;

  double balance = startBalance; // realized equity, USDT
  List<Map<String, dynamic>> positions = []; // open first, closed appended

  bool _loaded = false;
  bool get loaded => _loaded;

  Future<void> load(SharedPreferences prefs) async {
    final raw = prefs.getString(_prefsKey);
    if (raw != null) {
      try {
        final j = jsonDecode(raw) as Map<String, dynamic>;
        final b = (j['balance'] as num?)?.toDouble();
        final ps = (j['positions'] as List?)
            ?.whereType<Map>()
            .map((e) => Map<String, dynamic>.from(e))
            .toList();
        if (b != null && b.isFinite && ps != null) {
          balance = b;
          positions = ps;
        }
      } catch (_) {
        // Corrupt local state must never block the panel: start fresh.
        balance = startBalance;
        positions = [];
      }
    }
    _loaded = true;
    notifyListeners();
  }

  Future<void> _save(SharedPreferences prefs) async {
    final closed = positions.where((p) => p['status'] == 'closed').toList();
    final trimmedClosed = closed.length > maxHistory
        ? closed.sublist(closed.length - maxHistory)
        : closed;
    positions = [
      ...positions.where((p) => p['status'] == 'open'),
      ...trimmedClosed,
    ];
    await prefs.setString(
      _prefsKey,
      jsonEncode({'balance': balance, 'positions': positions}),
    );
  }

  List<Map<String, dynamic>> get openPositions =>
      positions.where((p) => p['status'] == 'open').toList();
  List<Map<String, dynamic>> get history {
    final closed =
        positions.where((p) => p['status'] == 'closed').toList();
    closed.sort(
      (a, b) => ((b['closedAt'] as num?) ?? 0)
          .compareTo((a['closedAt'] as num?) ?? 0),
    );
    return closed;
  }

  double floatingPnl(double bid, double ask) {
    var sum = 0.0;
    for (final p in openPositions) {
      final qty = (p['qty'] as num).toDouble();
      final entry = (p['entry'] as num).toDouble();
      final exit = p['direction'] == 'buy' ? bid : ask;
      sum += (p['direction'] == 'buy' ? exit - entry : entry - exit) * qty;
    }
    return sum;
  }

  double usedMargin() {
    var used = 0.0;
    for (final p in openPositions) {
      used += (p['entry'] as num).toDouble() * (p['qty'] as num).toDouble() /
          leverage;
    }
    return used;
  }

  double equity(double bid, double ask) => balance + floatingPnl(bid, ask);
  double free(double bid, double ask) => equity(bid, ask) - usedMargin();

  String? _validateProtection(
    String dir,
    double entry,
    double? tp,
    double? sl,
  ) {
    if (tp != null) {
      final ok = dir == 'buy' ? tp > entry : tp < entry;
      if (!ok) {
        return dir == 'buy'
            ? 'Take profit for a buy must be above the entry price.'
            : 'Take profit for a sell must be below the entry price.';
      }
    }
    if (sl != null) {
      final ok = dir == 'buy' ? sl < entry : sl > entry;
      if (!ok) {
        return dir == 'buy'
            ? 'Stop loss for a buy must be below the entry price.'
            : 'Stop loss for a sell must be above the entry price.';
      }
    }
    return null;
  }

  /// Opens a local BTC practice position at the live side price.
  /// Returns an error string, or null on success.
  String? open(
    SharedPreferences prefs,
    String dir,
    double qty,
    double? tp,
    double? sl,
    double bid,
    double ask,
  ) {
    if (!['buy', 'sell'].contains(dir)) return 'Enter a valid side.';
    if (!qty.isFinite || qty < minQty - 1e-12) {
      return 'Minimum size is $minQty BTC (steps of $qtyStep).';
    }
    // Refuse non-step sizes instead of silently changing the user's size.
    final steps = qty / qtyStep;
    if ((steps - steps.roundToDouble()).abs() > 1e-9) {
      return 'Size must be in steps of $qtyStep BTC.';
    }
    qty = steps.roundToDouble() * qtyStep;
    if (bid <= 0 || ask < bid) return 'No fresh BTC price - try again.';
    final px = dir == 'buy' ? ask : bid;
    final protectionError = _validateProtection(dir, px, tp, sl);
    if (protectionError != null) return protectionError;
    final required = px * qty / leverage;
    final avail = free(bid, ask);
    if (required > avail) {
      return 'Not enough practice margin: needs ${required.toStringAsFixed(2)} USDT, '
          'available ${avail.toStringAsFixed(2)} USDT at 1:500. Reduce the BTC size.';
    }
    positions.insert(0, {
      'id': DateTime.now().millisecondsSinceEpoch.toString(),
      'status': 'open',
      'direction': dir,
      'qty': qty,
      'entry': px,
      'tp': tp,
      'sl': sl,
      'openedAt': DateTime.now().millisecondsSinceEpoch,
      'instrument': 'BTC/USDT',
    });
    _save(prefs);
    notifyListeners();
    return null;
  }

  String? close(
    SharedPreferences prefs,
    String id,
    double bid,
    double ask, {
    String reason = 'Manual close',
  }) {
    final i = positions.indexWhere(
      (p) => p['id'] == id && p['status'] == 'open',
    );
    if (i < 0) return null; // already closed
    final p = positions[i];
    final exit = p['direction'] == 'buy' ? bid : ask;
    final qty = (p['qty'] as num).toDouble();
    final entry = (p['entry'] as num).toDouble();
    final pnl =
        (p['direction'] == 'buy' ? exit - entry : entry - exit) * qty;
    balance += pnl;
    positions[i] = {
      ...p,
      'status': 'closed',
      'exit': exit,
      'pnl': pnl,
      'closedAt': DateTime.now().millisecondsSinceEpoch,
      'closeReason': reason,
    };
    _save(prefs);
    notifyListeners();
    return null;
  }

  /// TP/SL watchdog: runs on every fresh BTC tick while the panel is live.
  /// Buy positions exit at bid; sell positions exit at ask.
  List<String> checkTpsl(SharedPreferences prefs, double bid, double ask) {
    final closedNow = <String>[];
    for (final p in openPositions) {
      final tp = (p['tp'] as num?)?.toDouble();
      final sl = (p['sl'] as num?)?.toDouble();
      final exit = p['direction'] == 'buy' ? bid : ask;
      String? reason;
      if (tp != null &&
          (p['direction'] == 'buy' ? exit >= tp : exit <= tp)) {
        reason = 'Take profit hit';
      } else if (sl != null &&
          (p['direction'] == 'buy' ? exit <= sl : exit >= sl)) {
        reason = 'Stop loss hit';
      }
      if (reason != null) {
        close(prefs, p['id'] as String, bid, ask, reason: reason);
        closedNow.add(p['id'] as String);
      }
    }
    return closedNow;
  }
}
