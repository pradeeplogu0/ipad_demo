import 'package:flutter_test/flutter_test.dart';
import 'package:ipad_demo/face_designer.dart';
import 'package:ipad_demo/face_layout.dart';
import 'package:ipad_demo/face_painter.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('layout bytes round-trip (matches firmware wire format)', () {
    final a = FaceLayout();
    a.faces[1][elDate]
      ..x = -37
      ..y = 90
      ..size = 2
      ..color = 11
      ..visible = false;
    final bytes = [
      for (final f in a.faces)
        for (final e in f) ...e.encode(),
    ];
    expect(bytes.length, 140);
    final b = FaceLayout()..apply(bytes);
    final e = b.faces[1][elDate];
    expect([e.visible, e.x, e.y, e.size, e.color], [false, -37, 90, 2, 11]);
    expect(b.faces[0][elTime].size, 3); // digital defaults untouched
  });

  testWidgets('designer: phone width, select + drag sends an edit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final layout = FaceLayout();
    final sent = <List<int>>[];
    WatchFace faceFor(int f) => WatchFace(
      face: f,
      elements: layout.faces[f],
      h12: true,
      time: DateTime(2026, 11, 21, 14, 5, 42),
      batPct: 92,
      batMv: 4130,
      rotation: 0,
      connected: true,
      steps: 0,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: FaceDesignerPage(
          layout: layout,
          initialFace: faceDigital,
          faceFor: faceFor,
          onEdit: (e) async => sent.add(e.encode()),
          onReset: () async {},
          onShowFace: (_) async {},
          onDragging: (_) {},
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);

    // Select "Time" via its chip, then drag on the preview.
    await tester.tap(find.widgetWithText(FilterChip, 'Time'));
    await tester.pump();
    final before = layout.faces[faceDigital][elTime].y;
    final preview = find.byKey(const ValueKey('face-preview'));
    await tester.ensureVisible(preview);
    await tester.pump();
    final centre = tester.getCenter(preview);
    await tester.dragFrom(centre, const Offset(0, 40));
    await tester.pump();

    expect(sent, isNotEmpty);
    expect(sent.last[0], faceDigital);
    expect(sent.last[1], elTime);
    expect(layout.faces[faceDigital][elTime].y, greaterThan(before));

    // Hide it with the switch.
    await tester.tap(find.byType(Switch));
    await tester.pump();
    expect(sent.last[2], 0);
    expect(tester.takeException(), isNull);
  });
}
