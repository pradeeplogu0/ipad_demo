import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'nav_engine.dart';

const _bg = Color(0xFF0B0F14);
const _panel = Color(0xF0121820);
const _inset = Color(0xFF0C1219);
const _line = Color(0xFF2A3544);
const _text = Color(0xFFE8EEF6);
const _muted = Color(0xFF8B98A8);
const _accent = Color(0xFF3D8BFD);
const _gold = Color(0xFFD4AF37);
const _ok = Color(0xFF3DD68C);
const _bad = Color(0xFFFF6B6B);

/// Destination search + live turn-by-turn guidance mirrored to the watch.
class NavPage extends StatefulWidget {
  const NavPage({
    super.key,
    required this.nav,
    required this.watchConnected,
    this.h12 = false,
  });
  final NavController nav;
  final bool Function() watchConnected;
  final bool h12;

  @override
  State<NavPage> createState() => _NavPageState();
}

class _NavPageState extends State<NavPage> {
  final _query = TextEditingController();
  List<Place> _results = [];
  bool _searching = false;
  String? _error;

  NavController get nav => widget.nav;

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _search() async {
    final q = _query.text.trim();
    if (q.isEmpty) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      double? lat, lon;
      try {
        final p = await nav.currentPosition();
        lat = p.$1;
        lon = p.$2;
      } catch (_) {}
      final r = await MapKit.search(q, lat: lat, lon: lon);
      setState(() => _results = r);
      if (r.isEmpty) _error = 'No places found for "$q".';
    } on MissingPluginException {
      _error =
          'Apple Maps search works in the iPhone app. Try "Demo drive" here.';
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _go(Place p) async {
    HapticFeedback.mediumImpact();
    setState(() => _error = null);
    try {
      await nav.start(p);
    } on MissingPluginException {
      setState(() => _error = 'Routing needs the iPhone app.');
    } on PlatformException catch (e) {
      setState(() => _error = e.message ?? e.code);
    } catch (e) {
      setState(() => _error = '$e');
    }
  }

  String _time(DateTime t) {
    final m = t.minute.toString().padLeft(2, '0');
    if (!widget.h12) return '${t.hour.toString().padLeft(2, '0')}:$m';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:$m ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        title: const Text(
          'Navigation',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
      ),
      body: SafeArea(
        child: ListenableBuilder(
          listenable: nav,
          builder: (context, _) => SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!widget.watchConnected()) _banner(),
                    if (nav.state != null) _guidance() else _planner(),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _banner() => Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: const Color(0xFF2A2210),
      borderRadius: BorderRadius.circular(12),
      border: Border.all(color: const Color(0xFF5A4818)),
    ),
    child: const Row(
      children: [
        Icon(Icons.watch_off_outlined, color: _gold, size: 18),
        SizedBox(width: 8),
        Expanded(
          child: Text(
            'Watch not connected — directions show here only.',
            style: TextStyle(color: _gold, fontSize: 13),
          ),
        ),
      ],
    ),
  );

  Widget _card(List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: _panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: _line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _planner() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card([
          TextField(
            controller: _query,
            textInputAction: TextInputAction.search,
            onSubmitted: (_) => _search(),
            style: const TextStyle(color: _text, fontSize: 16),
            decoration: InputDecoration(
              hintText: 'Search a place or address',
              hintStyle: const TextStyle(color: _muted),
              prefixIcon: const Icon(Icons.search_rounded, color: _muted),
              suffixIcon: _searching
                  ? const Padding(
                      padding: EdgeInsets.all(14),
                      child: SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : IconButton(
                      onPressed: _search,
                      icon: const Icon(
                        Icons.arrow_forward_rounded,
                        color: _accent,
                      ),
                    ),
              filled: true,
              fillColor: _inset,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 12),
          SegmentedButton<bool>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(
                value: false,
                icon: Icon(Icons.directions_car_rounded),
                label: Text('Drive'),
              ),
              ButtonSegment(
                value: true,
                icon: Icon(Icons.directions_walk_rounded),
                label: Text('Walk'),
              ),
            ],
            selected: {nav.walking},
            onSelectionChanged: (s) => setState(() => nav.walking = s.first),
          ),
          if (nav.status.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(nav.status, style: const TextStyle(color: _muted)),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: Text(
                _error!,
                style: const TextStyle(color: _bad, fontSize: 13),
              ),
            ),
        ]),
        if (_results.isNotEmpty)
          _card([
            const Text(
              'RESULTS',
              style: TextStyle(
                color: _muted,
                fontSize: 11,
                letterSpacing: 1.4,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            for (final p in _results)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.place_rounded, color: _accent),
                title: Text(p.name, style: const TextStyle(color: _text)),
                subtitle: Text(
                  p.subtitle,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
                trailing: FilledButton(
                  onPressed: () => _go(p),
                  style: FilledButton.styleFrom(backgroundColor: _accent),
                  child: const Text('Go'),
                ),
              ),
          ]),
        _card([
          const Row(
            children: [
              Icon(Icons.science_outlined, color: _muted, size: 18),
              SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Try the watch\'s navigation face without driving.',
                  style: TextStyle(color: _muted, fontSize: 13),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          OutlinedButton.icon(
            onPressed: () {
              HapticFeedback.selectionClick();
              nav.startDemo();
            },
            icon: const Icon(Icons.play_arrow_rounded),
            label: const Text('Demo drive'),
            style: OutlinedButton.styleFrom(
              foregroundColor: _text,
              side: const BorderSide(color: _line),
              padding: const EdgeInsets.symmetric(vertical: 14),
            ),
          ),
        ]),
        const Text(
          'Routes and search by Apple Maps. Guidance keeps running with the phone '
          'locked; the watch shows each turn.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _guidance() {
    final s = nav.state!;
    final near = s.toTurn <= 100 && s.maneuver != Maneuver.arrive;
    final arrived = s.maneuver == Maneuver.arrive && s.left < 30;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card([
          Row(
            children: [
              SizedBox(
                width: 110,
                height: 110,
                child: CustomPaint(
                  painter: ManeuverPainter(
                    s.maneuver,
                    color: near ? _gold : Colors.white,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      arrived ? 'Arrived' : fmtDistance(s.toTurn),
                      style: TextStyle(
                        color: near ? _gold : _text,
                        fontSize: 40,
                        height: 1,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s.text,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: _text,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              _pill(Icons.flag_rounded, _time(s.eta), 'arrival'),
              const SizedBox(width: 8),
              _pill(Icons.timer_outlined, '${s.minutes} min', 'left'),
              const SizedBox(width: 8),
              _pill(Icons.route_rounded, fmtDistance(s.left), 'to go'),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(
                widget.watchConnected()
                    ? Icons.watch_rounded
                    : Icons.watch_off_outlined,
                size: 16,
                color: widget.watchConnected() ? _ok : _muted,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  '${nav.demo ? 'Demo drive' : nav.status}'
                  '${widget.watchConnected() ? ' · showing on watch' : ''}',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ),
            ],
          ),
        ]),
        if (nav.route != null)
          _card([
            Text(
              'To ${nav.route!.destination.name}',
              style: const TextStyle(color: _text, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 10),
            SizedBox(
              height: 180,
              child: CustomPaint(painter: _RouteSketch(nav.route!, nav.here)),
            ),
          ]),
        FilledButton.icon(
          onPressed: () {
            HapticFeedback.mediumImpact();
            nav.stop();
          },
          icon: const Icon(Icons.stop_rounded),
          label: const Text('End navigation'),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF3A1D22),
            foregroundColor: const Color(0xFFFFB4B4),
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ],
    );
  }

  Widget _pill(IconData icon, String value, String label) => Expanded(
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: _inset,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: _accent),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  value,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _text,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          Text(label, style: const TextStyle(color: _muted, fontSize: 11)),
        ],
      ),
    ),
  );
}

/// Simple route outline with the current position (no map tiles).
class _RouteSketch extends CustomPainter {
  _RouteSketch(this.r, this.here);
  final NavRoute r;
  final (double, double)? here;

  @override
  void paint(Canvas canvas, Size size) {
    if (r.pts.length < 2) return;
    var minLat = r.pts.first.$1,
        maxLat = minLat,
        minLon = r.pts.first.$2,
        maxLon = minLon;
    for (final p in r.pts) {
      if (p.$1 < minLat) minLat = p.$1;
      if (p.$1 > maxLat) maxLat = p.$1;
      if (p.$2 < minLon) minLon = p.$2;
      if (p.$2 > maxLon) maxLon = p.$2;
    }
    const pad = 12.0;
    final w = size.width - pad * 2, h = size.height - pad * 2;
    final spanLat = (maxLat - minLat).abs() < 1e-6 ? 1e-6 : maxLat - minLat;
    final spanLon = (maxLon - minLon).abs() < 1e-6 ? 1e-6 : maxLon - minLon;
    final k = (w / spanLon < h / spanLat) ? w / spanLon : h / spanLat;
    final ox = pad + (w - spanLon * k) / 2, oy = pad + (h - spanLat * k) / 2;
    Offset map((double, double) p) =>
        Offset(ox + (p.$2 - minLon) * k, oy + (maxLat - p.$1) * k);

    final path = Path()..moveTo(map(r.pts.first).dx, map(r.pts.first).dy);
    for (final p in r.pts.skip(1)) {
      final o = map(p);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = _accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 4
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(map(r.pts.last), 7, Paint()..color = _ok);
    final h0 = here;
    if (h0 != null) {
      canvas.drawCircle(map(h0), 9, Paint()..color = Colors.white);
      canvas.drawCircle(map(h0), 6, Paint()..color = _accent);
    }
  }

  @override
  bool shouldRepaint(_RouteSketch old) => true;
}
