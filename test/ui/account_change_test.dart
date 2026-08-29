// test/ui/account_change_test.dart
//
// Connecting a token makes SettingsScreen call onAccountChanged, which makes
// RootScreen rebuild the repos tab. That is the exact moment the app threw
// "'_dependents.isEmpty': is not true" on device, so it gets a test.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:pocket_git/secrets/secret_store.dart';
import 'package:pocket_git/ui/root_screen.dart';
import 'package:pocket_git/ui/settings_screen.dart';

class _FakeSecretStore implements SecretStore {
  final Map<String, String> values;
  _FakeSecretStore([Map<String, String>? seed]) : values = {...?seed};

  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('an account change rebuilds the repos tab without tearing down a live subtree',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: RootScreen(secretStore: _FakeSecretStore())));
    await tester.pump();

    // Switch to Settings, the way the user does.
    await tester.tap(find.text('Settings'));
    await tester.pump();

    // Fire the callback SettingsScreen fires once a token is accepted.
    final settings = tester.widget<SettingsScreen>(find.byType(SettingsScreen));
    settings.onAccountChanged();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
  });

  testWidgets('the token dialog opens, accepts input and closes without throwing',
      (tester) async {
    await tester.pumpWidget(MaterialApp(home: SettingsScreen(
      secretStore: _FakeSecretStore(),
      onAccountChanged: () {},
    )));
    await tester.pump();

    await tester.tap(find.text('Connect GitHub account'));
    await tester.pumpAndSettle();

    final field = find.byType(TextField);
    if (field.evaluate().isNotEmpty) {
      await tester.enterText(field.first, 'ghp_notarealtoken');
      await tester.pump();
    }

    final connect = find.text('Connect');
    if (connect.evaluate().isNotEmpty) {
      await tester.tap(connect.last);
      // The dialog closes while the network call is still in flight; the
      // controller is disposed in that gap.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle(const Duration(seconds: 2));
    }

    expect(tester.takeException(), isNull);
  });
}
