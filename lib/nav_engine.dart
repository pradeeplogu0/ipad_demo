import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:material_ui/material_ui.dart';

/// Maneuver codes shared with the watch firmware (NavManeuver in ble_service.h).
enum Maneuver {
  straight,
  slightLeft,
  left,
  sharpLeft,
  slightRight,
  right,
  sharpRight,
  uturn,
  arrive,
  depart,
  roundabout,
}

class Place {
  Place(this.name, this.subtitle, this.lat, this.lon);
  final String name, subtitle;
  final double lat, lon;
}

class NavStep {
  NavStep(this.text, this.maneuver, this.startAlong);
  final String text;
  final Maneuver maneuver;
  final double startAlong; // metres from route start where this step begins
}

class NavRoute {
  NavRoute(
    this.pts,
    this.cum,
    this.steps,
    this.total,
    this.seconds,
    this.destination,
  );
  final List<(double, double)> pts; // lat, lon
  final List<double> cum; // cumulative metres at each point
  final List<NavStep> steps;
  final double total, seconds;
  final Place destination;
}

/// Live guidance state.
class NavState {
  const NavState({
    required this.maneuver,
    required this.toTurn,
    required this.left,
    required this.eta,
    required this.minutes,
    required this.text,
    required this.along,
  });
  final Maneuver maneuver;
  final double toTurn, left, along;
  final DateTime eta;
  final int minutes;
  final String text;
}

// ---------------------------------------------------------------------------
// Geometry
// ---------------------------------------------------------------------------
double haversine(double lat1, double lon1, double lat2, double lon2) {
  const r = 6371000.0;
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dp = p2 - p1, dl = (lon2 - lon1) * math.pi / 180;
  final a =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(a), math.sqrt(1 - a));
}

double bearing(double lat1, double lon1, double lat2, double lon2) {
  final p1 = lat1 * math.pi / 180, p2 = lat2 * math.pi / 180;
  final dl = (lon2 - lon1) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Maneuver from the instruction text (English), falling back to the turn
/// angle between the incoming and outgoing road segments.
Maneuver classify(
  String text,
  double? turnDeg, {
  bool first = false,
  bool last = false,
}) {
  final t = text.toLowerCase();
  if (last || t.contains('arrive') || t.contains('destination')) {
    return Maneuver.arrive;
  }
  if (first) return Maneuver.depart;
  if (t.contains('roundabout') ||
      t.contains('rotary') ||
      t.contains('traffic circle')) {
    return Maneuver.roundabout;
  }
  if (t.contains('u-turn') || t.contains('u turn') || t.contains('make a u')) {
    return Maneuver.uturn;
  }
  final left = t.contains('left'), right = t.contains('right');
  final slight =
      t.contains('slight') ||
      t.contains('keep') ||
      t.contains('bear') ||
      t.contains('merge') ||
      t.contains('exit') ||
      t.contains('fork');
  final sharp = t.contains('sharp');
  if (left && !right) {
    return sharp
        ? Maneuver.sharpLeft
        : (slight ? Maneuver.slightLeft : Maneuver.left);
  }
  if (right && !left) {
    return sharp
        ? Maneuver.sharpRight
        : (slight ? Maneuver.slightRight : Maneuver.right);
  }
  final d = turnDeg;
  if (d == null) return Maneuver.straight;
  final a = d.abs();
  if (a < 25) return Maneuver.straight;
  if (a > 160) return Maneuver.uturn;
  if (d < 0) {
    return a < 60
        ? Maneuver.slightLeft
        : (a < 135 ? Maneuver.left : Maneuver.sharpLeft);
  }
  return a < 60
      ? Maneuver.slightRight
      : (a < 135 ? Maneuver.right : Maneuver.sharpRight);
}

/// Watch fonts are ASCII only: fold accents, drop the rest.
String asciiFold(String s) {
  const map = {
    'à': 'a',
    'á': 'a',
    'â': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'ç': 'c',
    'è': 'e',
    'é': 'e',
    'ê': 'e',
    'ë': 'e',
    'ì': 'i',
    'í': 'i',
    'î': 'i',
    'ï': 'i',
    'ñ': 'n',
    'ò': 'o',
    'ó': 'o',
    'ô': 'o',
    'ö': 'o',
    'õ': 'o',
    'ø': 'o',
    'ù': 'u',
    'ú': 'u',
    'û': 'u',
    'ü': 'u',
    'ý': 'y',
    'ß': 'ss',
    '’': "'",
    '‘': "'",
    '“': '"',
    '”': '"',
    '–': '-',
    '—': '-',
    '…': '...',
  };
  final b = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final low = ch.toLowerCase();
    if (r >= 32 && r < 127) {
      b.write(ch);
    } else if (map.containsKey(low)) {
      final m = map[low]!;
      b.write(ch == low ? m : m.toUpperCase());
    }
  }
  return b.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Packet for the watch (characteristic af), see ble_service.h.
Uint8List encodeNavPacket(NavState? s) {
  if (s == null) return Uint8List.fromList(List.filled(15, 0));
  final text = asciiFold(s.text);
  final t = text.length > 120 ? text.substring(0, 120) : text;
  final b = BytesBuilder();
  final head = ByteData(15)
    ..setUint8(0, 1)
    ..setUint8(1, s.maneuver.index)
    ..setUint32(2, s.toTurn.round().clamp(0, 0xFFFFFFFF), Endian.little)
    ..setUint32(6, s.left.round().clamp(0, 0xFFFFFFFF), Endian.little)
    ..setUint8(10, s.eta.hour)
    ..setUint8(11, s.eta.minute)
    ..setUint16(12, s.minutes.clamp(0, 0xFFFF), Endian.little)
    ..setUint8(14, t.length);
  b.add(head.buffer.asUint8List());
  b.add(t.codeUnits);
  return b.toBytes();
}

// ---------------------------------------------------------------------------
// Apple Maps (MapKit) bridge — implemented in ios/Runner/AppDelegate.swift
// ---------------------------------------------------------------------------
class MapKit {
  static const _ch = MethodChannel('watchlab/mapkit');

  static Future<List<Place>> search(
    String query, {
    double? lat,
    double? lon,
  }) async {
    final r = await _ch.invokeMethod<List<dynamic>>('search', {
      'query': query,
      'lat': ?lat,
      'lon': ?lon,
    });
    return [
      for (final m in (r ?? []).cast<Map<dynamic, dynamic>>())
        Place(
          m['name'] as String? ?? '',
          m['subtitle'] as String? ?? '',
          (m['lat'] as num).toDouble(),
          (m['lon'] as num).toDouble(),
        ),
    ];
  }

  static Future<NavRoute> route(
    double fromLat,
    double fromLon,
    Place to, {
    bool walk = false,
  }) async {
    final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('route', {
      'fromLat': fromLat,
      'fromLon': fromLon,
      'toLat': to.lat,
      'toLon': to.lon,
      'mode': walk ? 'walk' : 'drive',
    });
    if (r == null) throw 'No route found';
    return buildRoute(r, to);
  }
}

/// Turns the MapKit route map into a [NavRoute] (also used by tests).
NavRoute buildRoute(Map<dynamic, dynamic> r, Place to) {
  final pts = <(double, double)>[];
  final cum = <double>[];
  final rawSteps = (r['steps'] as List).cast<Map<dynamic, dynamic>>();
  final starts = <double>[];
  final texts = <String>[];
  final turnAngles = <double?>[];

  for (final s in rawSteps) {
    final flat = (s['pts'] as List).cast<num>();
    final stepPts = <(double, double)>[
      for (var i = 0; i + 1 < flat.length; i += 2)
        (flat[i].toDouble(), flat[i + 1].toDouble()),
    ];
    // Turn angle: last heading before this step vs first heading of this step.
    double? angle;
    if (pts.length >= 2 && stepPts.length >= 2) {
      final a = pts[pts.length - 2], b = pts.last;
      final inB = bearing(a.$1, a.$2, b.$1, b.$2);
      final outB = bearing(
        stepPts[0].$1,
        stepPts[0].$2,
        stepPts[1].$1,
        stepPts[1].$2,
      );
      angle = ((outB - inB + 540) % 360) - 180;
    }
    starts.add(cum.isEmpty ? 0 : cum.last);
    texts.add((s['text'] as String?) ?? '');
    turnAngles.add(angle);
    for (final p in stepPts) {
      if (pts.isNotEmpty && pts.last == p) continue;
      cum.add(
        pts.isEmpty
            ? 0
            : cum.last + haversine(pts.last.$1, pts.last.$2, p.$1, p.$2),
      );
      pts.add(p);
    }
  }

  final steps = <NavStep>[];
  for (var i = 0; i < texts.length; i++) {
    final last = i == texts.length - 1;
    var text = texts[i];
    if (text.isEmpty) {
      text = i == 0 ? 'Start' : (last ? 'Arrive at ${to.name}' : 'Continue');
    }
    steps.add(
      NavStep(
        text,
        classify(
          text,
          turnAngles[i],
          first: i == 0 && texts.length > 1,
          last: last,
        ),
        starts[i],
      ),
    );
  }
  final total = cum.isEmpty ? (r['dist'] as num).toDouble() : cum.last;
  return NavRoute(pts, cum, steps, total, (r['time'] as num).toDouble(), to);
}

/// Projects a position onto the route. Returns (metres along route, metres off route).
(double, double) project(NavRoute r, double lat, double lon, {int hint = 0}) {
  if (r.pts.length < 2) return (0, 0);
  // Local equirectangular metres around the point.
  final kx = 111320 * math.cos(lat * math.pi / 180), ky = 110540.0;
  var best = double.infinity, bestAlong = 0.0;
  final from = math.max(0, hint - 40);
  for (var i = from; i < r.pts.length - 1; i++) {
    final a = r.pts[i], b = r.pts[i + 1];
    final ax = (a.$2 - lon) * kx, ay = (a.$1 - lat) * ky;
    final bx = (b.$2 - lon) * kx, by = (b.$1 - lat) * ky;
    final dx = bx - ax, dy = by - ay;
    final len2 = dx * dx + dy * dy;
    var t = len2 == 0 ? 0.0 : -(ax * dx + ay * dy) / len2;
    t = t.clamp(0.0, 1.0);
    final px = ax + t * dx, py = ay + t * dy;
    final d = math.sqrt(px * px + py * py);
    if (d < best) {
      best = d;
      bestAlong = r.cum[i] + t * (r.cum[i + 1] - r.cum[i]);
    }
  }
  return (bestAlong, best);
}

NavState stateAt(NavRoute r, double along, DateTime now) {
  // Next maneuver = first step starting ahead of us.
  NavStep? next;
  for (final s in r.steps.skip(1)) {
    if (s.startAlong > along + 3) {
      next = s;
      break;
    }
  }
  final left = math.max(0.0, r.total - along);
  final toTurn = next == null ? left : math.max(0.0, next.startAlong - along);
  final secsLeft = r.total > 0 ? r.seconds * left / r.total : 0.0;
  return NavState(
    maneuver: next?.maneuver ?? Maneuver.arrive,
    toTurn: toTurn,
    left: left,
    along: along,
    eta: now.add(Duration(seconds: secsLeft.round())),
    minutes: (secsLeft / 60).ceil(),
    text: next?.text ?? 'Arrive at ${r.destination.name}',
  );
}

// ---------------------------------------------------------------------------
// Guidance controller: GPS → route progress → watch packets
// ---------------------------------------------------------------------------
class NavController extends ChangeNotifier {
  NavController({required this.send});

  /// Writes a packet to the watch (null when not connected).
  final Future<void> Function(Uint8List packet)? Function() send;

  NavRoute? route;
  NavState? state;
  bool walking = false;
  bool demo = false;
  String status = '';
  (double, double)? here;

  StreamSubscription<Position>? _pos;
  Timer? _keepAlive, _demoTimer;
  int _hint = 0, _offCount = 0;
  DateTime _lastReroute = DateTime.fromMillisecondsSinceEpoch(0);
  bool _rerouting = false;

  bool get active => route != null;

  Future<(double, double)> currentPosition() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      throw 'Turn on Location Services in Settings.';
    }
    var perm = await Geolocator.checkPermission();
    if (perm == LocationPermission.denied) {
      perm = await Geolocator.requestPermission();
    }
    if (perm == LocationPermission.denied ||
        perm == LocationPermission.deniedForever) {
      throw 'Allow location for Watch Lab in Settings → Privacy & Security → Location.';
    }
    final p = await Geolocator.getCurrentPosition(
      locationSettings: const LocationSettings(accuracy: LocationAccuracy.best),
    );
    here = (p.latitude, p.longitude);
    return here!;
  }

  Future<void> start(Place dest) async {
    await stop(notify: false);
    status = 'Finding route…';
    notifyListeners();
    final (lat, lon) = await currentPosition();
    route = await MapKit.route(lat, lon, dest, walk: walking);
    _hint = 0;
    _offCount = 0;
    _update(lat, lon);
    status = 'Navigating';
    _pos =
        Geolocator.getPositionStream(
          locationSettings: AppleSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 5,
            activityType: walking
                ? ActivityType.fitness
                : ActivityType.automotiveNavigation,
            pauseLocationUpdatesAutomatically: false,
            showBackgroundLocationIndicator: true,
            allowBackgroundLocationUpdates: true,
          ),
        ).listen(
          (p) => _update(p.latitude, p.longitude),
          onError: (Object e) {
            status = 'Location error: $e';
            notifyListeners();
          },
        );
    _keepAlive = Timer.periodic(const Duration(seconds: 5), (_) => _push());
    notifyListeners();
  }

  void _update(double lat, double lon) {
    final r = route;
    if (r == null) return;
    here = (lat, lon);
    final (along, off) = project(r, lat, lon, hint: _hint);
    _hint = _indexFor(r, along);
    state = stateAt(r, along, DateTime.now());

    _offCount = off > 50 ? _offCount + 1 : 0;
    if (_offCount >= 3 &&
        !_rerouting &&
        DateTime.now().difference(_lastReroute) > const Duration(seconds: 15)) {
      _reroute(lat, lon);
    }
    if (state!.left < 25) {
      state = NavState(
        maneuver: Maneuver.arrive,
        toTurn: 0,
        left: 0,
        along: along,
        eta: DateTime.now(),
        minutes: 0,
        text: 'You have arrived',
      );
      status = 'Arrived';
      _push();
      notifyListeners();
      Future.delayed(const Duration(seconds: 10), () {
        if (status == 'Arrived') stop();
      });
      return;
    }
    _push();
    notifyListeners();
  }

  int _indexFor(NavRoute r, double along) {
    var i = _hint;
    while (i < r.cum.length - 1 && r.cum[i + 1] < along) {
      i++;
    }
    return i;
  }

  Future<void> _reroute(double lat, double lon) async {
    _rerouting = true;
    _lastReroute = DateTime.now();
    status = 'Rerouting…';
    notifyListeners();
    try {
      route = await MapKit.route(lat, lon, route!.destination, walk: walking);
      _hint = 0;
      _offCount = 0;
      status = 'Navigating';
    } catch (e) {
      status = 'Reroute failed: $e';
    } finally {
      _rerouting = false;
      notifyListeners();
    }
  }

  Future<void> _push() async {
    final s = send();
    if (s == null) return;
    try {
      await s(encodeNavPacket(state));
    } catch (_) {}
  }

  /// Simulated drive so the watch face can be tried without GPS or routing.
  Future<void> startDemo() async {
    await stop(notify: false);
    demo = true;
    status = 'Demo drive';
    final now = DateTime.now();
    final script = <(Maneuver, int, int, String)>[
      (Maneuver.depart, 400, 3400, 'Head north on Brigade Road'),
      (Maneuver.right, 250, 3150, 'Turn right onto MG Road'),
      (Maneuver.right, 60, 2960, 'Turn right onto MG Road'),
      (Maneuver.roundabout, 500, 2900, 'At the roundabout, take the 2nd exit'),
      (Maneuver.slightLeft, 300, 2000, 'Keep left at the fork'),
      (Maneuver.left, 90, 1500, 'Turn left onto Residency Road'),
      (Maneuver.uturn, 120, 900, 'Make a U-turn'),
      (Maneuver.arrive, 40, 40, 'Arrive at destination, on the right'),
    ];
    var i = 0;
    void tick() {
      final (m, toTurn, left, text) = script[i];
      final mins = math.max(1, left ~/ 400);
      state = NavState(
        maneuver: m,
        toTurn: toTurn.toDouble(),
        left: left.toDouble(),
        along: 0,
        eta: now.add(Duration(minutes: mins)),
        minutes: mins,
        text: text,
      );
      _push();
      notifyListeners();
      i++;
      if (i >= script.length) {
        _demoTimer?.cancel();
        Future.delayed(const Duration(seconds: 4), () {
          if (demo) stop();
        });
      }
    }

    tick();
    _demoTimer = Timer.periodic(const Duration(seconds: 3), (_) => tick());
  }

  Future<void> stop({bool notify = true}) async {
    await _pos?.cancel();
    _pos = null;
    _keepAlive?.cancel();
    _demoTimer?.cancel();
    final wasActive = route != null || demo;
    route = null;
    state = null;
    demo = false;
    status = '';
    if (wasActive) await _push(); // active = 0 → watch returns to its face
    if (notify) notifyListeners();
  }

  @override
  void dispose() {
    _pos?.cancel();
    _keepAlive?.cancel();
    _demoTimer?.cancel();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Arrow painter — same shapes as the watch (nav_face.cpp), 100 x 100 box.
// ---------------------------------------------------------------------------
class ManeuverPainter extends CustomPainter {
  ManeuverPainter(this.m, {this.color = Colors.white});
  final Maneuver m;
  final Color color;

  static const _shapes = <Maneuver, (List<Offset>, List<Offset>, int)>{
    Maneuver.straight: (
      [Offset(50, 95), Offset(50, 12)],
      [Offset(24, 38), Offset(50, 12), Offset(76, 38)],
      0,
    ),
    Maneuver.slightLeft: (
      [Offset(64, 95), Offset(64, 60), Offset(26, 22)],
      [Offset(50, 20), Offset(24, 20), Offset(24, 46)],
      0,
    ),
    Maneuver.left: (
      [Offset(70, 95), Offset(70, 50), Offset(18, 50)],
      [Offset(38, 30), Offset(16, 50), Offset(38, 70)],
      0,
    ),
    Maneuver.sharpLeft: (
      [Offset(70, 95), Offset(70, 30), Offset(30, 72)],
      [Offset(30, 48), Offset(28, 74), Offset(54, 74)],
      0,
    ),
    Maneuver.slightRight: (
      [Offset(36, 95), Offset(36, 60), Offset(74, 22)],
      [Offset(50, 20), Offset(76, 20), Offset(76, 46)],
      0,
    ),
    Maneuver.right: (
      [Offset(30, 95), Offset(30, 50), Offset(82, 50)],
      [Offset(62, 30), Offset(84, 50), Offset(62, 70)],
      0,
    ),
    Maneuver.sharpRight: (
      [Offset(30, 95), Offset(30, 30), Offset(70, 72)],
      [Offset(70, 48), Offset(72, 74), Offset(46, 74)],
      0,
    ),
    Maneuver.uturn: (
      [
        Offset(70, 95),
        Offset(70, 36),
        Offset(62, 20),
        Offset(38, 20),
        Offset(30, 36),
        Offset(30, 70),
      ],
      [Offset(14, 54), Offset(30, 72), Offset(46, 54)],
      0,
    ),
    Maneuver.arrive: ([], [], 1),
    Maneuver.depart: (
      [Offset(50, 95), Offset(50, 12)],
      [Offset(24, 38), Offset(50, 12), Offset(76, 38)],
      0,
    ),
    Maneuver.roundabout: (
      [Offset(50, 96), Offset(50, 76)],
      [
        Offset(63, 37),
        Offset(84, 16),
        Offset(64, 16),
        Offset(84, 16),
        Offset(84, 36),
      ],
      2,
    ),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 100;
    final o = Offset((size.width - 100 * k) / 2, (size.height - 100 * k) / 2);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final (shaft, head, ring) = _shapes[m]!;
    void poly(List<Offset> p) {
      if (p.length < 2) return;
      final path = Path()..moveTo(o.dx + p[0].dx * k, o.dy + p[0].dy * k);
      for (final q in p.skip(1)) {
        path.lineTo(o.dx + q.dx * k, o.dy + q.dy * k);
      }
      canvas.drawPath(path, paint);
    }

    poly(shaft);
    poly(head);
    if (ring == 1) {
      canvas.drawCircle(
        o + Offset(50 * k, 50 * k),
        26 * k,
        paint
          ..color = const Color(0xFF3DD68C)
          ..strokeWidth = 12 * k,
      );
    } else if (ring == 2) {
      canvas.drawCircle(
        o + Offset(50 * k, 56 * k),
        15.5 * k,
        paint..strokeWidth = 9 * k,
      );
    }
  }

  @override
  bool shouldRepaint(ManeuverPainter old) => old.m != m || old.color != color;
}

String fmtDistance(double m) {
  if (m < 1000) return '${m < 100 ? m.round() : (m / 10).round() * 10} m';
  if (m < 10000) return '${(m / 1000).toStringAsFixed(1)} km';
  return '${(m / 1000).round()} km';
}
