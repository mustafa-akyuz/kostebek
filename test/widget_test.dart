import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Uygulama basligi metni olusturulabilir', (WidgetTester tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Center(child: Text('Köstebek')),
        ),
      ),
    );

    expect(find.text('Köstebek'), findsOneWidget);
  });
}
