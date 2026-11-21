import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

import 'ble_link.dart';
import 'geo.dart';
import 'nav_engine.dart';
import 'protocol.dart';
import 'routing.dart';

enum NavPhase { browsing, preview, navigating, arrived }

/// App state: location (GPS or simulation) → NavEngine → BLE messages.
class NavController extends ChangeNotifier {
  NavController({required this.ble, RoutingProvider? router})
    : router = router ?? defaultRouter() {
    _statusSub = ble.statuses.listen(_onStatus);
    ble.addListener(_onLink);
  }

  final BleLink ble;
  final RoutingProvider router;

  NavPhase phase = NavPhase.browsing;
  LatLng? here;
  double heading = 0, speedKmh = 0;
  bool locating = false;
  String? error;

  Place? destination;
  NavRoute? route;
  NavEngine? engine;
  NavProgress? progress;

  bool simulate = false;
  double simSpeedKmh = 40;

  StreamSubscription<Position>? _gps;
  StreamSubscription<DisplayStatus>? _statusSub;
  Timer? _tick, _simTimer;
  DateTime _fixAt = DateTime.now();
  DateTime _lastManeuver = DateTime.fromMillisecondsSinceEpoch(0);
  double _simAlong = 0;
  int _routeId = 0, _resends = 0;
  bool _rerouting = false, _wasConnected = false;

  // ── location ──────────────────────────────────────────────────────────
  Future<LatLng?> locate() async {
    locating = true;
    error = null;
    notifyListeners();
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        throw 'Turn on Location Services';
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
      }
      if (p == LocationPermission.denied ||
          p == LocationPermission.deniedForever) {
        throw 'Allow location for NavLink in Settings';
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.best,
        ),
      );
      _applyFix(pos);
      _startGps();
      return here;
    } catch (e) {
      error = '$e';
      return null;
    } finally {
      locating = false;
      notifyListeners();
    }
  }

  void _startGps() {
    if (_gps != null) return;
    final settings = (defaultTargetPlatform == TargetPlatform.iOS && !kIsWeb)
        ? AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 0,
            activityType: ActivityType.automotiveNavigation,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
            allowBackgroundLocationUpdates: true,
          )
        : const LocationSettings(accuracy: LocationAccuracy.best);
    _gps = Geolocator.getPositionStream(locationSettings: settings).listen(
      (p) {
        if (!simulate) {
          _applyFix(p);
          _onPosition();
        }
      },
      onError: (Object e) {
        error = 'Location: $e';
        notifyListeners();
      },
    );
  }

  void _applyFix(Position p) {
    final prev = here;
    here = LatLng(p.latitude, p.longitude);
    speedKmh = p.speed > 0 ? p.speed * 3.6 : 0;
    if (p.speed > 1.0 && p.heading >= 0) {
      heading = p.heading;
    } else if (prev != null && haversine(prev, here!) > 3) {
      heading = bearing(prev, here!);
    }
    _fixAt = DateTime.now();
  }

  // ── search + routing ─────────────────────────────────────────────────
  Future<List<Place>> search(String q) => router.search(q, near: here);

  Future<void> previewTo(Place p) async {
    error = null;
    destination = p;
    final from = here ?? await locate();
    if (from == null) {
      notifyListeners();
      return;
    }
    try {
      route = await router.route(from, p);
      engine = NavEngine(route!);
      progress = null;
      phase = NavPhase.preview;
    } catch (e) {
      error = 'Route: $e';
    }
    notifyListeners();
  }

  void cancelPreview() {
    phase = NavPhase.browsing;
    route = null;
    engine = null;
    destination = null;
    notifyListeners();
  }

  // ── navigation ───────────────────────────────────────────────────────
  Future<void> start() async {
    final e = engine;
    if (e == null) return;
    phase = NavPhase.navigating;
    _resends = 0;
    if (simulate) {
      _simAlong = 0;
      final (p, h) = e.pointAt(0);
      here = p;
      heading = h;
      _simTimer = Timer.periodic(
        const Duration(milliseconds: 200),
        (_) => _simStep(),
      );
    } else {
      _startGps();
    }
    _tick?.cancel();
    _tick = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _sendPosition(),
    );
    _onPosition();
    await _sendRoute();
    notifyListeners();
  }

  Future<void> stop() async {
    _tick?.cancel();
    _simTimer?.cancel();
    phase = NavPhase.browsing;
    route = null;
    engine = null;
    progress = null;
    destination = null;
    await ble.send(encodeClear());
    notifyListeners();
  }

  void _simStep() {
    final e = engine;
    if (e == null) return;
    _simAlong += simSpeedKmh / 3.6 * 0.2;
    final (p, h) = e.pointAt(_simAlong);
    here = p;
    heading = h;
    speedKmh = simSpeedKmh;
    _fixAt = DateTime.now();
    _onPosition();
  }

  void _onPosition() {
    final e = engine, pos = here;
    if (e == null || pos == null || phase != NavPhase.navigating) {
      notifyListeners();
      return;
    }
    final pr = e.update(pos, DateTime.now());
    progress = pr;
    if (speedKmh < 3) heading = _routeHeading(e, pr.along);
    if (pr.arrived) {
      _arrive();
      return;
    }
    if (pr.needsReroute && !simulate) _reroute();
    if (DateTime.now().difference(_lastManeuver) >=
        const Duration(milliseconds: 950)) {
      _sendManeuver();
    }
    notifyListeners();
  }

  double _routeHeading(NavEngine e, double along) {
    final (_, h) = e.pointAt(along + 1);
    return h;
  }

  Future<void> _arrive() async {
    _tick?.cancel();
    _simTimer?.cancel();
    phase = NavPhase.arrived;
    final p = progress!;
    await ble.send(
      encodeManeuver(Turn.arrive, 0, 0, 0, DateTime.now(), p.next.street),
    );
    notifyListeners();
    Future.delayed(const Duration(seconds: 6), () async {
      if (phase == NavPhase.arrived) {
        await ble.send(encodeClear());
        phase = NavPhase.browsing;
        route = null;
        engine = null;
        progress = null;
        notifyListeners();
      }
    });
  }

  Future<void> _reroute() async {
    if (_rerouting) return;
    _rerouting = true;
    try {
      final from = here!, to = destination!;
      final r = await router.route(from, to);
      route = r;
      engine = NavEngine(r);
      _resends = 0;
      await _sendRoute(reroute: true);
    } catch (e) {
      error = 'Reroute failed: $e';
    } finally {
      _rerouting = false;
      notifyListeners();
    }
  }

  // ── BLE output ───────────────────────────────────────────────────────
  Future<void> _sendRoute({bool reroute = false, bool sameId = false}) async {
    final e = engine;
    if (e == null || !ble.connected) return;
    if (!sameId) _routeId = (_routeId + 1) & 0xFFFF;
    if (reroute || sameId) await ble.send(encodeReroute(_routeId));
    final pts = e.displayPoints();
    final eta = DateTime.now().add(
      Duration(seconds: e.route.durationS.round()),
    );
    for (final m in encodeRoute(
      _routeId,
      pts,
      e.total.round(),
      eta,
      maxPayload: ble.payload,
    )) {
      await ble.send(m);
    }
    _sendManeuver();
  }

  void _sendPosition() {
    final pos = here;
    if (pos == null || !ble.connected || phase != NavPhase.navigating) return;
    // Dead-reckon between GPS fixes so the display moves smoothly at 5 Hz.
    var p = pos;
    final dt = math.min(
      1.5,
      DateTime.now().difference(_fixAt).inMilliseconds / 1000.0,
    );
    if (!simulate && speedKmh > 3 && dt > 0.05) {
      final d = speedKmh / 3.6 * dt;
      final h = heading * math.pi / 180;
      p = LatLng(
        pos.latitude + d * math.cos(h) / 110540,
        pos.longitude +
            d * math.sin(h) / (111320 * math.cos(pos.latitudeInRad)),
      );
    }
    ble.send(encodePosition(p, heading, speedKmh));
  }

  void _sendManeuver() {
    final pr = progress;
    if (pr == null || !ble.connected) return;
    _lastManeuver = DateTime.now();
    ble.send(
      encodeManeuver(
        pr.next.turn,
        pr.next.exit,
        pr.toTurnM,
        pr.remainingM,
        pr.eta,
        pr.next.street.isNotEmpty ? pr.next.street : pr.street,
      ),
    );
  }

  void _onStatus(DisplayStatus s) {
    if (s is StatusResend && s.routeId == _routeId && _resends < 3) {
      _resends++;
      _sendRoute(sameId: true);
    }
  }

  void _onLink() {
    final c = ble.connected;
    if (c && !_wasConnected && phase == NavPhase.navigating) {
      _sendRoute(); // display rebooted / reconnected: send the route again
    }
    _wasConnected = c;
    notifyListeners();
  }

  @override
  void dispose() {
    _gps?.cancel();
    _statusSub?.cancel();
    _tick?.cancel();
    _simTimer?.cancel();
    ble.removeListener(_onLink);
    super.dispose();
  }
}
