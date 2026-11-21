import 'dart:math' as math;

import 'package:latlong2/latlong.dart';

import 'geo.dart';
import 'protocol.dart';
import 'routing.dart';

class NavProgress {
  NavProgress({
    required this.along,
    required this.offRouteM,
    required this.snapped,
    required this.next,
    required this.toTurnM,
    required this.remainingM,
    required this.eta,
    required this.street,
    required this.needsReroute,
    required this.arrived,
  });
  final double along, offRouteM, toTurnM, remainingM;
  final LatLng snapped;
  final RouteStep next;
  final DateTime eta;
  final String street; // road we're on now
  final bool needsReroute, arrived;
}

/// Pure navigation maths for one route: snapping, progress, off-route detection.
class NavEngine {
  NavEngine(this.route, {this.offRouteMeters = 40, this.offRouteSeconds = 5})
    : cum = _cumulative(route.points) {
    stepAlong = [
      for (final s in route.steps) cum[s.pointIndex.clamp(0, cum.length - 1)],
    ];
  }

  final NavRoute route;
  final double offRouteMeters;
  final int offRouteSeconds;
  final List<double> cum;
  late final List<double> stepAlong;

  int _hint = 0;
  DateTime? _offSince;

  double get total => cum.isEmpty ? 0 : cum.last;

  static List<double> _cumulative(List<LatLng> p) {
    final c = <double>[0];
    for (var i = 1; i < p.length; i++) {
      c.add(c.last + haversine(p[i - 1], p[i]));
    }
    return c;
  }

  /// Projects [pos] onto the route near the last match.
  /// Returns (metres along route, metres off route, snapped point, segment index).
  (double, double, LatLng, int) project(LatLng pos) {
    final pts = route.points;
    if (pts.length < 2) return (0, 0, pos, 0);
    final kx = 111320 * math.cos(pos.latitudeInRad), ky = 110540.0;
    var best = double.infinity, bestAlong = 0.0, bestSeg = _hint;
    var bestPt = pos;
    final from = math.max(0, _hint - 30);
    final to = math.min(pts.length - 1, _hint + 600);
    for (var pass = 0; pass < 2; pass++) {
      final a0 = pass == 0 ? from : 0, a1 = pass == 0 ? to : pts.length - 1;
      for (var i = a0; i < a1; i++) {
        final a = pts[i], b = pts[i + 1];
        final ax = (a.longitude - pos.longitude) * kx,
            ay = (a.latitude - pos.latitude) * ky;
        final bx = (b.longitude - pos.longitude) * kx,
            by = (b.latitude - pos.latitude) * ky;
        final dx = bx - ax, dy = by - ay;
        final len2 = dx * dx + dy * dy;
        final t = len2 == 0
            ? 0.0
            : (-(ax * dx + ay * dy) / len2).clamp(0.0, 1.0);
        final px = ax + t * dx, py = ay + t * dy;
        final d = math.sqrt(px * px + py * py);
        if (d < best) {
          best = d;
          bestSeg = i;
          bestAlong = cum[i] + t * (cum[i + 1] - cum[i]);
          bestPt = lerpLatLng(a, b, t);
        }
      }
      if (best < 60) {
        break; // found near the last position; no full search needed
      }
    }
    return (bestAlong, best, bestPt, bestSeg);
  }

  NavProgress update(LatLng pos, DateTime now) {
    final (along, off, snapped, seg) = project(pos);
    _hint = seg;

    // Off-route: more than offRouteMeters for longer than offRouteSeconds.
    if (off > offRouteMeters) {
      _offSince ??= now;
    } else {
      _offSince = null;
    }
    final reroute =
        _offSince != null &&
        now.difference(_offSince!).inSeconds >= offRouteSeconds;

    // Next maneuver = first step (after the start) beyond our position.
    var nextIdx = route.steps.length - 1;
    for (var i = 1; i < route.steps.length; i++) {
      if (stepAlong[i] > along + 3) {
        nextIdx = i;
        break;
      }
    }
    var currentStreet = '';
    for (var i = nextIdx - 1; i >= 0; i--) {
      if (route.steps[i].street.isNotEmpty) {
        currentStreet = route.steps[i].street;
        break;
      }
    }
    final remaining = math.max(0.0, total - along);
    final toTurn = math.max(0.0, stepAlong[nextIdx] - along);
    final secsLeft = total > 0 ? route.durationS * remaining / total : 0.0;
    return NavProgress(
      along: along,
      offRouteM: off,
      snapped: snapped,
      next: route.steps[nextIdx],
      toTurnM: toTurn,
      remainingM: remaining,
      eta: now.add(Duration(seconds: secsLeft.round())),
      street: currentStreet,
      needsReroute: reroute,
      arrived: remaining < 25 && off < offRouteMeters,
    );
  }

  /// Position [metres] along the route (for simulation).
  (LatLng, double) pointAt(double metres) {
    final pts = route.points;
    if (pts.length < 2) {
      return (pts.isEmpty ? const LatLng(0, 0) : pts.first, 0);
    }
    final m = metres.clamp(0.0, total);
    var lo = 0, hi = cum.length - 1;
    while (hi - lo > 1) {
      final mid = (lo + hi) >> 1;
      if (cum[mid] <= m) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final segLen = cum[hi] - cum[lo];
    final t = segLen == 0 ? 0.0 : (m - cum[lo]) / segLen;
    return (lerpLatLng(pts[lo], pts[hi], t), bearing(pts[lo], pts[hi]));
  }

  /// Simplified route for the display (Douglas-Peucker, capped at 4000 points).
  List<LatLng> displayPoints() {
    var tol = 5.0;
    var s = simplify(route.points, tol);
    while (s.length > 4000) {
      tol *= 1.6;
      s = simplify(route.points, tol);
    }
    return s;
  }
}

extension TurnNames on Turn {
  bool get isTurn => this != Turn.straight && this != Turn.depart;
}
