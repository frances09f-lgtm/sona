import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sona/main.dart';

void main() {
  test('application title is Sona', () {
    final app = const SonaApp().build(_UnusedContext()) as MaterialApp;
    expect(app.title, 'Sona');
  });

  testWidgets('lock screen shows Sona branding', (tester) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildAppTheme(),
      home: LockScreen(app: AppState()),
    ));
    expect(find.text('Sona'), findsOneWidget);
    expect(find.text('Gold Paper Trading'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

class _UnusedContext extends Fake implements BuildContext {}
