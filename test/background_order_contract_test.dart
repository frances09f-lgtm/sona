import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final root = 'android/app/src/main/kotlin/com/ambi/gold_paper_trading';
  test('headless service and provider both authenticate certificate and UID', () {
    final caller = File('$root/FridayCaller.kt').readAsStringSync();
    expect(caller, contains('getPackagesForUid(uid)'));
    expect(caller, contains('GET_SIGNING_CERTIFICATES'));
    expect(caller, contains('9ca9b3638f3580bfff9d01883515dbaaf44b8e74617fd4e6119228f54785e2fc'));
    expect(File('$root/FridayOrderService.kt').readAsStringSync(), contains('FridayCaller.trusted(applicationContext, msg.sendingUid)'));
    expect(File('$root/OroBridgeProvider.kt').readAsStringSync(), contains('FridayCaller.trusted(ctx, Binder.getCallingUid())'));
  });
  test('native UI/headless claim is durable before returning any order', () {
    final store = File('$root/FridayOrderStore.kt').readAsStringSync();
    expect(store, contains('@Synchronized fun claim'));
    expect(store.indexOf('.commit()'), lessThan(store.indexOf('return raw')));
    expect(store, contains('claims.contains(id)'));
    expect(File('$root/MainActivity.kt').readAsStringSync(), contains('FridayOrderStore.register'));
    expect(File('lib/friday_orders.dart').readAsStringSync(), contains('final raw = await _claimPending()'));
  });
  test('headless mode excludes periodic app work and foreground fallback', () {
    final service = File('$root/FridayOrderService.kt').readAsStringSync();
    expect(service, isNot(contains('startActivity(')));
    expect(service, contains('90_000'));
    final app = File('lib/main.dart').readAsStringSync();
    expect(app, contains('AppState(fridayHeadless: true)'));
    expect(app, contains('if (!fridayHeadless)'));
  });
}
