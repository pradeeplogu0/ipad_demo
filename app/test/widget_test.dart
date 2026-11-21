import 'package:flutter_test/flutter_test.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:navlink/ble_link.dart';
import 'package:navlink/main.dart';
import 'package:navlink/nav_controller.dart';
import 'package:navlink/routing.dart';
import 'package:provider/provider.dart';

import 'engine_test.dart' show osrmFixture;

class FakeRouter implements RoutingProvider {
  @override
  String get name => 'fake';

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async => [
    Place('Cubbon Park', 'Bengaluru', const LatLng(12.98, 77.61)),
  ];

  @override
  Future<NavRoute> route(LatLng from, Place to) async =>
      parseOsrmRoute(osrmFixture(), to);
}

void main() {
  testWidgets('preview → simulated navigation → end, at iPhone 7 width', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(375, 667);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final ble = BleLink();
    final nav = NavController(ble: ble, router: FakeRouter())
      ..here = const LatLng(12.97, 77.60);

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: ble),
          ChangeNotifierProvider.value(value: nav),
        ],
        child: const MaterialApp(
          home: MapScreen(autoStart: false, showTiles: false),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Where to?'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await nav.previewTo(
      Place('Cubbon Park', 'Bengaluru', const LatLng(12.98, 77.61)),
    );
    await tester.pump();
    expect(find.text('Start'), findsOneWidget);
    expect(find.textContaining('2.2 km'), findsOneWidget);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(Switch)); // "Simulate drive"
    await tester.pump();
    expect(nav.simulate, isTrue);
    expect(find.byType(Slider), findsOneWidget);
    nav.simSpeedKmh = 100;
    await tester.tap(find.text('Start simulation'));
    await tester.pump(const Duration(seconds: 2));
    expect(nav.phase, NavPhase.navigating);
    expect(find.text('End'), findsOneWidget);
    expect(find.text('MG Road'), findsWidgets); // next turn's street
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('End'));
    await tester.pump();
    expect(nav.phase, NavPhase.browsing);
    nav.dispose();
    ble.dispose();
  });
}
