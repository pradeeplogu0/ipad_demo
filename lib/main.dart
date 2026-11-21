import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';

// ---------------------------------------------------------------------------
// Watch protocol (same UUIDs and byte layouts as the Watch Lab web page).
// ---------------------------------------------------------------------------
final Guid kService = Guid('4b0ad7a0-4b2c-11ee-be56-0242ac120002');
final Guid kSteps = Guid('4b0ad7a1-4b2c-11ee-be56-0242ac120002');
final Guid kReset = Guid('4b0ad7a2-4b2c-11ee-be56-0242ac120002');
final Guid kGoal = Guid('4b0ad7a3-4b2c-11ee-be56-0242ac120002');
final Guid kTime = Guid('4b0ad7a4-4b2c-11ee-be56-0242ac120002');
final Guid kSens = Guid('4b0ad7a5-4b2c-11ee-be56-0242ac120002');
final Guid kImu = Guid('4b0ad7a6-4b2c-11ee-be56-0242ac120002');
// Added by the ESP32-S3 Round Display firmware (optional on older watches).
final Guid kBatt = Guid('4b0ad7a7-4b2c-11ee-be56-0242ac120002');
final Guid kClock = Guid('4b0ad7a8-4b2c-11ee-be56-0242ac120002');
final Guid kRot = Guid('4b0ad7a9-4b2c-11ee-be56-0242ac120002');
final Guid kBright = Guid('4b0ad7aa-4b2c-11ee-be56-0242ac120002');
const String kNamePrefix = 'StepCounter';

// ---------------------------------------------------------------------------
// Palette (mirrors the CSS variables).
// ---------------------------------------------------------------------------
class C {
  static const bg = Color(0xFF0B0F14);
  static const panel = Color(0xF0121820);
  static const inset = Color(0xFF0C1219);
  static const plotBg = Color(0xFF0A1016);
  static const line = Color(0xFF2A3544);
  static const grid = Color(0xFF243040);
  static const text = Color(0xFFE8EEF6);
  static const muted = Color(0xFF8B98A8);
  static const accent = Color(0xFF3D8BFD);
  static const ok = Color(0xFF3DD68C);
  static const warn = Color(0xFFF5C542);
  static const bad = Color(0xFFFF6B6B);
  static const btn = Color(0xFF1B2734);
  static const danger = Color(0xFF3A1D22);
  static const dangerText = Color(0xFFFFB4B4);
  static const ax = Color(0xFFFF6B6B);
  static const ay = Color(0xFF51CF66);
  static const az = Color(0xFF4DABF7);
  static const mag = Color(0xFFF5C542);
}

void main() => runApp(const WatchLabApp());

class WatchLabApp extends StatelessWidget {
  const WatchLabApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Watch Lab',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: C.bg,
        colorScheme: ColorScheme.fromSeed(
          seedColor: C.accent,
          brightness: Brightness.dark,
          primary: C.accent,
          surface: C.bg,
        ),
        sliderTheme: const SliderThemeData(
          activeTrackColor: C.accent,
          thumbColor: C.accent,
          inactiveTrackColor: C.grid,
        ),
      ),
      home: const WatchLabPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// IMU plot model: smooths raw samples and keeps a rolling history.
// Used as the CustomPainter's repaint listenable so only the chart redraws.
// ---------------------------------------------------------------------------
class ImuModel extends ChangeNotifier {
  static const maxN = 90;
  static const smooth = 0.045;
  static const pushEvery = Duration(milliseconds: 80);

  final raw = <String, double>{'mag': 1000, 'x': 0, 'y': 0, 'z': 0};
  final shown = <String, double>{'mag': 1000, 'x': 0, 'y': 0, 'z': 0};
  final hist = <String, List<double>>{'mag': [], 'x': [], 'y': [], 'z': []};
  final visible = <String, bool>{'mag': true, 'x': true, 'y': true, 'z': true};
  Duration _lastPush = Duration.zero;

  void tick(Duration now) {
    for (final k in shown.keys) {
      shown[k] = shown[k]! + (raw[k]! - shown[k]!) * smooth;
    }
    if (_lastPush == Duration.zero || now - _lastPush >= pushEvery) {
      _lastPush = now;
      for (final k in hist.keys) {
        final h = hist[k]!..add(shown[k]!);
        if (h.length > maxN) h.removeAt(0);
      }
    }
    notifyListeners();
  }

  void toggle(String k, bool v) {
    visible[k] = v;
    notifyListeners();
  }
}

class ImuPainter extends CustomPainter {
  ImuPainter(this.m) : super(repaint: m);
  final ImuModel m;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    final grid = Paint()
      ..color = C.grid
      ..strokeWidth = 1;
    for (var i = 1; i < 4; i++) {
      final y = h * i / 4;
      canvas.drawLine(Offset(0, y), Offset(w, y), grid);
    }

    void line(List<double> arr, Color color, double scale) {
      final n = arr.length;
      if (n < 2) return;
      double x(int i) => i / (ImuModel.maxN - 1) * w;
      double y(double v) => h / 2 - (v / scale) * h * 0.42;
      final path = Path()..moveTo(x(0), y(arr[0]));
      for (var i = 1; i < n; i++) {
        final x0 = x(i - 1), y0 = y(arr[i - 1]);
        final x1 = x(i), y1 = y(arr[i]);
        path.quadraticBezierTo(x0, y0, (x0 + x1) / 2, (y0 + y1) / 2);
      }
      path.lineTo(x(n - 1), y(arr[n - 1]));
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeJoin = StrokeJoin.round
          ..strokeCap = StrokeCap.round,
      );
    }

    if (m.visible['x']!) line(m.hist['x']!, C.ax, 2500);
    if (m.visible['y']!) line(m.hist['y']!, C.ay, 2500);
    if (m.visible['z']!) line(m.hist['z']!, C.az, 2500);
    if (m.visible['mag']!) line(m.hist['mag']!, C.mag, 2500);
  }

  @override
  bool shouldRepaint(ImuPainter old) => false;
}

class RingPainter extends CustomPainter {
  RingPainter(this.pct, {this.color = C.accent});
  final double pct;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.shortestSide / 2 - 10;
    final c = size.center(Offset.zero);
    final bg = Paint()
      ..color = C.grid
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12;
    canvas.drawCircle(c, r, bg);
    if (pct <= 0) return;
    final fg = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: r),
      -math.pi / 2,
      2 * math.pi * pct,
      false,
      fg,
    );
  }

  @override
  bool shouldRepaint(RingPainter old) => old.pct != pct || old.color != color;
}

// ---------------------------------------------------------------------------
// Main page
// ---------------------------------------------------------------------------
enum Link { off, busy, on, err }

class WatchLabPage extends StatefulWidget {
  const WatchLabPage({super.key});

  @override
  State<WatchLabPage> createState() => _WatchLabPageState();
}

class _WatchLabPageState extends State<WatchLabPage>
    with SingleTickerProviderStateMixin {
  final imu = ImuModel();
  late final _ticker = createTicker(imu.tick);
  final _goalCtl = TextEditingController(text: '8000');

  BluetoothDevice? _device;
  BluetoothCharacteristic? _steps, _reset, _goal, _time, _sens, _imu;
  BluetoothCharacteristic? _batt, _clock, _rot, _bright; // optional
  final _subs = <StreamSubscription>[];

  int? _batPct; // 0-100
  int? _batMv; // battery millivolts
  DateTime? _clockNow; // watch RTC time (null = not set / unknown)
  int _rotVal = 0; // 0-3 (x90 deg)
  int _brightVal = 100; // %
  bool _imuSeen = false; // got non-zero IMU data → watch has a motion sensor

  Link _link = Link.off;
  String _statusText = 'Disconnected';
  String _note = 'Tap Connect to scan for your StepCounter watch.';
  int _stepsVal = 0;
  int _goalVal = 8000;
  int _sensVal = 5;
  int _sensSent = 5;
  String _watchTime = '—';

  bool get _on => _link == Link.on;

  @override
  void initState() {
    super.initState();
    _ticker.start();
  }

  @override
  void dispose() {
    _ticker.dispose();
    _cancelSubs();
    _goalCtl.dispose();
    imu.dispose();
    super.dispose();
  }

  // ---------------- helpers ----------------
  static int _u32(List<int> v) => v.length >= 4
      ? ByteData.sublistView(Uint8List.fromList(v)).getUint32(0, Endian.little)
      : 0;

  void _toast(String t) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(t, style: const TextStyle(color: C.text)),
          backgroundColor: C.btn,
          behavior: SnackBarBehavior.floating,
          width: 320,
          duration: const Duration(milliseconds: 2200),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(color: C.line),
          ),
        ),
      );
  }

  void _setStatus(Link l, String text, [String? note]) {
    if (!mounted) return;
    setState(() {
      _link = l;
      _statusText = text;
      if (note != null) _note = note;
    });
  }

  Future<void> _write(BluetoothCharacteristic c, List<int> bytes) {
    final p = c.properties;
    return c.write(bytes, withoutResponse: !p.write && p.writeWithoutResponse);
  }

  void _cancelSubs() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
  }

  String _err(Object e) {
    if (e is FlutterBluePlusException) return e.description ?? e.toString();
    return e.toString();
  }

  // ---------------- connection ----------------
  Future<void> _connect() async {
    if (!await FlutterBluePlus.isSupported) {
      _setStatus(Link.err, 'Failed', 'Bluetooth LE is not supported here.');
      return;
    }
    _setStatus(Link.busy, 'Scanning…', 'Waiting for Bluetooth…');
    final state = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
    if (state != BluetoothAdapterState.on) {
      _setStatus(
        Link.err,
        'Bluetooth off',
        state == BluetoothAdapterState.unauthorized
            ? 'Allow Bluetooth for Watch Lab in Settings → Privacy & Security → Bluetooth.'
            : 'Turn on Bluetooth in Control Centre, then tap Connect again.',
      );
      return;
    }

    var device = _device;
    if (device == null) {
      _setStatus(
        Link.busy,
        'Scanning…',
        'Pick your StepCounter from the list.',
      );
      device = await _pickDevice();
      if (device == null) {
        _setStatus(Link.off, 'Disconnected', 'No device selected.');
        return;
      }
    }

    _setStatus(Link.busy, 'Connecting…');
    try {
      await _bind(device);
    } catch (e) {
      _cancelSubs();
      try {
        await device.disconnect();
      } catch (_) {}
      _setStatus(Link.err, 'Failed', _err(e));
    }
  }

  Future<BluetoothDevice?> _pickDevice() async {
    await FlutterBluePlus.startScan(
      timeout: const Duration(seconds: 15),
      webOptionalServices: [kService],
    );
    if (!mounted) return null;
    final picked = await showModalBottomSheet<BluetoothDevice>(
      context: context,
      backgroundColor: C.panel,
      showDragHandle: true,
      constraints: const BoxConstraints(maxWidth: 560),
      builder: (_) => const _ScanSheet(),
    );
    await FlutterBluePlus.stopScan();
    return picked;
  }

  Future<void> _bind(BluetoothDevice d) async {
    _cancelSubs();
    await d.connect(
      license: License.nonprofit,
      timeout: const Duration(seconds: 15),
    );
    _device = d;

    _subs.add(
      d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected && _on) _onOff();
      }),
    );

    final services = await d.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid == kService,
      orElse: () => throw 'StepCounter service not found on this device.',
    );
    BluetoothCharacteristic ch(Guid id) => svc.characteristics.firstWhere(
      (c) => c.uuid == id,
      orElse: () => throw 'Characteristic $id missing.',
    );
    BluetoothCharacteristic? opt(Guid id) {
      for (final c in svc.characteristics) {
        if (c.uuid == id) return c;
      }
      return null;
    }

    _steps = ch(kSteps);
    _reset = ch(kReset);
    _goal = ch(kGoal);
    _time = ch(kTime);
    _sens = ch(kSens);
    _imu = ch(kImu);
    _batt = opt(kBatt);
    _clock = opt(kClock);
    _rot = opt(kRot);
    _bright = opt(kBright);
    _imuSeen = false;

    _subs.add(
      _steps!.onValueReceived.listen((v) {
        if (mounted) setState(() => _stepsVal = _u32(v));
      }),
    );
    _subs.add(
      _imu!.onValueReceived.listen((v) {
        if (v.length < 8) return;
        final bd = ByteData.sublistView(Uint8List.fromList(v));
        imu.raw['x'] = bd.getInt16(0, Endian.little).toDouble();
        imu.raw['y'] = bd.getInt16(2, Endian.little).toDouble();
        imu.raw['z'] = bd.getInt16(4, Endian.little).toDouble();
        imu.raw['mag'] = bd.getInt16(6, Endian.little).toDouble();
        if (!_imuSeen && v.any((b) => b != 0) && mounted) {
          setState(() => _imuSeen = true);
        }
      }),
    );
    await _steps!.setNotifyValue(true);
    await _imu!.setNotifyValue(true);

    if (_batt != null) {
      _subs.add(_batt!.onValueReceived.listen(_onBattery));
      await _batt!.setNotifyValue(true);
    }
    if (_clock != null) {
      _subs.add(_clock!.onValueReceived.listen(_onClock));
      await _clock!.setNotifyValue(true);
    }

    final name = d.platformName.isNotEmpty ? d.platformName : 'XIAO';
    _setStatus(
      Link.on,
      'Connected',
      'Connected to $name. Time synced automatically.',
    );

    final steps = await _steps!.read();
    final goal = await _goal!.read();
    final sens = await _sens!.read();
    if (!mounted) return;
    setState(() {
      _stepsVal = _u32(steps);
      _goalVal = _u32(goal);
      _goalCtl.text = '$_goalVal';
      if (sens.isNotEmpty) _sensVal = _sensSent = sens[0].clamp(1, 10);
    });
    if (_batt != null) _onBattery(await _batt!.read());
    if (_rot != null) {
      final r = await _rot!.read();
      if (r.isNotEmpty && mounted) setState(() => _rotVal = r[0] & 3);
    }
    if (_bright != null) {
      final b = await _bright!.read();
      if (b.isNotEmpty && mounted) {
        setState(() => _brightVal = b[0].clamp(5, 100));
      }
    }
    await _syncTime(auto: true);
  }

  void _onBattery(List<int> v) {
    if (v.length < 4 || !mounted) return;
    setState(() {
      _batPct = v[0].clamp(0, 100);
      _batMv = v[2] | (v[3] << 8);
    });
  }

  void _onClock(List<int> v) {
    if (v.length < 8 || !mounted) return;
    setState(() {
      _clockNow = v[7] == 1
          ? DateTime(1900 + v[0], v[1] + 1, v[2], v[3], v[4], v[5])
          : null;
    });
  }

  Future<void> _disconnect() async {
    try {
      await _device?.disconnect();
    } catch (_) {}
    _onOff();
  }

  void _onOff() {
    _cancelSubs();
    _steps = _reset = _goal = _time = _sens = _imu = null;
    _batt = _clock = _rot = _bright = null;
    _setStatus(
      Link.off,
      'Disconnected',
      'Disconnected. Connect again — it will reuse the last watch if still in range.',
    );
  }

  // ---------------- actions ----------------
  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _note = _err(e));
    }
  }

  Future<void> _syncTime({bool auto = false}) => _run(() async {
    final t = _time;
    if (t == null) return;
    final n = DateTime.now();
    await _write(t, [
      n.year - 1900,
      n.month - 1,
      n.day,
      n.hour,
      n.minute,
      n.second,
      n.weekday % 7, // JS getDay(): Sunday = 0
    ]);
    if (!mounted) return;
    setState(
      () => _watchTime =
          '${n.hour.toString().padLeft(2, '0')}:${n.minute.toString().padLeft(2, '0')}',
    );
    if (!auto) _toast('Watch clock set from this phone');
  });

  Future<void> _sendGoal() => _run(() async {
    final g = int.tryParse(_goalCtl.text);
    if (_goal == null || g == null || g < 1000 || g > 50000) {
      setState(() => _note = 'Goal must be 1000–50000.');
      return;
    }
    final b = ByteData(4)..setUint32(0, g, Endian.little);
    await _write(_goal!, b.buffer.asUint8List());
    setState(() => _goalVal = g);
    _toast('Goal $g sent');
  });

  Future<void> _sendSens(int v) => _run(() async {
    if (_sens == null) return;
    await _write(_sens!, [v]);
    setState(() => _sensSent = v);
    _toast('Sensitivity $v sent');
  });

  Future<void> _resetSteps() => _run(() async {
    if (_reset == null) return;
    await _write(_reset!, [1]);
    setState(() => _stepsVal = 0);
    _toast('Watch steps reset');
  });

  Future<void> _sendRotation(int r) => _run(() async {
    if (_rot == null) return;
    await _write(_rot!, [r & 3]);
    setState(() => _rotVal = r & 3);
    _toast('Screen rotated to ${r * 90}°');
  });

  Future<void> _sendBrightness(int p) => _run(() async {
    if (_bright == null) return;
    await _write(_bright!, [p.clamp(5, 100)]);
    _toast('Brightness $p% sent');
  });

  static String _sensWord(int v) =>
      v <= 3 ? 'strict' : (v >= 8 ? 'sensitive' : 'balanced');

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: DecoratedBox(
        decoration: const BoxDecoration(
          gradient: RadialGradient(
            center: Alignment(1.2, -1.4),
            radius: 1.3,
            colors: [Color(0xFF1A3050), C.bg],
            stops: [0, 0.55],
          ),
        ),
        child: SafeArea(
          child: LayoutBuilder(
            builder: (context, box) {
              final wide = box.maxWidth >= 900;
              return SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 36),
                child: Center(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 1120),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _header(),
                        const SizedBox(height: 16),
                        if (wide)
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(flex: 125, child: _mainCard()),
                              const SizedBox(width: 14),
                              Expanded(flex: 75, child: _sideCards()),
                            ],
                          )
                        else ...[
                          _mainCard(),
                          const SizedBox(height: 14),
                          _sideCards(),
                        ],
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _header() {
    final (Color fg, Color bg, Color border, Color dot) = switch (_link) {
      Link.on => (const Color(0xFF062012), C.ok, C.ok, const Color(0xFF062012)),
      Link.busy => (
        C.warn,
        const Color(0xFF0E141C),
        C.warn,
        const Color(0xFF5B6777),
      ),
      Link.err => (
        C.bad,
        const Color(0xFF0E141C),
        C.bad,
        const Color(0xFF5B6777),
      ),
      Link.off => (
        C.muted,
        const Color(0xFF0E141C),
        C.line,
        const Color(0xFF5B6777),
      ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Watch Lab',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                  color: C.text,
                ),
              ),
              SizedBox(height: 4),
              Text(
                'XIAO nRF54LM20A · goal, clock, sensitivity, live IMU',
                style: TextStyle(fontSize: 13, color: C.muted),
              ),
            ],
          ),
        ),
        AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
              ),
              const SizedBox(width: 8),
              Text(
                _statusText,
                style: TextStyle(
                  fontSize: 12,
                  color: fg,
                  fontWeight: _on ? FontWeight.w700 : FontWeight.w400,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _card({required List<Widget> children}) => Container(
    padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
    decoration: BoxDecoration(
      color: C.panel,
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: C.line),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    ),
  );

  Widget _label(String t) => Text(
    t.toUpperCase(),
    style: const TextStyle(
      color: C.muted,
      fontSize: 11,
      letterSpacing: 1.6,
      fontWeight: FontWeight.w700,
    ),
  );

  Widget _mainCard() {
    final pct = _goalVal > 0 ? math.min(1.0, _stepsVal / _goalVal) : 0.0;
    final hasBatt = _batt != null && _batPct != null;
    final batColor = !hasBatt
        ? C.accent
        : (_batPct! > 30 ? C.ok : (_batPct! > 15 ? C.warn : C.bad));
    final ringPct = hasBatt ? _batPct! / 100 : pct;
    final ringBig = hasBatt ? '$_batPct%' : '$_stepsVal';
    final ringSub = hasBatt
        ? 'BATTERY${_batMv != null ? '\n${(_batMv! / 1000).toStringAsFixed(2)} V' : ''}'
        : 'STEPS';
    final ring = SizedBox(
      width: 160,
      height: 160,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: ringPct),
        duration: const Duration(milliseconds: 350),
        curve: Curves.easeOut,
        builder: (_, v, child) => CustomPaint(
          painter: RingPainter(v, color: batColor),
          child: child,
        ),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                ringBig,
                style: const TextStyle(
                  fontSize: 34,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.5,
                  height: 1,
                  color: C.text,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 4),
              Text(
                ringSub,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: C.muted,
                  fontSize: 11,
                  letterSpacing: 1.8,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    Widget stat(String v, String l, {IconData? icon, double turns = 0}) =>
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: C.inset,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: C.line),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (icon != null) ...[
                    AnimatedRotation(
                      turns: turns,
                      duration: const Duration(milliseconds: 300),
                      child: Icon(icon, size: 18, color: C.accent),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      v,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: C.text,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                l,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: C.muted, fontSize: 11),
              ),
            ],
          ),
        );

    String two(int n) => n.toString().padLeft(2, '0');
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final c = _clockNow;
    final clockText = c != null
        ? '${two(c.hour)}:${two(c.minute)}:${two(c.second)}'
        : (_clock != null && _on ? 'not set' : _watchTime);
    final clockSub = c != null
        ? 'watch clock · ${c.day} ${months[c.month - 1]}'
        : 'watch clock';

    final stats = hasBatt || _rot != null
        ? Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: stat(
                      clockText,
                      clockSub,
                      icon: Icons.schedule_rounded,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: stat(
                      '${_rotVal * 90}°',
                      'screen rotation',
                      icon: Icons.screen_rotation_alt_rounded,
                      turns: _rotVal / 4,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(
                    child: stat(
                      '$_stepsVal',
                      'steps · ${(pct * 100).round()}% of goal',
                      icon: Icons.directions_walk_rounded,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: stat(
                      '$_brightVal%',
                      'brightness',
                      icon: Icons.light_mode_rounded,
                    ),
                  ),
                ],
              ),
            ],
          )
        : Column(
            children: [
              Row(
                children: [
                  Expanded(child: stat('$_goalVal', 'daily goal')),
                  const SizedBox(width: 10),
                  Expanded(child: stat('${(pct * 100).round()}%', 'of goal')),
                ],
              ),
              const SizedBox(height: 10),
              Row(
                children: [
                  Expanded(child: stat('$_sensSent', 'sensitivity')),
                  const SizedBox(width: 10),
                  Expanded(child: stat(_watchTime, 'watch clock')),
                ],
              ),
            ],
          );

    Widget legend(String key, String label, Color color) => InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => imu.toggle(key, !imu.visible[key]!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 22,
              height: 22,
              child: Checkbox(
                value: imu.visible[key],
                onChanged: (v) => imu.toggle(key, v ?? true),
                activeColor: C.accent,
                side: const BorderSide(color: C.muted),
              ),
            ),
            const SizedBox(width: 6),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 6),
            Text(label, style: const TextStyle(color: C.muted, fontSize: 12)),
          ],
        ),
      ),
    );

    return _card(
      children: [
        LayoutBuilder(
          builder: (_, b) {
            if (b.maxWidth < 560) {
              return Column(
                children: [ring, const SizedBox(height: 18), stats],
              );
            }
            return Row(
              children: [
                SizedBox(width: 170, child: Center(child: ring)),
                const SizedBox(width: 18),
                Expanded(child: stats),
              ],
            );
          },
        ),
        const SizedBox(height: 16),
        _label('IMU live'),
        const SizedBox(height: 8),
        if (_on && !_imuSeen)
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: C.inset,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: C.line),
            ),
            child: const Row(
              children: [
                Icon(Icons.sensors_off_rounded, color: C.muted),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'No motion data from this watch yet (the XIAO ESP32-S3 + Round Display '
                    'has no motion sensor), so steps and this chart stay off. '
                    'Time, battery, rotation and brightness work normally.',
                    style: TextStyle(color: C.muted, fontSize: 13),
                  ),
                ),
              ],
            ),
          )
        else ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Container(
              height: 200,
              color: C.plotBg,
              child: CustomPaint(painter: ImuPainter(imu)),
            ),
          ),
          const SizedBox(height: 8),
          ListenableBuilder(
            listenable: imu,
            builder: (_, _) => Wrap(
              spacing: 12,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                legend('mag', 'mag', C.mag),
                legend('x', 'X', C.ax),
                legend('y', 'Y', C.ay),
                legend('z', 'Z', C.az),
                Text(
                  'mag ${imu.shown['mag']!.round()} mg',
                  style: const TextStyle(color: C.muted, fontSize: 12),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  Widget _btn(
    String label, {
    VoidCallback? onPressed,
    bool primary = false,
    bool danger = false,
  }) {
    final bg = primary ? C.accent : (danger ? C.danger : C.btn);
    final fg = primary ? Colors.white : (danger ? C.dangerText : C.text);
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: fg,
          disabledBackgroundColor: bg.withValues(alpha: 0.38),
          disabledForegroundColor: fg.withValues(alpha: 0.38),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
        ),
        child: Text(label),
      ),
    );
  }

  Widget _sideCards() {
    final busy = _link == Link.busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card(
          children: [
            _label('Connection'),
            Row(
              children: [
                Expanded(
                  child: _btn(
                    'Connect',
                    primary: true,
                    onPressed: _on || busy ? null : _connect,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _btn(
                    'Disconnect',
                    onPressed: _on ? _disconnect : null,
                  ),
                ),
              ],
            ),
            _btn(
              'Sync phone date & time',
              onPressed: _on ? () => _syncTime() : null,
            ),
            _btn(
              'Reset steps on watch',
              danger: true,
              onPressed: _on ? _resetSteps : null,
            ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                _note,
                style: const TextStyle(color: C.muted, fontSize: 13),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        _card(
          children: [
            _label('Watch screen'),
            const SizedBox(height: 4),
            const Text(
              'Rotation',
              style: TextStyle(color: C.muted, fontSize: 13),
            ),
            Row(
              children: [
                for (var r = 0; r < 4; r++) ...[
                  if (r > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _btn(
                      '${r * 90}°',
                      primary: _on && _rot != null && _rotVal == r,
                      onPressed: _on && _rot != null && _rotVal != r
                          ? () => _sendRotation(r)
                          : null,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            Text(
              'Brightness $_brightVal%',
              style: const TextStyle(color: C.muted, fontSize: 13),
            ),
            Slider(
              value: _brightVal.toDouble(),
              min: 5,
              max: 100,
              divisions: 19,
              label: '$_brightVal%',
              onChanged: _on && _bright != null
                  ? (v) => setState(() => _brightVal = v.round())
                  : null,
              onChangeEnd: _on && _bright != null
                  ? (v) => _sendBrightness(v.round())
                  : null,
            ),
            if (_on && _rot == null && _bright == null)
              const Text(
                'This watch firmware has no screen controls.',
                style: TextStyle(color: C.muted, fontSize: 12),
              ),
          ],
        ),
        const SizedBox(height: 14),
        _card(
          children: [
            _label('Daily goal'),
            const SizedBox(height: 8),
            TextField(
              controller: _goalCtl,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              style: const TextStyle(fontSize: 16, color: C.text),
              decoration: InputDecoration(
                filled: true,
                fillColor: C.plotBg,
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 12,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: C.accent),
                ),
              ),
            ),
            const SizedBox(height: 2),
            Row(
              children: [
                for (final (i, g) in const [
                  5000,
                  8000,
                  10000,
                  12000,
                ].indexed) ...[
                  if (i > 0) const SizedBox(width: 8),
                  Expanded(
                    child: _btn(
                      '${g ~/ 1000}k',
                      onPressed: () => setState(() => _goalCtl.text = '$g'),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 2),
            _btn('Send goal', primary: true, onPressed: _on ? _sendGoal : null),
          ],
        ),
        const SizedBox(height: 14),
        _card(
          children: [
            _label('Step sensitivity'),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                '$_sensVal — ${_sensWord(_sensVal)}',
                style: const TextStyle(color: C.muted, fontSize: 13),
              ),
            ),
            Slider(
              value: _sensVal.toDouble(),
              min: 1,
              max: 10,
              divisions: 9,
              label: '$_sensVal',
              onChanged: _on
                  ? (v) => setState(() => _sensVal = v.round())
                  : null,
              onChangeEnd: _on ? (v) => _sendSens(v.round()) : null,
            ),
            const Text(
              '1 strict (fewer false steps) · 10 sensitive (lighter motion)',
              style: TextStyle(color: C.muted, fontSize: 13),
            ),
          ],
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Scan sheet: lists StepCounter watches found nearby (replaces the browser's
// device picker, which iOS apps don't have).
// ---------------------------------------------------------------------------
class _ScanSheet extends StatelessWidget {
  const _ScanSheet();

  static bool _isWatch(ScanResult r) =>
      r.advertisementData.advName.startsWith(kNamePrefix) ||
      r.device.platformName.startsWith(kNamePrefix) ||
      r.advertisementData.serviceUuids.contains(kService);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(
                  child: Text(
                    'Choose your watch',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: C.text,
                    ),
                  ),
                ),
                StreamBuilder<bool>(
                  stream: FlutterBluePlus.isScanning,
                  initialData: FlutterBluePlus.isScanningNow,
                  builder: (_, s) => s.data == true
                      ? const SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : TextButton(
                          onPressed: () => FlutterBluePlus.startScan(
                            timeout: const Duration(seconds: 15),
                            webOptionalServices: [kService],
                          ),
                          child: const Text('Scan again'),
                        ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 120, maxHeight: 320),
              child: StreamBuilder<List<ScanResult>>(
                stream: FlutterBluePlus.scanResults,
                initialData: FlutterBluePlus.lastScanResults,
                builder: (_, snap) {
                  final list = (snap.data ?? []).where(_isWatch).toList()
                    ..sort((a, b) => b.rssi.compareTo(a.rssi));
                  if (list.isEmpty) {
                    return const Center(
                      child: Text(
                        'Looking for StepCounter…\nMake sure the watch is on and nearby.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: C.muted),
                      ),
                    );
                  }
                  return ListView.separated(
                    shrinkWrap: true,
                    itemCount: list.length,
                    separatorBuilder: (_, _) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final r = list[i];
                      final name = r.advertisementData.advName.isNotEmpty
                          ? r.advertisementData.advName
                          : (r.device.platformName.isNotEmpty
                                ? r.device.platformName
                                : 'StepCounter');
                      return ListTile(
                        tileColor: C.inset,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                          side: const BorderSide(color: C.line),
                        ),
                        leading: const Icon(
                          Icons.watch_rounded,
                          color: C.accent,
                        ),
                        title: Text(
                          name,
                          style: const TextStyle(color: C.text),
                        ),
                        subtitle: Text(
                          'Signal ${r.rssi} dBm',
                          style: const TextStyle(color: C.muted),
                        ),
                        trailing: const Icon(
                          Icons.chevron_right,
                          color: C.muted,
                        ),
                        onTap: () => Navigator.pop(context, r.device),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
