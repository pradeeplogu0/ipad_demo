import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

import 'config.dart';
import 'geo.dart';
import 'protocol.dart';

class Place {
  Place(this.name, this.subtitle, this.point);
  final String name, subtitle;
  final LatLng point;
}

class RouteStep {
  RouteStep({
    required this.turn,
    required this.exit,
    required this.instruction,
    required this.street,
    required this.pointIndex,
  });
  final Turn turn;
  final int exit; // roundabout exit, 0 = unknown
  final String instruction, street;
  final int pointIndex; // index in NavRoute.points where the maneuver happens
}

class NavRoute {
  NavRoute(
    this.points,
    this.steps,
    this.distanceM,
    this.durationS,
    this.destination,
    this.source,
  );
  final List<LatLng> points;
  final List<RouteStep> steps;
  final double distanceM, durationS;
  final Place destination;
  final String source; // "Apple Maps" or "OSRM"
}

abstract class RoutingProvider {
  String get name;
  Future<List<Place>> search(String query, {LatLng? near});
  Future<NavRoute> route(LatLng from, Place to);
}

/// Apple Maps on iPhone, OpenStreetMap services everywhere else.
RoutingProvider defaultRouter() =>
    (!kIsWeb && defaultTargetPlatform == TargetPlatform.iOS)
    ? AppleMapsRouter()
    : OsmRouter();

// ───────────────────────────────────────────────────────────────────────────
// Turn classification
// ───────────────────────────────────────────────────────────────────────────

/// OSRM maneuver type/modifier → protocol turn.
Turn turnFromOsrm(String type, String? modifier) {
  switch (type) {
    case 'depart':
      return Turn.depart;
    case 'arrive':
      return Turn.arrive;
    case 'roundabout':
    case 'rotary':
    case 'roundabout turn':
    case 'exit roundabout':
    case 'exit rotary':
      return Turn.roundabout;
  }
  switch (modifier) {
    case 'uturn':
      return Turn.uturn;
    case 'sharp right':
      return Turn.sharpRight;
    case 'right':
      return (type == 'fork' ||
              type == 'merge' ||
              type == 'on ramp' ||
              type == 'off ramp')
          ? Turn.slightRight
          : Turn.right;
    case 'slight right':
      return Turn.slightRight;
    case 'sharp left':
      return Turn.sharpLeft;
    case 'left':
      return (type == 'fork' ||
              type == 'merge' ||
              type == 'on ramp' ||
              type == 'off ramp')
          ? Turn.slightLeft
          : Turn.left;
    case 'slight left':
      return Turn.slightLeft;
  }
  return Turn.straight;
}

/// Apple Maps gives text instructions only: read the turn from the words,
/// falling back to the angle between the incoming and outgoing road.
Turn turnFromText(
  String text,
  double? angle, {
  bool first = false,
  bool last = false,
}) {
  final t = text.toLowerCase();
  if (last || t.contains('arrive') || t.contains('destination')) {
    return Turn.arrive;
  }
  if (first) return Turn.depart;
  if (t.contains('roundabout') ||
      t.contains('rotary') ||
      t.contains('traffic circle')) {
    return Turn.roundabout;
  }
  if (t.contains('u-turn') || t.contains('u turn') || t.contains('make a u')) {
    return Turn.uturn;
  }
  final left = t.contains('left'), right = t.contains('right');
  final slight =
      t.contains('slight') ||
      t.contains('keep') ||
      t.contains('bear') ||
      t.contains('merge') ||
      t.contains('exit') ||
      t.contains('fork') ||
      t.contains('ramp');
  final sharp = t.contains('sharp');
  if (left && !right) {
    return sharp ? Turn.sharpLeft : (slight ? Turn.slightLeft : Turn.left);
  }
  if (right && !left) {
    return sharp ? Turn.sharpRight : (slight ? Turn.slightRight : Turn.right);
  }
  final a = angle;
  if (a == null || a.abs() < 25) return Turn.straight;
  if (a.abs() > 160) return Turn.uturn;
  if (a < 0) {
    return a > -60 ? Turn.slightLeft : (a > -135 ? Turn.left : Turn.sharpLeft);
  }
  return a < 60 ? Turn.slightRight : (a < 135 ? Turn.right : Turn.sharpRight);
}

/// "Turn right onto MG Road" → "MG Road".
String streetFromInstruction(String text) {
  for (final k in [' onto ', ' on ', ' toward ', ' towards ', ' to ']) {
    final i = text.indexOf(k);
    if (i >= 0) return text.substring(i + k.length).trim();
  }
  return '';
}

int roundaboutExitFromText(String text) {
  final m = RegExp(r'(\d+)(st|nd|rd|th) exit').firstMatch(text.toLowerCase());
  return m == null ? 0 : int.parse(m.group(1)!);
}

// ───────────────────────────────────────────────────────────────────────────
// Apple Maps (MapKit) — ios/Runner/AppDelegate.swift, channel navlink/mapkit
// ───────────────────────────────────────────────────────────────────────────
class AppleMapsRouter implements RoutingProvider {
  static const _ch = MethodChannel('navlink/mapkit');

  @override
  String get name => 'Apple Maps';

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async {
    final r = await _ch.invokeMethod<List<dynamic>>('search', {
      'query': query,
      'lat': ?near?.latitude,
      'lon': ?near?.longitude,
    });
    return [
      for (final m in (r ?? []).cast<Map<dynamic, dynamic>>())
        Place(
          m['name'] as String? ?? '',
          m['subtitle'] as String? ?? '',
          LatLng((m['lat'] as num).toDouble(), (m['lon'] as num).toDouble()),
        ),
    ];
  }

  @override
  Future<NavRoute> route(LatLng from, Place to) async {
    final r = await _ch.invokeMethod<Map<dynamic, dynamic>>('route', {
      'fromLat': from.latitude,
      'fromLon': from.longitude,
      'toLat': to.point.latitude,
      'toLon': to.point.longitude,
    });
    if (r == null) throw 'No route found';
    return parseAppleRoute(r, to);
  }
}

NavRoute parseAppleRoute(Map<dynamic, dynamic> r, Place to) {
  final pts = <LatLng>[];
  final steps = <RouteStep>[];
  final raw = (r['steps'] as List).cast<Map<dynamic, dynamic>>();
  for (var s = 0; s < raw.length; s++) {
    final flat = (raw[s]['pts'] as List).cast<num>();
    final stepPts = [
      for (var i = 0; i + 1 < flat.length; i += 2)
        LatLng(flat[i].toDouble(), flat[i + 1].toDouble()),
    ];
    double? angle;
    if (pts.length >= 2 && stepPts.length >= 2) {
      angle = angleDiff(
        bearing(pts[pts.length - 2], pts.last),
        bearing(stepPts[0], stepPts[1]),
      );
    }
    final startIndex = pts.isEmpty ? 0 : pts.length - 1;
    for (final p in stepPts) {
      if (pts.isEmpty || pts.last != p) pts.add(p);
    }
    final text = (raw[s]['text'] as String?) ?? '';
    final last = s == raw.length - 1;
    if (text.isEmpty && !last && s != 0) continue;
    final turn = turnFromText(
      text,
      angle,
      first: s == 0 && raw.length > 1,
      last: last,
    );
    steps.add(
      RouteStep(
        turn: turn,
        exit: turn == Turn.roundabout ? roundaboutExitFromText(text) : 0,
        instruction: text.isEmpty
            ? (last ? 'Arrive at ${to.name}' : 'Start')
            : text,
        street: last ? to.name : streetFromInstruction(text),
        pointIndex: last ? pts.length - 1 : startIndex,
      ),
    );
  }
  return NavRoute(
    pts,
    steps,
    (r['dist'] as num).toDouble(),
    (r['time'] as num).toDouble(),
    to,
    'Apple Maps',
  );
}

// ───────────────────────────────────────────────────────────────────────────
// OpenStreetMap: Nominatim search + OSRM routing (desktop / web testing)
// ───────────────────────────────────────────────────────────────────────────
class OsmRouter implements RoutingProvider {
  OsmRouter({http.Client? client}) : _http = client ?? http.Client();
  final http.Client _http;
  static DateTime _lastNominatim = DateTime.fromMillisecondsSinceEpoch(0);

  Map<String, String> get _headers =>
      kIsWeb ? {} : {'User-Agent': AppConfig.userAgent};

  @override
  String get name => 'OSRM';

  @override
  Future<List<Place>> search(String query, {LatLng? near}) async {
    // Nominatim usage policy: max 1 request per second.
    final wait =
        const Duration(milliseconds: 1100) -
        DateTime.now().difference(_lastNominatim);
    if (wait > Duration.zero) await Future<void>.delayed(wait);
    _lastNominatim = DateTime.now();
    final uri = Uri.parse('${AppConfig.nominatimUrl}/search').replace(
      queryParameters: {
        'q': query,
        'format': 'jsonv2',
        'limit': '8',
        if (near != null)
          'viewbox':
              '${near.longitude - 0.5},${near.latitude + 0.5},'
              '${near.longitude + 0.5},${near.latitude - 0.5}',
      },
    );
    final res = await _http.get(uri, headers: _headers);
    if (res.statusCode != 200) throw 'Search failed (${res.statusCode})';
    final list = (jsonDecode(res.body) as List).cast<Map<String, dynamic>>();
    return [
      for (final m in list)
        Place(
          (m['name'] as String?)?.isNotEmpty == true
              ? m['name'] as String
              : (m['display_name'] as String).split(',').first,
          m['display_name'] as String? ?? '',
          LatLng(
            double.parse(m['lat'] as String),
            double.parse(m['lon'] as String),
          ),
        ),
    ];
  }

  @override
  Future<NavRoute> route(LatLng from, Place to) async {
    final uri = Uri.parse(
      '${AppConfig.osrmUrl}/route/v1/driving/'
      '${from.longitude},${from.latitude};${to.point.longitude},${to.point.latitude}'
      '?overview=full&geometries=geojson&steps=true',
    );
    final res = await _http.get(uri, headers: _headers);
    if (res.statusCode != 200) throw 'Routing failed (${res.statusCode})';
    return parseOsrmRoute(jsonDecode(res.body) as Map<String, dynamic>, to);
  }
}

NavRoute parseOsrmRoute(Map<String, dynamic> j, Place to) {
  if (j['code'] != 'Ok' || (j['routes'] as List).isEmpty) {
    throw 'No route found';
  }
  final r = (j['routes'] as List).first as Map<String, dynamic>;
  final coords = ((r['geometry'] as Map)['coordinates'] as List).cast<List>();
  final pts = [
    for (final c in coords)
      LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()),
  ];

  final steps = <RouteStep>[];
  var search = 0;
  for (final leg in (r['legs'] as List).cast<Map<String, dynamic>>()) {
    for (final s in (leg['steps'] as List).cast<Map<String, dynamic>>()) {
      final m = s['maneuver'] as Map<String, dynamic>;
      final loc = (m['location'] as List).cast<num>();
      final at = LatLng(loc[1].toDouble(), loc[0].toDouble());
      // Nearest geometry point to the maneuver, searching forward.
      var best = search, bestD = double.infinity;
      for (var i = search; i < pts.length && i < search + 2000; i++) {
        final d = haversine(pts[i], at);
        if (d < bestD) {
          bestD = d;
          best = i;
        }
        if (d < 1) break;
      }
      search = best;
      final type = m['type'] as String? ?? '';
      final mod = m['modifier'] as String?;
      final turn = turnFromOsrm(type, mod);
      final street = (s['name'] as String?) ?? '';
      steps.add(
        RouteStep(
          turn: turn,
          exit: (m['exit'] as num?)?.toInt() ?? 0,
          instruction: _osrmText(type, mod, street, turn),
          street: turn == Turn.arrive ? to.name : street,
          pointIndex: best,
        ),
      );
    }
  }
  return NavRoute(
    pts,
    steps,
    (r['distance'] as num).toDouble(),
    (r['duration'] as num).toDouble(),
    to,
    'OSRM',
  );
}

String _osrmText(String type, String? mod, String street, Turn turn) {
  final onto = street.isEmpty ? '' : ' onto $street';
  return switch (turn) {
    Turn.depart => 'Head out${street.isEmpty ? '' : ' on $street'}',
    Turn.arrive => 'Arrive at destination',
    Turn.roundabout => 'At the roundabout, take the exit$onto',
    Turn.uturn => 'Make a U-turn$onto',
    Turn.straight => 'Continue$onto',
    _ => '${type == 'fork' ? 'Keep' : 'Turn'} ${mod ?? ''}$onto'.replaceAll(
      '  ',
      ' ',
    ),
  };
}
