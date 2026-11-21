import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

double haversine(LatLng a, LatLng b) {
  const r = 6371000.0;
  final p1 = a.latitudeInRad, p2 = b.latitudeInRad;
  final dp = p2 - p1, dl = (b.longitude - a.longitude) * math.pi / 180;
  final h =
      math.sin(dp / 2) * math.sin(dp / 2) +
      math.cos(p1) * math.cos(p2) * math.sin(dl / 2) * math.sin(dl / 2);
  return 2 * r * math.atan2(math.sqrt(h), math.sqrt(1 - h));
}

/// Initial bearing a → b in degrees (0 = north, clockwise).
double bearing(LatLng a, LatLng b) {
  final p1 = a.latitudeInRad, p2 = b.latitudeInRad;
  final dl = (b.longitude - a.longitude) * math.pi / 180;
  final y = math.sin(dl) * math.cos(p2);
  final x =
      math.cos(p1) * math.sin(p2) - math.sin(p1) * math.cos(p2) * math.cos(dl);
  return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
}

/// Signed smallest difference b - a in degrees (-180..180).
double angleDiff(double a, double b) => ((b - a + 540) % 360) - 180;

/// Point at [t] (0..1) between a and b.
LatLng lerpLatLng(LatLng a, LatLng b, double t) => LatLng(
  a.latitude + (b.latitude - a.latitude) * t,
  a.longitude + (b.longitude - a.longitude) * t,
);

/// Douglas-Peucker simplification with [toleranceM] metres (local metric space).
List<LatLng> simplify(List<LatLng> pts, double toleranceM) {
  if (pts.length < 3) return List.of(pts);
  final lat0 = pts.first.latitude * math.pi / 180;
  final kx = 111320 * math.cos(lat0), ky = 110540.0;
  final xs = [for (final p in pts) p.longitude * kx];
  final ys = [for (final p in pts) p.latitude * ky];
  final keep = List<bool>.filled(pts.length, false)
    ..[0] = true
    ..[pts.length - 1] = true;
  final stack = <(int, int)>[(0, pts.length - 1)];
  while (stack.isNotEmpty) {
    final (s, e) = stack.removeLast();
    var maxD = 0.0, idx = -1;
    final dx = xs[e] - xs[s], dy = ys[e] - ys[s];
    final len = math.sqrt(dx * dx + dy * dy);
    for (var i = s + 1; i < e; i++) {
      final d = len == 0
          ? math.sqrt(math.pow(xs[i] - xs[s], 2) + math.pow(ys[i] - ys[s], 2))
          : ((dy * xs[i] - dx * ys[i] + xs[e] * ys[s] - ys[e] * xs[s]).abs() /
                len);
      if (d > maxD) {
        maxD = d;
        idx = i;
      }
    }
    if (idx >= 0 && maxD > toleranceM) {
      keep[idx] = true;
      stack
        ..add((s, idx))
        ..add((idx, e));
    }
  }
  return [
    for (var i = 0; i < pts.length; i++)
      if (keep[i]) pts[i],
  ];
}

String fmtDistance(double m) {
  if (m < 1000) return '${m < 100 ? m.round() : (m / 10).round() * 10} m';
  if (m < 10000) return '${(m / 1000).toStringAsFixed(1)} km';
  return '${(m / 1000).round()} km';
}
