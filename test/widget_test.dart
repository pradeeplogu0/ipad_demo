import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:ipad_demo/main.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  testWidgets('Watch Lab renders disconnected', (tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const WatchLabApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Watch Lab'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('Digital'), findsWidgets);
    expect(find.text('12-hour AM/PM'), findsOneWidget);
  });

  testWidgets('Phone-width layout has no overflow', (tester) async {
    tester.view.physicalSize = const Size(375, 2400); // iPhone 7 width
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const WatchLabApp());
    await tester.pump(const Duration(milliseconds: 100));
    expect(tester.takeException(), isNull);
  });
}
