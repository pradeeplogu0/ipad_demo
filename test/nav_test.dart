import 'package:flutter_test/flutter_test.dart';
import 'package:ipad_demo/nav_engine.dart';
import 'package:ipad_demo/nav_page.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  test('classify maneuvers from text and angle', () {
    expect(classify('Turn right onto MG Road', 85), Maneuver.right);
    expect(classify('Turn left onto Residency Rd', -90), Maneuver.left);
    expect(classify('Keep left at the fork', -10), Maneuver.slightLeft);
    expect(classify('Take a sharp right', 150), Maneuver.sharpRight);
    expect(classify('At the roundabout, take the 2nd exit', 30), Maneuver.roundabout);
    expect(classify('Make a U-turn', 179), Maneuver.uturn);
    expect(classify('Continue on NH 48', 3), Maneuver.straight);
    expect(classify('', -45), Maneuver.slightLeft); // geometry fallback
    expect(classify('', 100), Maneuver.right);
    expect(classify('Arrive at Cubbon Park', null, last: true), Maneuver.arrive);
    expect(classify('Proceed to the route', null, first: true), Maneuver.depart);
  });

  // ~1.1 km north, then ~1.1 km east (a right turn), like a MapKit result.
  final mapkit = {
    'dist': 2200.0,
    'time': 300.0,
    'steps': [
      {'text': '', 'dist': 0.0, 'pts': [12.9700, 77.6000]},
      {'text': 'Proceed north on Brigade Road', 'dist': 1110.0, 'pts': [12.9700, 77.6000, 12.9800, 77.6000]},
      {'text': 'Turn right onto MG Road', 'dist': 1085.0, 'pts': [12.9800, 77.6000, 12.9800, 77.6100]},
      {'text': 'Arrive at Cubbon Park', 'dist': 0.0, 'pts': [12.9800, 77.6100]},
    ],
  };
  final dest = Place('Cubbon Park', 'Bengaluru', 12.98, 77.61);

  test('route building, projection and guidance state', () {
    final r = buildRoute(mapkit, dest);
    expect(r.steps.map((s) => s.maneuver).toList(),
        [Maneuver.depart, Maneuver.straight, Maneuver.right, Maneuver.arrive]);
    expect(r.total, closeTo(2197, 25));

    // Half-way up the first leg, 5 m east of the road.
    final (along, off) = project(r, 12.9750, 77.60005);
    expect(along, closeTo(556, 15));
    expect(off, closeTo(5.4, 2));

    final st = stateAt(r, along, DateTime(2026, 11, 21, 15, 0));
    expect(st.maneuver, Maneuver.right);
    expect(st.toTurn, closeTo(556, 20));
    expect(st.text, 'Turn right onto MG Road');
    expect(st.left, closeTo(1641, 30));
    expect(st.minutes, 4);

    // After the turn: next is arrival.
    final st2 = stateAt(r, 1500, DateTime(2026, 11, 21, 15, 0));
    expect(st2.maneuver, Maneuver.arrive);
  });

  test('watch packet layout matches ble_service.h', () {
    final s = NavState(
        maneuver: Maneuver.right, toTurn: 250, left: 3150, along: 0,
        eta: DateTime(2026, 1, 1, 15, 42), minutes: 8, text: 'Turn right onto Café Road');
    final b = encodeNavPacket(s);
    expect(b[0], 1);
    expect(b[1], 5); // NAV_RIGHT
    expect(b[2] | b[3] << 8, 250);
    expect(b[6] | b[7] << 8, 3150);
    expect([b[10], b[11]], [15, 42]);
    expect(b[12], 8);
    expect(String.fromCharCodes(b.sublist(15, 15 + b[14])), 'Turn right onto Cafe Road');
    final off = encodeNavPacket(null);
    expect(off.length, 15);
    expect(off[0], 0);
  });

  test('ascii fold for the watch font', () {
    expect(asciiFold('Avenida São João — Centro'), 'Avenida Sao Joao - Centro');
    expect(asciiFold('MG  Road\n'), 'MG Road');
    expect(asciiFold('ಬೆಂಗಳೂರು MG Road'), 'MG Road');
  });

  testWidgets('navigation page fits iPhone width, demo drive renders', (tester) async {
    tester.view.physicalSize = const Size(375, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final sent = <List<int>>[];
    final nav = NavController(send: () => (pkt) async => sent.add(pkt));
    await tester.pumpWidget(MaterialApp(
      home: NavPage(nav: nav, watchConnected: () => true, h12: true),
    ));
    await tester.pump();
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Demo drive'));
    await tester.pump();
    expect(find.text('End navigation'), findsOneWidget);
    expect(sent.last[0], 1);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(seconds: 3));
    expect(sent.length, greaterThanOrEqualTo(2));

    await tester.tap(find.text('End navigation'));
    await tester.pump();
    expect(sent.last[0], 0); // watch told to stop
    nav.dispose();
  });
}
