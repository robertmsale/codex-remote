// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter_test/flutter_test.dart';

import 'package:field_exec/app/field_exec_app.dart';

void main() {
  testWidgets('App boots to connection screen', (WidgetTester tester) async {
    await tester.pumpWidget(const FieldExecApp());
    // Avoid pumpAndSettle here because some background services/plugins may
    // keep the microtask queue active on desktop.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }

    expect(find.text('FieldExec'), findsOneWidget);
    final hasRemoteField = find.text('username@host').evaluate().isNotEmpty;
    final hasLocalHint =
        find.textContaining('Local mode runs Codex').evaluate().isNotEmpty;
    expect(hasRemoteField || hasLocalHint, isTrue);
  });
}
