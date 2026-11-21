import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:navlink/geo.dart';
import 'package:navlink/nav_engine.dart';
import 'package:navlink/protocol.dart';
import 'package:navlink/routing.dart';

/// OSRM-shaped response: ~1.1 km north, right turn, ~1.1 km east, arrive.
Map<String, dynamic> osrmFixture() {
  final coords = <List<double>>[];
  for (var i = 0; i <= 10; i++) {
    coords.add([77.6000, 12.9700 + i * 0.001]);
  }
  for (var i = 1; i <= 10; i++) {
    coords.add([77.6000 + i * 0.001, 12.9800]);
  }
  return {
    'code': 'Ok',
    'routes': [
      {
        'distance': 2197.0,
        'duration': 300.0,
        'geometry': {'coordinates': coords},
        'legs': [
          {
            'steps': [
              {
                'name': 'Brigade Road',
                'maneuver': {
                  'type': 'depart',
                  'location': [77.6000, 12.9700],
                },
              },
              {
                'name': 'MG Road',
                'maneuver': {
                  'type': 'turn',
                  'modifier': 'right',
                  'location': [77.6000, 12.9800],
                },
              },
              {
                'name': '',
                'maneuver': {
                  'type': 'arrive',
                  'location': [77.6100, 12.9800],
                },
              },
            ],
          },
        ],
      },
    ],
  };
}

final dest = Place('Cubbon Park', 'Bengaluru', const LatLng(12.98, 77.61));

void main() {
  test('OSRM maneuver mapping', () {
    expect(turnFromOsrm('turn', 'right'), Turn.right);
    expect(turnFromOsrm('turn', 'sharp left'), Turn.sharpLeft);
    expect(turnFromOsrm('fork', 'left'), Turn.slightLeft);
    expect(turnFromOsrm('off ramp', 'right'), Turn.slightRight);
    expect(turnFromOsrm('continue', 'uturn'), Turn.uturn);
    expect(turnFromOsrm('roundabout', 'right'), Turn.roundabout);
    expect(turnFromOsrm('new name', 'straight'), Turn.straight);
    expect(turnFromOsrm('depart', null), Turn.depart);
    expect(turnFromOsrm('arrive', 'left'), Turn.arrive);
  });

  test('Apple Maps instructions', () {
    expect(turnFromText('Turn right onto MG Road', 85), Turn.right);
    expect(turnFromText('Keep left at the fork', -12), Turn.slightLeft);
    expect(
      turnFromText('At the roundabout, take the 2nd exit', 30),
      Turn.roundabout,
    );
    expect(roundaboutExitFromText('At the roundabout, take the 2nd exit'), 2);
    expect(turnFromText('', -100), Turn.left);
    expect(streetFromInstruction('Turn right onto MG Road'), 'MG Road');
    expect(streetFromInstruction('Continue'), '');
  });

  test('OSRM route parsing', () {
    final r = parseOsrmRoute(osrmFixture(), dest);
    expect(r.points.length, 21);
    expect(r.steps.map((s) => s.turn), [Turn.depart, Turn.right, Turn.arrive]);
    expect(r.steps[1].pointIndex, 10);
    expect(r.steps[1].street, 'MG Road');
    expect(r.steps[2].street, 'Cubbon Park');
  });

  test('progress, next maneuver and ETA', () {
    final e = NavEngine(parseOsrmRoute(osrmFixture(), dest));
    final now = DateTime(2026, 11, 22, 9);
    // Half-way up the first leg, 5 m east of the road.
    final p = e.update(const LatLng(12.9750, 77.60005), now);
    expect(p.along, closeTo(556, 15));
    expect(p.offRouteM, closeTo(5.4, 2));
    expect(p.next.turn, Turn.right);
    expect(p.toTurnM, closeTo(556, 20));
    expect(p.street, 'Brigade Road');
    expect(p.remainingM, closeTo(1641, 30));
    expect(p.eta.difference(now).inSeconds, closeTo(224, 10));
    expect(p.needsReroute, isFalse);
    expect(p.arrived, isFalse);

    final p2 = e.update(const LatLng(12.9800, 77.6050), now);
    expect(p2.next.turn, Turn.arrive);
    final p3 = e.update(const LatLng(12.9800, 77.60995), now);
    expect(p3.arrived, isTrue);
  });

  test('off-route needs > 40 m for > 5 s', () {
    final e = NavEngine(parseOsrmRoute(osrmFixture(), dest));
    final t0 = DateTime(2026, 11, 22, 9);
    const away = LatLng(12.9750, 77.6010); // ~108 m east of the road
    expect(e.update(away, t0).needsReroute, isFalse);
    expect(
      e.update(away, t0.add(const Duration(seconds: 3))).needsReroute,
      isFalse,
    );
    expect(
      e.update(away, t0.add(const Duration(seconds: 6))).needsReroute,
      isTrue,
    );
    // Back on the road resets the timer.
    expect(
      e
          .update(
            const LatLng(12.9760, 77.6000),
            t0.add(const Duration(seconds: 7)),
          )
          .needsReroute,
      isFalse,
    );
  });

  test('simulation point lookup', () {
    final e = NavEngine(parseOsrmRoute(osrmFixture(), dest));
    final (p0, h0) = e.pointAt(0);
    expect(p0, const LatLng(12.9700, 77.6000));
    expect(h0, closeTo(0, 1)); // heading north
    final (p1, h1) = e.pointAt(e.total - 1);
    expect(haversine(p1, const LatLng(12.98, 77.61)), lessThan(5));
    expect(h1, closeTo(90, 1)); // heading east
  });

  test('Douglas-Peucker keeps corners, drops straight points', () {
    final r = parseOsrmRoute(osrmFixture(), dest);
    final s = simplify(r.points, 5);
    expect(s.length, 3); // start, corner, end
    expect(s[1], const LatLng(12.9800, 77.6000));
    expect(NavEngine(r).displayPoints().length, 3);
  });
}
