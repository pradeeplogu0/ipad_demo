import 'package:flutter_test/flutter_test.dart';

import 'package:ipad_demo/main.dart';

void main() {
  testWidgets('tapping the box increments and reset clears', (tester) async {
    await tester.pumpWidget(const IpadDemoApp());
    expect(find.text('0'), findsOneWidget);

    await tester.tap(find.text('0'));
    await tester.pumpAndSettle();
    expect(find.text('1'), findsOneWidget);

    await tester.tap(find.byTooltip('Reset'));
    await tester.pumpAndSettle();
    expect(find.text('0'), findsOneWidget);
  });
}
