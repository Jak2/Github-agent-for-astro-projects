// test/ui/dialog_controller_test.dart
//
// Every popup with a text field owns its controller through the route
// (AppControllerScope). Disposing one when showDialog's future completes
// crashes the field that is still rebuilding through the close animation:
// "A TextEditingController was used after being disposed", which cascades into
// a framework assert and a red screen. These tests close each popup and pump
// through the exit animation, which is exactly when that used to blow up.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:pocket_git/theme/app_theme.dart';

Future<void> _pumpHost(WidgetTester tester, Future<void> Function(BuildContext) open) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Builder(
        builder: (context) => ElevatedButton(
          onPressed: () => open(context),
          child: const Text('open'),
        ),
      ),
    ),
  ));
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('showInputPopup survives being confirmed', (tester) async {
    String? result;
    await _pumpHost(tester, (context) async {
      result = await showInputPopup(context, title: 'New file', hint: 'path', confirmLabel: 'Create');
    });

    await tester.enterText(find.byType(TextField), 'docs/notes.md');
    await tester.pump();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, 'docs/notes.md');
  });

  testWidgets('showInputPopup survives being cancelled', (tester) async {
    await _pumpHost(tester, (context) async {
      await showInputPopup(context, title: 'New file', hint: 'path');
    });

    await tester.enterText(find.byType(TextField), 'x');
    await tester.pump();
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a masked input popup still returns what was typed', (tester) async {
    String? result;
    await _pumpHost(tester, (context) async {
      result = await showInputPopup(
        context,
        title: 'GitHub token',
        hint: 'ghp_…',
        confirmLabel: 'Connect',
        obscure: true,
      );
    });

    await tester.enterText(find.byType(TextField), 'ghp_secret');
    await tester.pump();
    await tester.tap(find.text('Connect'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(result, 'ghp_secret');
  });

  testWidgets('AppControllerScope hands the live controller to its builder', (tester) async {
    await _pumpHost(tester, (context) async {
      await showDialog<String>(
        context: context,
        builder: (ctx) => AppControllerScope(
          initialText: 'seed',
          builder: (ctx, controller) => AlertDialog(
            content: TextField(controller: controller),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(controller.text),
                child: const Text('done'),
              ),
            ],
          ),
        ),
      );
    });

    expect(find.text('seed'), findsOneWidget);
    await tester.tap(find.text('done'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
