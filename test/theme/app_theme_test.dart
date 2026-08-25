// test/theme/app_theme_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:git_agent_app/theme/app_theme.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

Finder _arrow(IconData icon) => find.widgetWithIcon(OutlinedButton, icon);

bool _enabled(WidgetTester tester, IconData icon) =>
    tester.widget<OutlinedButton>(_arrow(icon)).onPressed != null;

void main() {
  testWidgets('appStepper reports the next value on each arrow', (tester) async {
    final seen = <int>[];
    await tester.pumpWidget(_host(appStepper(
      label: 'Max reasoning loops',
      value: 3,
      min: 1,
      max: 10,
      onChanged: seen.add,
    )));

    expect(find.text('3'), findsOneWidget);
    await tester.tap(_arrow(Icons.chevron_right));
    await tester.tap(_arrow(Icons.chevron_left));
    expect(seen, [4, 2]);
  });

  testWidgets('appStepper disables the arrow at each bound instead of no-oping', (tester) async {
    await tester.pumpWidget(_host(appStepper(
      label: 'Max reasoning loops',
      value: 1,
      min: 1,
      max: 10,
      onChanged: (_) => fail('a disabled arrow must not fire'),
    )));
    expect(_enabled(tester, Icons.chevron_left), isFalse);
    expect(_enabled(tester, Icons.chevron_right), isTrue);

    await tester.pumpWidget(_host(appStepper(
      label: 'Max reasoning loops',
      value: 10,
      min: 1,
      max: 10,
      onChanged: (_) => fail('a disabled arrow must not fire'),
    )));
    expect(_enabled(tester, Icons.chevron_left), isTrue);
    expect(_enabled(tester, Icons.chevron_right), isFalse);
  });

  testWidgets('appActionChip fires once per tap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(appActionChip(
      label: 'Status',
      icon: Icons.difference_outlined,
      onPressed: () => taps++,
    )));
    await tester.tap(find.text('Status'));
    expect(taps, 1);
  });

  testWidgets('appActionChip with a null callback is inert, not silently tappable', (tester) async {
    await tester.pumpWidget(_host(appActionChip(
      label: 'Pull',
      icon: Icons.south,
      onPressed: null,
    )));
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);
  });

  testWidgets('a row of chips sizes to its labels rather than blowing a Row apart', (tester) async {
    // appPrimaryButton/appSecondaryButton are full-width SizedBoxes and throw
    // a BoxConstraints assertion unwrapped in a Row. Chips must not.
    await tester.pumpWidget(_host(SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          for (final label in ['Status', 'Log', 'Branches', 'Pull', 'Commit & push'])
            appActionChip(label: label, icon: Icons.circle, onPressed: () {}),
        ],
      ),
    )));
    expect(tester.takeException(), isNull);
    expect(find.text('Commit & push'), findsOneWidget);
  });
}
