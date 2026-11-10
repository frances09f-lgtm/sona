import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sona/main.dart';
import 'package:sona/pending_orders.dart';
import 'add_pending_flow_test.dart' as fixture;

void main() {
  testWidgets(
    'legacy filled card is gone from Portfolio; waiting card and open position stay',
    (t) async {
      SharedPreferences.setMockInitialValues({
        'oro_pending_paper_orders':
            '[{"id":"filled-1","side":"buy","qty":1.0,"trigger":4074.0,"above":false,"gtc":true,"createdAt":1,"expiresAt":2,"tp":null,"sl":null,"status":"filled","note":null,"lastAttemptAt":null},'
            '{"id":"wait-1","side":"buy","qty":2.0,"trigger":4076.0,"above":false,"gtc":true,"createdAt":1,"expiresAt":2,"tp":null,"sl":null,"status":"pending","note":null,"lastAttemptAt":null}]',
      });
      final prefs = await SharedPreferences.getInstance();
      final app = fixture.PendingAccount()
        ..prefs = prefs
        ..pendingOrders = PendingPaperOrders.load(prefs)
        ..unlocked = true
        ..bid = 4078.39
        ..ask = 4079.04
        ..price = 4078.39
        ..priceOk = true
        ..priceAt = DateTime.now().millisecondsSinceEpoch;
      app.positions = [
        {
          'id': 'pos-1',
          'direction': 'buy',
          'entry': 4079.84,
          'qty': 1.0,
          'tp': null,
          'sl': null,
          'pnl': null,
          'exit': null,
          'status': 'open',
          'opened_at': '2026-11-10T18:20:00',
          'closed_at': null,
          'reason': null,
        },
      ];
      // The stored filled record is purged on load; the waiting one remains.
      expect(app.pendingOrders!.orders.map((o) => o.id), ['wait-1']);
      final portfolioKey = await fixture.mount(t, PositionsTab(app: app));
      expect(find.text('Filled'), findsNothing);
      expect(
        find.textContaining('Waiting for Ask at or below 4,076.00'),
        findsOneWidget,
      );
      expect(find.byTooltip('Remove order'), findsOneWidget);
      expect(find.textContaining('No open positions'), findsNothing);
      await fixture.capture(t, portfolioKey, 'filled-auto-cleared-portfolio');
    },
  );
}
