import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('multilingual dictionary card renders accessibly',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Semantics(
            label: 'offline dictionary entry',
            child: const Card(
              child: ListTile(
                leading: Icon(Icons.menu_book),
                title: Text('dictionary'),
                subtitle: Text('字典；辭典'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('dictionary'), findsOneWidget);
    expect(find.text('字典；辭典'), findsOneWidget);
    expect(
      find.bySemanticsLabel('offline dictionary entry'),
      findsOneWidget,
    );
  });
}
