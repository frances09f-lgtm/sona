import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/friday_orders.dart';

class _Desk implements PaperDesk {
  @override
  bool unlocked = true;
  @override
  bool hasSavedPin = true;
  @override
  bool priceFresh = true;
  String? closedMsg;
  @override
  List<Map<String, dynamic>> positions = [];
  final opens = <List<Object?>>[];
  final closes = <String>[];
  String? openError;
  int _next = 100;
  @override
  Future<void> refreshPrice() async {}
  @override
  Future<void> refreshAccount() async {}
  @override
  Future<String?> openPaper(String dir, double qty, double? tp, double? sl) async {
    opens.add([dir, qty, tp, sl]);
    if (openError != null) return openError;
    positions = [
      ...positions,
      {'id': _next++, 'direction': dir, 'qty': qty, 'entry': 4120.4, 'tp': tp, 'sl': sl, 'status': 'open'},
    ];
    return null;
  }

  @override
  Future<String?> closePaper(Map<String, dynamic> t, {String? reason}) async {
    closes.add('${t['id']}:$reason');
    positions = [
      for (final p in positions)
        p['id'] == t['id'] ? {...p, 'status': 'closed', 'exit': 4125.0, 'pnl': 46.0} : p,
    ];
    return 'closed:+\$46.00';
  }

  @override
  String? marketClosed() => closedMsg;
}

const _now = 1800000000000;

Future<(FridayOrders, SharedPreferences, _Desk)> _setup(Map<String, dynamic>? order, {int age = 1000}) async {
  SharedPreferences.setMockInitialValues({
    if (order != null) FridayOrders.orderKey: jsonEncode({...order, 'receivedAt': _now - age}),
  });
  final prefs = await SharedPreferences.getInstance();
  final desk = _Desk();
  final runner = FridayOrders(prefs, desk,
      nowMs: () => _now,
      step: const Duration(milliseconds: 5),
      unlockWait: const Duration(milliseconds: 40),
      priceWait: const Duration(milliseconds: 40));
  return (runner, prefs, desk);
}

Map<String, dynamic> _result(SharedPreferences p) =>
    Map<String, dynamic>.from(jsonDecode(p.getString(FridayOrders.resultKey)!) as Map);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('open order runs through openPaper once and reports the fill', () async {
    final (r, prefs, desk) = await _setup({'id': 'f1', 'op': 'open', 'side': 'buy', 'qty': 10, 'tp': 4150, 'sl': 4100});
    expect(await r.processPending(), isTrue);
    expect(desk.opens, [['buy', 10.0, 4150.0, 4100.0]]);
    final res = _result(prefs);
    expect(res['id'], 'f1');
    expect(res['status'], 'done');
    expect(res['fill']['entry'], 4120.4);
    expect(res['fill']['qty'], 10.0);
    expect(prefs.getString(FridayOrders.orderKey), isNull);
    // Exactly once: a second resume finds nothing.
    expect(await r.processPending(), isFalse);
    expect(desk.opens.length, 1);
  });

  test("Sona's own rejection is passed back verbatim", () async {
    final (r, prefs, desk) = await _setup({'id': 'f2', 'op': 'open', 'side': 'sell', 'qty': 5});
    desk.openError = 'Stop loss must be above entry.';
    await r.processPending();
    expect(_result(prefs)['status'], 'rejected');
    expect(_result(prefs)['message'], 'Stop loss must be above entry.');
  });

  test('locked without a PIN: refuses, places nothing', () async {
    final (r, prefs, desk) = await _setup({'id': 'f3', 'op': 'open', 'side': 'buy', 'qty': 1});
    desk.unlocked = false;
    desk.hasSavedPin = false;
    await r.processPending();
    expect(desk.opens, isEmpty);
    expect(_result(prefs)['message'], contains('Sona is locked'));
  });

  test('market closed / stale price: refuses, places nothing', () async {
    final (r, prefs, desk) = await _setup({'id': 'f4', 'op': 'open', 'side': 'buy', 'qty': 1});
    desk.priceFresh = false;
    desk.closedMsg = 'Market closed for the weekend - reopens Mon 3:30 AM';
    await r.processPending();
    expect(desk.opens, isEmpty);
    expect(_result(prefs)['message'], startsWith('Market closed'));
    final (r2, prefs2, desk2) = await _setup({'id': 'f5', 'op': 'open', 'side': 'buy', 'qty': 1});
    desk2.priceFresh = false;
    await r2.processPending();
    expect(desk2.opens, isEmpty);
    expect(_result(prefs2)['message'], contains('no fresh live gold price'));
  });

  test('expired order is refused and does not hand the screen back', () async {
    final (r, prefs, desk) = await _setup({'id': 'f6', 'op': 'open', 'side': 'buy', 'qty': 1}, age: 120000);
    expect(await r.processPending(), isFalse);
    expect(desk.opens, isEmpty);
    expect(_result(prefs)['status'], 'rejected');
    expect(_result(prefs)['message'], contains('expired'));
  });

  test('close closes exactly the confirmed ids', () async {
    final (r, prefs, desk) = await _setup({'id': 'f7', 'op': 'close', 'ids': ['7', '9']});
    desk.positions = [
      {'id': 7, 'direction': 'buy', 'qty': 10.0, 'entry': 4100.0, 'status': 'open'},
      {'id': 8, 'direction': 'sell', 'qty': 5.0, 'entry': 4130.0, 'status': 'open'},
      {'id': 9, 'direction': 'buy', 'qty': 1.0, 'entry': 4090.0, 'status': 'closed'},
    ];
    await r.processPending();
    expect(desk.closes, ['7:${FridayOrders.closeReason}']);
    final res = _result(prefs);
    expect(res['status'], 'done');
    expect(res['closed'].single['exit'], 4125.0);
    expect(res['closed'].single['pnl'], 46.0);
    expect(res['failed'].single['reason'], 'already closed or not found');
    expect(desk.positions.firstWhere((p) => p['id'] == 8)['status'], 'open');
  });

  test('no order waiting: nothing happens', () async {
    final (r, prefs, _) = await _setup(null);
    expect(await r.processPending(), isFalse);
    expect(prefs.getString(FridayOrders.resultKey), isNull);
  });
}
