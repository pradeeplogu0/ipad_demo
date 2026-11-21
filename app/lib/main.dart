import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';

import 'ble_link.dart';
import 'config.dart';
import 'geo.dart';
import 'nav_controller.dart';
import 'protocol.dart';
import 'routing.dart';
import 'turn_icon.dart';

class K {
  static const bg = Color(0xFF0B0F14);
  static const panel = Color(0xF2121820);
  static const line = Color(0xFF2A3544);
  static const text = Color(0xFFE8EEF6);
  static const muted = Color(0xFF8B98A8);
  static const accent = Color(0xFF3D8BFD);
  static const gold = Color(0xFFD4AF37);
  static const ok = Color(0xFF3DD68C);
  static const bad = Color(0xFFFF6B6B);
}

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => BleLink()),
        ChangeNotifierProxyProvider<BleLink, NavController>(
          create: (c) => NavController(ble: c.read<BleLink>()),
          update: (_, ble, nav) => nav!,
        ),
      ],
      child: const NavLinkApp(),
    ),
  );
}

class NavLinkApp extends StatelessWidget {
  const NavLinkApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'NavLink',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: K.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: K.accent,
          brightness: Brightness.dark,
          primary: K.accent,
          surface: K.bg,
        ),
      ),
      home: const MapScreen(),
    );
  }
}

class MapScreen extends StatefulWidget {
  const MapScreen({super.key, this.autoStart = true, this.showTiles = true});

  /// Connect to the display and request location on launch (off in tests).
  final bool autoStart;

  /// Load map tiles from the network (off in tests).
  final bool showTiles;

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _map = MapController();
  final _search = TextEditingController();
  Timer? _debounce;
  List<Place> _results = [];
  bool _searching = false;
  bool _follow = true;
  bool _mapReady = false;

  static const _darken = ColorFilter.matrix([
    -0.55, 0, 0, 0, 160, //
    0, -0.55, 0, 0, 165,
    0, 0, -0.5, 0, 175,
    0, 0, 0, 1, 0,
  ]);

  @override
  void initState() {
    super.initState();
    final nav = context.read<NavController>();
    nav.addListener(_onNav);
    if (!widget.autoStart) return;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      context.read<BleLink>().start();
      final p = await nav.locate();
      if (p != null && _mapReady) _map.move(p, 15);
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  void _onNav() {
    final nav = context.read<NavController>();
    if (!_mapReady) return;
    if (nav.phase == NavPhase.navigating && _follow && nav.here != null) {
      final zoom = nav.speedKmh > 70 ? 15.5 : (nav.speedKmh > 35 ? 16.5 : 17.5);
      _map.moveAndRotate(nav.here!, zoom, -nav.heading);
    }
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    if (q.trim().length < 3) {
      setState(() => _results = []);
      return;
    }
    _debounce = Timer(
      const Duration(milliseconds: 700),
      () => _runSearch(q.trim()),
    );
  }

  Future<void> _runSearch(String q) async {
    setState(() => _searching = true);
    try {
      final r = await context.read<NavController>().search(q);
      if (mounted) setState(() => _results = r);
    } catch (e) {
      if (mounted) setState(() => _results = []);
      _toast('Search failed: $e');
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  Future<void> _choose(Place p) async {
    FocusScope.of(context).unfocus();
    setState(() => _results = []);
    _search.text = p.name;
    final nav = context.read<NavController>();
    await nav.previewTo(p);
    final r = nav.route;
    if (r != null && r.points.length > 1 && _mapReady) {
      _map.rotate(0);
      _map.fitCamera(
        CameraFit.coordinates(
          coordinates: r.points,
          padding: const EdgeInsets.fromLTRB(40, 140, 40, 260),
        ),
      );
    }
    if (nav.error != null) _toast(nav.error!);
  }

  void _toast(String t) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(t), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    final nav = context.watch<NavController>();
    final route = nav.route;
    final here = nav.here;
    final navigating =
        nav.phase == NavPhase.navigating || nav.phase == NavPhase.arrived;

    return Scaffold(
      body: Stack(
        children: [
          FlutterMap(
            mapController: _map,
            options: MapOptions(
              initialCenter: here ?? const LatLng(12.9716, 77.5946),
              initialZoom: 13,
              onMapReady: () => _mapReady = true,
              onLongPress: navigating
                  ? null
                  : (_, p) {
                      HapticFeedback.mediumImpact();
                      _choose(
                        Place(
                          'Dropped pin',
                          '${p.latitude.toStringAsFixed(5)}, ${p.longitude.toStringAsFixed(5)}',
                          p,
                        ),
                      );
                    },
              onPositionChanged: (_, gesture) {
                if (gesture && _follow && navigating) {
                  setState(() => _follow = false);
                }
              },
            ),
            children: [
              if (widget.showTiles)
                TileLayer(
                  urlTemplate: AppConfig.tileUrl,
                  userAgentPackageName: AppConfig.userAgentPackage,
                  maxZoom: 19,
                  tileBuilder: AppConfig.darkenTiles
                      ? (context, tile, _) =>
                            ColorFiltered(colorFilter: _darken, child: tile)
                      : null,
                ),
              if (route != null)
                PolylineLayer(
                  polylines: [
                    Polyline(
                      points: route.points,
                      strokeWidth: 7,
                      color: K.accent,
                      borderStrokeWidth: 3,
                      borderColor: const Color(0xFF14325E),
                    ),
                  ],
                ),
              MarkerLayer(
                markers: [
                  if (nav.destination != null)
                    Marker(
                      point: nav.destination!.point,
                      width: 40,
                      height: 40,
                      alignment: Alignment.topCenter,
                      child: const Icon(
                        Icons.location_on_rounded,
                        color: K.bad,
                        size: 40,
                      ),
                    ),
                  if (here != null)
                    Marker(
                      point: here,
                      width: 44,
                      height: 44,
                      child: Transform.rotate(
                        angle: navigating ? 0 : nav.heading * 3.14159265 / 180,
                        child: const _MeArrow(),
                      ),
                    ),
                ],
              ),
            ],
          ),
          SafeArea(
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                  child: navigating ? _turnCard(nav) : _searchBar(),
                ),
                if (_results.isNotEmpty && !navigating) _resultsList(),
                const Spacer(),
                // Map data attribution (required by the OSM licence), kept visible.
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Text(
                      '© OpenStreetMap contributors',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: K.muted, fontSize: 10),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  child: switch (nav.phase) {
                    NavPhase.browsing => _browsePanel(nav),
                    NavPhase.preview => _previewPanel(nav),
                    NavPhase.navigating || NavPhase.arrived => _navPanel(nav),
                  },
                ),
              ],
            ),
          ),
          if (navigating && !_follow)
            Positioned(
              right: 16,
              bottom: 190,
              child: FloatingActionButton(
                onPressed: () {
                  setState(() => _follow = true);
                  _onNav();
                },
                backgroundColor: K.accent,
                child: const Icon(Icons.navigation_rounded),
              ),
            ),
        ],
      ),
    );
  }

  // ── widgets ─────────────────────────────────────────────────────────
  BoxDecoration get _box => BoxDecoration(
    color: K.panel,
    borderRadius: BorderRadius.circular(20),
    border: Border.all(color: K.line),
    boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16)],
  );

  Widget _searchBar() {
    return Container(
      decoration: _box,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _search,
              onChanged: _onQuery,
              onSubmitted: (q) => _runSearch(q.trim()),
              textInputAction: TextInputAction.search,
              style: const TextStyle(color: K.text, fontSize: 18),
              decoration: InputDecoration(
                hintText: 'Where to?',
                hintStyle: const TextStyle(color: K.muted, fontSize: 18),
                prefixIcon: const Icon(Icons.search_rounded, color: K.muted),
                suffixIcon: _searching
                    ? const Padding(
                        padding: EdgeInsets.all(14),
                        child: SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : null,
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 16),
              ),
            ),
          ),
          const _LinkChip(),
        ],
      ),
    );
  }

  Widget _resultsList() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      constraints: const BoxConstraints(maxHeight: 320),
      decoration: _box,
      child: ListView.separated(
        shrinkWrap: true,
        padding: EdgeInsets.zero,
        itemCount: _results.length,
        separatorBuilder: (_, _) => const Divider(height: 1, color: K.line),
        itemBuilder: (_, i) {
          final p = _results[i];
          return ListTile(
            leading: const Icon(Icons.place_rounded, color: K.accent),
            title: Text(
              p.name,
              style: const TextStyle(color: K.text, fontSize: 17),
            ),
            subtitle: Text(
              p.subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: K.muted),
            ),
            onTap: () => _choose(p),
          );
        },
      ),
    );
  }

  Widget _browsePanel(NavController nav) {
    return Container(
      decoration: _box,
      padding: const EdgeInsets.all(16),
      child: Row(
        children: [
          const Icon(Icons.touch_app_outlined, color: K.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              nav.error ??
                  'Search above or long-press the map to choose a destination.',
              style: TextStyle(
                color: nav.error != null ? K.bad : K.muted,
                fontSize: 15,
              ),
            ),
          ),
          IconButton(
            tooltip: 'My location',
            onPressed: () async {
              final p = await nav.locate();
              if (p != null && _mapReady) _map.move(p, 16);
            },
            icon: nav.locating
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.my_location_rounded, color: K.accent),
          ),
        ],
      ),
    );
  }

  Widget _previewPanel(NavController nav) {
    final r = nav.route!;
    final mins = (r.durationS / 60).round();
    return Container(
      decoration: _box,
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            nav.destination?.name ?? 'Destination',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: K.text,
              fontSize: 22,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${fmtDistance(r.distanceM)} · $mins min · ${r.source}',
            style: const TextStyle(color: K.muted, fontSize: 16),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              const Icon(Icons.science_outlined, color: K.muted, size: 20),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Simulate drive',
                  style: TextStyle(color: K.text, fontSize: 16),
                ),
              ),
              Switch(
                value: nav.simulate,
                onChanged: (v) {
                  nav.simulate = v;
                  setState(() {});
                },
              ),
            ],
          ),
          if (nav.simulate)
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: nav.simSpeedKmh,
                    min: 10,
                    max: 130,
                    divisions: 12,
                    label: '${nav.simSpeedKmh.round()} km/h',
                    onChanged: (v) => setState(() => nav.simSpeedKmh = v),
                  ),
                ),
                SizedBox(
                  width: 76,
                  child: Text(
                    '${nav.simSpeedKmh.round()} km/h',
                    style: const TextStyle(color: K.text, fontSize: 15),
                  ),
                ),
              ],
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: nav.cancelPreview,
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    side: const BorderSide(color: K.line),
                    foregroundColor: K.text,
                  ),
                  child: const Text('Cancel', style: TextStyle(fontSize: 17)),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: FilledButton.icon(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    setState(() => _follow = true);
                    nav.start();
                  },
                  icon: const Icon(Icons.navigation_rounded),
                  label: Text(
                    nav.simulate ? 'Start simulation' : 'Start',
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _turnCard(NavController nav) {
    final p = nav.progress;
    final arrived = nav.phase == NavPhase.arrived;
    final near = p != null && p.toTurnM <= 100 && p.next.turn != Turn.arrive;
    return Container(
      decoration: _box,
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          TurnIcon(
            arrived ? Turn.arrive : (p?.next.turn ?? Turn.straight),
            size: 72,
            color: near ? K.gold : Colors.white,
            exit: p?.next.exit ?? 0,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  arrived
                      ? 'Arrived'
                      : (p == null ? '…' : fmtDistance(p.toTurnM)),
                  style: TextStyle(
                    color: near ? K.gold : K.text,
                    fontSize: 38,
                    height: 1.05,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  arrived
                      ? (nav.destination?.name ?? '')
                      : (p == null
                            ? ''
                            : (p.next.street.isNotEmpty
                                  ? p.next.street
                                  : p.next.instruction)),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: K.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _navPanel(NavController nav) {
    final p = nav.progress;
    String two(int n) => n.toString().padLeft(2, '0');
    final eta = p == null ? '--:--' : '${two(p.eta.hour)}:${two(p.eta.minute)}';
    return Container(
      decoration: _box,
      padding: const EdgeInsets.all(14),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              _stat(eta, 'arrival'),
              _stat(p == null ? '—' : fmtDistance(p.remainingM), 'to go'),
              _stat('${nav.speedKmh.round()}', 'km/h'),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const _LinkChip(),
              if (nav.simulate) ...[
                const SizedBox(width: 8),
                const Chip(
                  label: Text('SIM'),
                  backgroundColor: Color(0xFF3A2E10),
                  labelStyle: TextStyle(
                    color: K.gold,
                    fontWeight: FontWeight.w800,
                  ),
                  side: BorderSide.none,
                ),
              ],
              const Spacer(),
              FilledButton(
                onPressed: () {
                  HapticFeedback.mediumImpact();
                  nav.stop();
                },
                style: FilledButton.styleFrom(
                  backgroundColor: const Color(0xFF3A1D22),
                  foregroundColor: const Color(0xFFFFB4B4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 22,
                    vertical: 14,
                  ),
                ),
                child: const Text(
                  'End',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _stat(String v, String l) => Expanded(
    child: Column(
      children: [
        Text(
          v,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            color: K.text,
            fontSize: 26,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(l, style: const TextStyle(color: K.muted, fontSize: 14)),
      ],
    ),
  );
}

class _MeArrow extends StatelessWidget {
  const _MeArrow();

  @override
  Widget build(BuildContext context) => const DecoratedBox(
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: Colors.white,
      boxShadow: [BoxShadow(color: Color(0x88000000), blurRadius: 8)],
    ),
    child: Icon(Icons.navigation_rounded, color: K.accent, size: 32),
  );
}

/// Connection state of the NavDisplay; tap to reconnect / disconnect.
class _LinkChip extends StatelessWidget {
  const _LinkChip();

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleLink>();
    final (Color c, IconData i, String t) = switch (ble.state) {
      LinkState.connected => (
        K.ok,
        Icons.watch_rounded,
        ble.batteryPct == null ? 'Display' : '${ble.batteryPct}%',
      ),
      LinkState.connecting ||
      LinkState.scanning => (K.gold, Icons.bluetooth_searching_rounded, '…'),
      LinkState.off => (K.muted, Icons.watch_off_outlined, 'Off'),
    };
    return Tooltip(
      message: ble.message,
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => ble.connected ? null : ble.start(),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: c.withValues(alpha: 0.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(i, size: 18, color: c),
              const SizedBox(width: 6),
              Text(
                t,
                style: TextStyle(color: c, fontWeight: FontWeight.w700),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
