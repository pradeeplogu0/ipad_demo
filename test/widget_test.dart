import 'package:flutter_test/flutter_test.dart';

import 'package:ipad_demo/main.dart';

void main() {
  testWidgets('Watch Lab renders disconnected', (tester) async {
    await tester.pumpWidget(const WatchLabApp());
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.text('Watch Lab'), findsOneWidget);
    expect(find.text('Disconnected'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('8000'), findsWidgets);
  });
}
