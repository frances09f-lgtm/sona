import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';
import 'package:sona/pending_orders.dart';
import 'add_pending_flow_test.dart' as fixture;

void main() {
  testWidgets('remove waiting order from Add and Portfolio completely', (t) async {
    final app = await fixture.account();
    app.pendingOrders!.orders.add(PendingPaperOrder(id:'remove-preview', side:'buy', qty:.1,
      trigger:3990,above:false,gtc:true,createdAt:1,expiresAt:2));
    await app.pendingOrders!.save();
    final addKey = await fixture.mount(t, AddTab(app:app));
    await t.ensureVisible(find.text('Pending paper order'));
    await t.pumpAndSettle();
    await fixture.capture(t, addKey, 'remove-add-before');
    final portfolioKey = await fixture.mount(t, PositionsTab(app:app));
    await fixture.capture(t, portfolioKey, 'remove-portfolio-before');
    await t.tap(find.byTooltip('Remove order'));await t.pumpAndSettle();
    expect(find.text('Pending orders'), findsNothing);
    expect(find.text('Cancelled'), findsNothing);
    expect(app.pendingOrders!.orders,isEmpty);
    expect(PendingPaperOrders.load(app.prefs!).orders,isEmpty);
    for(final state in t.stateList<ScrollableState>(find.byType(Scrollable))) {state.position.jumpTo(0);}
    await fixture.capture(t, portfolioKey, 'remove-portfolio-after');
    final afterKey = await fixture.mount(t, AddTab(app:app));
    expect(find.byTooltip('Remove order'),findsNothing);
    expect(find.text('Cancelled'),findsNothing);
    await fixture.capture(t, afterKey, 'remove-add-after');
  });
}
