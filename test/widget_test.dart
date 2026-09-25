import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timely/main.dart';

void main() {
  testWidgets('account screen shows Timely sign up fields', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: AccountPage()));

    expect(find.text('Timely'), findsOneWidget);
    expect(find.text('Registrieren'), findsOneWidget);
    expect(find.text('Einloggen'), findsOneWidget);
    expect(find.text('E-Mail'), findsOneWidget);
    expect(find.text('Timely-Benutzername'), findsOneWidget);
  });
}
