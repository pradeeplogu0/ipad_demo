import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'face_designer.dart';
import 'face_layout.dart';
import 'face_painter.dart';

// ---------------------------------------------------------------------------
// Watch protocol — service 4b0ad7a0-…; see firmware/RoundWatchESP32/ble_service.cpp
// ---------------------------------------------------------------------------
Guid _u(String c) => Guid('4b0ad7$c-4b2c-11ee-be56-0242ac120002');
final Guid kService = _u('a0');
final Guid kSteps = _u('a1'); // R N  u32
final Guid kReset = _u('a2'); // W    0x01
final Guid kGoal = _u('a3'); // R W  u32
final Guid kTime = _u('a4'); // W    7 bytes
final Guid kSens = _u('a5'); // R W  u8 1-10
final Guid kImu = _u('a6'); // R N  4x i16
final Guid kBatt = _u('a7'); // R N  [pct, 0, mv u16]
final Guid kClock = _u('a8'); // R N  [yr-1900, mon0, d, h, m, s, wday, valid]
final Guid kRot = _u('a9'); // R W N 0-3
final Guid kBright = _u('aa'); // R W N 5-100
final Guid kFormat = _u('ab'); // R W N 0 = 24 h, 1 = 12 h
final Guid kFace = _u('ac'); // R W N 0 = digital, 1 = pendant
final Guid kSleep = _u('ad');
final Guid kLayout = _u(
  'ae',
); // R W N face designer // R W N seconds, 0 = always on
const String kNamePrefix = 'StepCounter';
const String kPrefLastWatch = 'last_watch_id';

// ---------------------------------------------------------------------------
// Palette
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
  static const gold = Color(0xFFD4AF37);
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

  static Color battery(int? pct) =>
      pct == null ? muted : (pct > 30 ? ok : (pct > 15 ? warn : bad));
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
        segmentedButtonTheme: SegmentedButtonThemeData(
          style: ButtonStyle(
            side: const WidgetStatePropertyAll(BorderSide(color: C.line)),
            backgroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.selected) ? C.accent : C.btn,
            ),
            foregroundColor: WidgetStateProperty.resolveWith(
              (s) => s.contains(WidgetState.disabled)
                  ? C.muted.withValues(alpha: 0.5)
                  : (s.contains(WidgetState.selected) ? Colors.white : C.text),
            ),
            textStyle: const WidgetStatePropertyAll(
              TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
            ),
            shape: WidgetStatePropertyAll(
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ),
      ),
      home: const WatchLabPage(),
    );
  }
}

// ---------------------------------------------------------------------------
// IMU plot model (only shown when the watch has a motion sensor)
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
      canvas.drawLine(Offset(0, h * i / 4), Offset(w, h * i / 4), grid);
    }
    void line(List<double> arr, Color color) {
      if (arr.length < 2) return;
      double x(int i) => i / (ImuModel.maxN - 1) * w;
      double y(double v) => h / 2 - (v / 2500) * h * 0.42;
      final path = Path()..moveTo(x(0), y(arr[0]));
      for (var i = 1; i < arr.length; i++) {
        final x0 = x(i - 1), y0 = y(arr[i - 1]);
        path.quadraticBezierTo(x0, y0, (x0 + x(i)) / 2, (y0 + y(arr[i])) / 2);
      }
      canvas.drawPath(
        path,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..strokeCap = StrokeCap.round,
      );
    }

    if (m.visible['x']!) line(m.hist['x']!, C.ax);
    if (m.visible['y']!) line(m.hist['y']!, C.ay);
    if (m.visible['z']!) line(m.hist['z']!, C.az);
    if (m.visible['mag']!) line(m.hist['mag']!, C.mag);
  }

  @override
  bool shouldRepaint(ImuPainter old) => false;
}

// Battery history sparkline
class SparkPainter extends CustomPainter {
  SparkPainter(this.values, this.color);
  final List<double> values;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (values.length < 2) return;
    var lo = values.reduce(math.min), hi = values.reduce(math.max);
    if (hi - lo < 4) {
      final mid = (hi + lo) / 2;
      lo = mid - 2;
      hi = mid + 2;
    }
    Offset pt(int i) => Offset(
      i / (values.length - 1) * size.width,
      size.height - (values[i] - lo) / (hi - lo) * size.height,
    );
    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < values.length; i++) {
      path.lineTo(pt(i).dx, pt(i).dy);
    }
    final fill = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(
      fill,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [color.withValues(alpha: 0.35), color.withValues(alpha: 0)],
        ).createShader(Offset.zero & size),
    );
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(SparkPainter old) => true;
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
  BluetoothCharacteristic? _batt,
      _clock,
      _rot,
      _bright,
      _format,
      _face,
      _sleep,
      _layoutChr;
  final _subs = <StreamSubscription>[];
  bool _userDisconnect = false;
  String? _savedId;

  Link _link = Link.off;
  String _statusText = 'Disconnected';
  String _note = 'Tap Connect to find your watch.';
  String _deviceName = '';

  int _stepsVal = 0, _goalVal = 8000, _sensVal = 5;
  int? _batPct, _batMv;
  final _batHist = <double>[];
  DateTime? _batAt;
  DateTime? _clockNow;
  int? _driftSec; // watch - phone, seconds
  int _rotVal = 0,
      _brightVal = 100,
      _formatVal = 0,
      _faceVal = 0,
      _sleepVal = 0;
  bool _imuSeen = false;
  final _layout = FaceLayout();
  (int, int)? _dragSkip; // element being dragged in the designer
  Future<void> _writeQueue = Future.value();

  bool get _on => _link == Link.on;
  bool get _hasScreen => _on && _rot != null;
  bool get _showSteps => _imuSeen || (_on && _batt == null);

  @override
  void initState() {
    super.initState();
    _ticker.start();
    _loadSaved();
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
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(t, style: const TextStyle(color: C.text)),
          backgroundColor: C.btn,
          behavior: SnackBarBehavior.floating,
          width: 320,
          duration: const Duration(milliseconds: 1800),
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

  Future<void> _run(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (mounted) setState(() => _note = _err(e));
    }
  }

  // ---------------- remembered watch ----------------
  Future<void> _loadSaved() async {
    try {
      final p = await SharedPreferences.getInstance();
      _savedId = p.getString(kPrefLastWatch);
    } catch (_) {}
    if (_savedId != null && mounted) {
      setState(() {});
      _connect(auto: true);
    }
  }

  Future<void> _saveWatch(String? id) async {
    _savedId = id;
    try {
      final p = await SharedPreferences.getInstance();
      if (id == null) {
        await p.remove(kPrefLastWatch);
      } else {
        await p.setString(kPrefLastWatch, id);
      }
    } catch (_) {}
  }

  // ---------------- connection ----------------
  Future<bool> _bluetoothReady() async {
    if (!await FlutterBluePlus.isSupported) {
      _setStatus(
        Link.err,
        'No Bluetooth',
        'Bluetooth LE is not supported here.',
      );
      return false;
    }
    final state = await FlutterBluePlus.adapterState
        .where((s) => s != BluetoothAdapterState.unknown)
        .first
        .timeout(
          const Duration(seconds: 5),
          onTimeout: () => BluetoothAdapterState.unknown,
        );
    if (state == BluetoothAdapterState.on) return true;
    _setStatus(
      Link.err,
      'Bluetooth off',
      state == BluetoothAdapterState.unauthorized
          ? 'Allow Bluetooth for Watch Lab in Settings → Privacy & Security → Bluetooth.'
          : 'Turn on Bluetooth in Control Centre, then tap Connect.',
    );
    return false;
  }

  /// Finds the remembered watch by scanning for its id (works on iOS, where
  /// ids are per-phone UUIDs, without showing the picker).
  Future<BluetoothDevice?> _findSaved(String id) async {
    final done = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((rs) {
      for (final r in rs) {
        if (r.device.remoteId.str == id && !done.isCompleted) {
          done.complete(r.device);
        }
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withRemoteIds: [id],
        timeout: const Duration(seconds: 10),
        webOptionalServices: [kService],
      );
      return await done.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () => null,
      );
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> _connect({bool auto = false}) async {
    if (_link == Link.busy || _on) return;
    if (!await _bluetoothReady()) return;
    _userDisconnect = false;

    var device = _device;
    if (device == null && _savedId != null && !FlutterBluePlus.isScanningNow) {
      _setStatus(Link.busy, 'Searching…', 'Looking for your watch…');
      try {
        device = await _findSaved(_savedId!);
      } catch (_) {}
      if (device == null && auto) {
        _setStatus(
          Link.off,
          'Disconnected',
          'Your watch is not in range. Tap Connect when it is nearby.',
        );
        return;
      }
    }
    if (device == null) {
      _setStatus(Link.busy, 'Scanning…', 'Pick your watch from the list.');
      device = await _pickDevice();
      if (device == null) {
        _setStatus(Link.off, 'Disconnected', 'No watch selected.');
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
        if (s == BluetoothConnectionState.disconnected && _on) _onLost();
      }),
    );

    final services = await d.discoverServices();
    final svc = services.firstWhere(
      (s) => s.uuid == kService,
      orElse: () => throw 'This device is not a StepCounter watch.',
    );
    BluetoothCharacteristic? opt(Guid id) {
      for (final c in svc.characteristics) {
        if (c.uuid == id) return c;
      }
      return null;
    }

    BluetoothCharacteristic req(Guid id) =>
        opt(id) ?? (throw 'Watch is missing characteristic $id.');

    _steps = req(kSteps);
    _reset = req(kReset);
    _goal = req(kGoal);
    _time = req(kTime);
    _sens = req(kSens);
    _imu = req(kImu);
    _batt = opt(kBatt);
    _clock = opt(kClock);
    _rot = opt(kRot);
    _bright = opt(kBright);
    _format = opt(kFormat);
    _face = opt(kFace);
    _sleep = opt(kSleep);
    _layoutChr = opt(kLayout);
    _imuSeen = false;
    _batHist.clear();

    Future<void> listen(
      BluetoothCharacteristic? c,
      void Function(List<int>) f, {
      bool read = true,
    }) async {
      if (c == null) return;
      _subs.add(c.onValueReceived.listen(f));
      if (c.properties.notify) await c.setNotifyValue(true);
      if (read && c.properties.read) f(await c.read());
    }

    int b0(List<int> v, int lo, int hi, int fallback) =>
        v.isEmpty ? fallback : v[0].clamp(lo, hi);

    await listen(_steps, (v) => _set(() => _stepsVal = _u32(v)));
    await listen(_imu, _onImu, read: false);
    await listen(_batt, _onBattery);
    await listen(_clock, _onClock);
    await listen(_rot, (v) => _set(() => _rotVal = b0(v, 0, 3, 0)));
    await listen(_bright, (v) => _set(() => _brightVal = b0(v, 5, 100, 100)));
    await listen(_format, (v) => _set(() => _formatVal = b0(v, 0, 1, 0)));
    await listen(_face, (v) => _set(() => _faceVal = b0(v, 0, 1, 0)));
    await listen(_sleep, (v) => _set(() => _sleepVal = b0(v, 0, 255, 0)));
    await listen(
      _layoutChr,
      (v) => _set(() => _layout.apply(v, skip: _dragSkip)),
    );

    final goal = await _goal!.read();
    final sens = await _sens!.read();
    _deviceName = d.platformName.isNotEmpty ? d.platformName : 'StepCounter';
    _set(() {
      _goalVal = _u32(goal);
      _goalCtl.text = '$_goalVal';
      _sensVal = b0(sens, 1, 10, 5);
    });

    await _saveWatch(d.remoteId.str);
    _setStatus(Link.on, 'Connected', 'Connected to $_deviceName.');
    HapticFeedback.mediumImpact();
    await _syncTime(auto: true);
  }

  void _set(VoidCallback f) {
    if (mounted) setState(f);
  }

  void _onImu(List<int> v) {
    if (v.length < 8) return;
    final bd = ByteData.sublistView(Uint8List.fromList(v));
    imu.raw['x'] = bd.getInt16(0, Endian.little).toDouble();
    imu.raw['y'] = bd.getInt16(2, Endian.little).toDouble();
    imu.raw['z'] = bd.getInt16(4, Endian.little).toDouble();
    imu.raw['mag'] = bd.getInt16(6, Endian.little).toDouble();
    if (!_imuSeen && v.any((b) => b != 0)) _set(() => _imuSeen = true);
  }

  void _onBattery(List<int> v) {
    if (v.length < 4) return;
    _set(() {
      _batPct = v[0].clamp(0, 100);
      _batMv = v[2] | (v[3] << 8);
      _batAt = DateTime.now();
      _batHist.add(_batMv! / 1000);
      if (_batHist.length > 300) _batHist.removeAt(0); // ~10 min at 2 s
    });
  }

  void _onClock(List<int> v) {
    if (v.length < 8) return;
    _set(() {
      if (v[7] == 1) {
        _clockNow = DateTime(1900 + v[0], v[1] + 1, v[2], v[3], v[4], v[5]);
        _driftSec = _clockNow!.difference(DateTime.now()).inSeconds;
      } else {
        _clockNow = null;
        _driftSec = null;
      }
    });
  }

  Future<void> _disconnect() async {
    _userDisconnect = true;
    try {
      await _device?.disconnect();
    } catch (_) {}
    _onOff('Disconnected. Tap Connect to reconnect to $_deviceName.');
  }

  void _onOff(String note) {
    _cancelSubs();
    _steps = _reset = _goal = _time = _sens = _imu = null;
    _batt = _clock = _rot = _bright = _format = _face = _sleep = _layoutChr =
        null;
    _setStatus(Link.off, 'Disconnected', note);
  }

  /// Unexpected disconnect (out of range, watch reset): try to come back.
  void _onLost() {
    _onOff('Connection lost — reconnecting…');
    if (_userDisconnect) return;
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted && !_on && _link != Link.busy && !_userDisconnect) {
        _device = null; // re-find by saved id
        _connect(auto: true);
      }
    });
  }

  Future<void> _forget() async {
    await _disconnect();
    _device = null;
    await _saveWatch(null);
    _set(() => _note = 'Watch forgotten. Tap Connect to pick a watch.');
  }

  // ---------------- actions ----------------
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
      n.weekday % 7, // Sunday = 0
    ]);
    if (!auto) {
      HapticFeedback.selectionClick();
      _toast('Watch clock set from this phone');
    }
  });

  Future<void> _sendByte(
    BluetoothCharacteristic? c,
    int v,
    String msg,
    VoidCallback local,
  ) => _run(() async {
    if (c == null) return;
    HapticFeedback.selectionClick();
    _set(local); // optimistic; the watch confirms via notify
    await _write(c, [v]);
    if (msg.isNotEmpty) _toast(msg);
  });

  Future<void> _sendGoal() => _run(() async {
    final g = int.tryParse(_goalCtl.text);
    if (_goal == null || g == null || g < 1000 || g > 50000) {
      _set(() => _note = 'Goal must be 1000–50000.');
      return;
    }
    final b = ByteData(4)..setUint32(0, g, Endian.little);
    await _write(_goal!, b.buffer.asUint8List());
    _set(() => _goalVal = g);
    _toast('Goal $g sent');
  });

  Future<void> _resetSteps() => _run(() async {
    if (_reset == null) return;
    await _write(_reset!, [1]);
    _set(() => _stepsVal = 0);
    _toast('Watch steps reset');
  });

  // ---------------- UI ----------------
  WatchFace _faceFor(int face) => WatchFace(
    face: face,
    elements: _layout.faces[face],
    h12: _formatVal == 1,
    time: _clockNow,
    batPct: _batPct,
    batMv: _batMv,
    rotation: _rotVal,
    connected: _on,
    steps: _stepsVal,
  );

  WatchFace get _faceModel => _faceFor(_faceVal);

  // ---------------- face designer ----------------
  bool get _canDesign => _on && _layoutChr != null;

  Future<void> _queueWrite(List<int> bytes) {
    final c = _layoutChr;
    if (c == null) return Future.value();
    return _writeQueue = _writeQueue
        .then((_) => _write(c, bytes))
        .catchError((Object e) => _set(() => _note = _err(e)));
  }

  Future<void> _openDesigner() async {
    if (!_canDesign) {
      _toast('Connect to your watch to customise its face');
      return;
    }
    HapticFeedback.selectionClick();
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => FaceDesignerPage(
          layout: _layout,
          initialFace: _faceVal,
          faceFor: _faceFor,
          onEdit: (e) => _queueWrite(e.encode()),
          onReset: () => _queueWrite([0xFF]),
          onShowFace: (f) async {
            if (_faceVal != f && _face != null) {
              _set(() => _faceVal = f);
              await _write(_face!, [f]);
            }
          },
          onDragging: (el) => _dragSkip = el,
        ),
      ),
    );
    _set(() {});
  }

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
              final left = <Widget>[
                _heroCard(),
                const SizedBox(height: 14),
                _batteryCard(),
                if (_imuSeen) ...[const SizedBox(height: 14), _imuCard()],
              ];
              final right = <Widget>[
                _connectionCard(),
                const SizedBox(height: 14),
                _clockCard(),
                const SizedBox(height: 14),
                _displayCard(),
                if (_showSteps) ...[const SizedBox(height: 14), _stepsCard()],
              ];
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
                              Expanded(
                                flex: 11,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: left,
                                ),
                              ),
                              const SizedBox(width: 14),
                              Expanded(
                                flex: 9,
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: right,
                                ),
                              ),
                            ],
                          )
                        else ...[
                          ...left,
                          const SizedBox(height: 14),
                          ...right,
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
    final (Color fg, Color bg, Color border) = switch (_link) {
      Link.on => (const Color(0xFF062012), C.ok, C.ok),
      Link.busy => (C.warn, const Color(0xFF0E141C), C.warn),
      Link.err => (C.bad, const Color(0xFF0E141C), C.bad),
      Link.off => (C.muted, const Color(0xFF0E141C), C.line),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Watch Lab',
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -1,
                  color: C.text,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _on
                    ? '$_deviceName · XIAO ESP32-S3 Round Display'
                    : 'Pendant & watch companion',
                style: const TextStyle(fontSize: 13, color: C.muted),
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
              if (_link == Link.busy)
                const SizedBox(
                  width: 10,
                  height: 10,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: C.warn,
                  ),
                )
              else
                Icon(
                  _on ? Icons.bluetooth_connected : Icons.bluetooth,
                  size: 14,
                  color: fg,
                ),
              const SizedBox(width: 6),
              Text(
                _statusText,
                style: TextStyle(
                  fontSize: 12,
                  color: fg,
                  fontWeight: _on ? FontWeight.w700 : FontWeight.w500,
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

  Widget _label(String t, {IconData? icon}) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Row(
      children: [
        if (icon != null) ...[
          Icon(icon, size: 14, color: C.muted),
          const SizedBox(width: 6),
        ],
        Text(
          t.toUpperCase(),
          style: const TextStyle(
            color: C.muted,
            fontSize: 11,
            letterSpacing: 1.6,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    ),
  );

  Widget _stat(String value, String label, {IconData? icon, Color? color}) =>
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
                  Icon(icon, size: 16, color: color ?? C.accent),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(
                    value,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: color ?? C.text,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 2),
            Text(
              label,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: C.muted, fontSize: 11),
            ),
          ],
        ),
      );

  String _fmtTime(DateTime t, {bool seconds = true}) {
    String two(int n) => n.toString().padLeft(2, '0');
    final s = seconds ? ':${two(t.second)}' : '';
    if (_formatVal == 0) return '${two(t.hour)}:${two(t.minute)}$s';
    final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
    return '$h:${two(t.minute)}$s ${t.hour < 12 ? 'AM' : 'PM'}';
  }

  Widget _heroCard() {
    final preview = LayoutBuilder(
      builder: (_, b) {
        final size = math.min(260.0, b.maxWidth);
        return Center(
          child: WatchPreview(
            face: _faceModel,
            size: size,
            onTap: _canDesign ? _openDesigner : null,
          ),
        );
      },
    );
    final c = _clockNow;
    final stats = Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _stat(
                c == null ? (_on ? 'not set' : '—') : _fmtTime(c),
                'watch time',
                icon: Icons.schedule_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _stat(
                _batPct == null ? '—' : '$_batPct%',
                'battery',
                icon: Icons.battery_charging_full_rounded,
                color: _batPct == null ? null : C.battery(_batPct),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: _stat(
                '${_rotVal * 90}°',
                'screen rotation',
                icon: Icons.screen_rotation_alt_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _stat(
                _faceVal == 1 ? 'Pendant' : 'Digital',
                'watch face',
                icon: _faceVal == 1
                    ? Icons.diamond_outlined
                    : Icons.watch_rounded,
                color: _faceVal == 1 ? C.gold : null,
              ),
            ),
          ],
        ),
        if (_imuSeen) ...[
          const SizedBox(height: 10),
          _stat(
            '$_stepsVal',
            'steps · goal $_goalVal',
            icon: Icons.directions_walk_rounded,
          ),
        ],
      ],
    );

    return _card(
      children: [
        _label('Live watch', icon: Icons.visibility_outlined),
        LayoutBuilder(
          builder: (_, b) {
            if (b.maxWidth < 560) {
              return Column(
                children: [preview, const SizedBox(height: 18), stats],
              );
            }
            return Row(
              children: [
                SizedBox(width: 270, child: preview),
                const SizedBox(width: 18),
                Expanded(child: stats),
              ],
            );
          },
        ),
        if (!_on)
          const Padding(
            padding: EdgeInsets.only(top: 14),
            child: Text(
              'Connect to see the watch live. The preview mirrors its '
              'face, time, battery and rotation.',
              textAlign: TextAlign.center,
              style: TextStyle(color: C.muted, fontSize: 13),
            ),
          ),
      ],
    );
  }

  Widget _batteryCard() {
    final col = C.battery(_batPct);
    final ago = _batAt == null
        ? null
        : DateTime.now().difference(_batAt!).inSeconds;
    final health = _batPct == null
        ? '—'
        : (_batPct! > 30 ? 'Good' : (_batPct! > 15 ? 'Low' : 'Charge soon'));
    return _card(
      children: [
        _label('Battery · live', icon: Icons.bolt_rounded),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _batPct == null ? '—' : '$_batPct%',
              style: TextStyle(
                fontSize: 40,
                height: 1,
                fontWeight: FontWeight.w800,
                letterSpacing: -1.5,
                color: _batPct == null ? C.muted : col,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _batMv == null
                        ? ''
                        : '${(_batMv! / 1000).toStringAsFixed(3)} V',
                    style: const TextStyle(
                      color: C.text,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Text(
                    _batPct == null
                        ? (_on ? 'waiting for watch…' : 'not connected')
                        : '$health · updated ${ago! <= 1 ? 'now' : '${ago}s ago'}',
                    style: const TextStyle(color: C.muted, fontSize: 12),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: LinearProgressIndicator(
            value: (_batPct ?? 0) / 100,
            minHeight: 8,
            color: col,
            backgroundColor: C.grid,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          height: 70,
          decoration: BoxDecoration(
            color: C.plotBg,
            borderRadius: BorderRadius.circular(10),
          ),
          padding: const EdgeInsets.all(8),
          child: _batHist.length < 2
              ? const Center(
                  child: Text(
                    'Voltage history appears here',
                    style: TextStyle(color: C.muted, fontSize: 12),
                  ),
                )
              : CustomPaint(painter: SparkPainter(List.of(_batHist), col)),
        ),
        const SizedBox(height: 6),
        Text(
          _batHist.length < 2
              ? 'Updates every 2 seconds while connected.'
              : 'Voltage, last ${(_batHist.length * 2 / 60).toStringAsFixed(1)} min',
          style: const TextStyle(color: C.muted, fontSize: 11),
        ),
      ],
    );
  }

  Widget _imuCard() {
    Widget legend(String key, String label, Color color) => InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => imu.toggle(key, !imu.visible[key]!),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              imu.visible[key]!
                  ? Icons.check_box_rounded
                  : Icons.check_box_outline_blank_rounded,
              size: 18,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(label, style: const TextStyle(color: C.muted, fontSize: 12)),
          ],
        ),
      ),
    );
    return _card(
      children: [
        _label('Motion · live', icon: Icons.sensors_rounded),
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Container(
            height: 180,
            color: C.plotBg,
            child: CustomPaint(painter: ImuPainter(imu)),
          ),
        ),
        const SizedBox(height: 8),
        ListenableBuilder(
          listenable: imu,
          builder: (_, _) => Wrap(
            spacing: 10,
            children: [
              legend('mag', 'mag', C.mag),
              legend('x', 'X', C.ax),
              legend('y', 'Y', C.ay),
              legend('z', 'Z', C.az),
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${imu.shown['mag']!.round()} mg',
                  style: const TextStyle(color: C.muted, fontSize: 12),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _btn(
    String label, {
    VoidCallback? onPressed,
    bool primary = false,
    bool danger = false,
    IconData? icon,
  }) {
    final bg = primary ? C.accent : (danger ? C.danger : C.btn);
    final fg = primary ? Colors.white : (danger ? C.dangerText : C.text);
    final style = FilledButton.styleFrom(
      backgroundColor: bg,
      foregroundColor: fg,
      disabledBackgroundColor: bg.withValues(alpha: 0.38),
      disabledForegroundColor: fg.withValues(alpha: 0.38),
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      textStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: icon == null
          ? FilledButton(onPressed: onPressed, style: style, child: Text(label))
          : FilledButton.icon(
              onPressed: onPressed,
              style: style,
              icon: Icon(icon, size: 18),
              label: Text(label),
            ),
    );
  }

  Widget _connectionCard() {
    final busy = _link == Link.busy;
    return _card(
      children: [
        _label('Connection', icon: Icons.link_rounded),
        Row(
          children: [
            Expanded(
              child: _btn(
                _savedId != null && !_on ? 'Reconnect' : 'Connect',
                primary: true,
                icon: Icons.bluetooth_searching_rounded,
                onPressed: _on || busy ? null : () => _connect(),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _btn('Disconnect', onPressed: _on ? _disconnect : null),
            ),
          ],
        ),
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            _note,
            style: const TextStyle(color: C.muted, fontSize: 13),
          ),
        ),
        if (_savedId != null)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: busy ? null : _forget,
              icon: const Icon(Icons.link_off_rounded, size: 16),
              label: const Text('Forget this watch'),
              style: TextButton.styleFrom(foregroundColor: C.muted),
            ),
          ),
      ],
    );
  }

  Widget _clockCard() {
    final d = _driftSec;
    final drift = d == null
        ? (_on ? 'Watch time not set yet' : '')
        : (d.abs() <= 2
              ? 'In sync with this phone'
              : 'Watch is ${d.abs()} s ${d > 0 ? 'ahead' : 'behind'}');
    return _card(
      children: [
        _label('Clock', icon: Icons.schedule_rounded),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: 0, label: Text('24-hour')),
            ButtonSegment(value: 1, label: Text('12-hour AM/PM')),
          ],
          selected: {_formatVal},
          onSelectionChanged: _on && _format != null
              ? (s) => _sendByte(
                  _format,
                  s.first,
                  'Time format: ${s.first == 1 ? '12-hour' : '24-hour'}',
                  () => _formatVal = s.first,
                )
              : null,
        ),
        _btn(
          'Sync time from phone',
          icon: Icons.sync_rounded,
          onPressed: _on ? () => _syncTime() : null,
        ),
        if (drift.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Icon(
                  d != null && d.abs() <= 2
                      ? Icons.check_circle_rounded
                      : Icons.info_outline_rounded,
                  size: 14,
                  color: d != null && d.abs() <= 2 ? C.ok : C.warn,
                ),
                const SizedBox(width: 6),
                Text(
                  drift,
                  style: const TextStyle(color: C.muted, fontSize: 12),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _displayCard() {
    const sleeps = [0, 10, 30, 60, 120];
    String sleepLabel(int s) =>
        s == 0 ? 'Always on' : (s < 60 ? '${s}s' : '${s ~/ 60} min');
    return _card(
      children: [
        _label('Display', icon: Icons.tune_rounded),
        _btn(
          'Customize face',
          primary: true,
          icon: Icons.brush_rounded,
          onPressed: _canDesign ? _openDesigner : null,
        ),
        const SizedBox(height: 14),
        const Text(
          'Watch face',
          style: TextStyle(color: C.muted, fontSize: 13),
        ),
        const SizedBox(height: 6),
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: 0,
              icon: Icon(Icons.watch_rounded),
              label: Text('Digital'),
            ),
            ButtonSegment(
              value: 1,
              icon: Icon(Icons.diamond_outlined),
              label: Text('Pendant'),
            ),
          ],
          selected: {_faceVal},
          onSelectionChanged: _on && _face != null
              ? (s) => _sendByte(
                  _face,
                  s.first,
                  s.first == 1 ? 'Pendant face on' : 'Digital face on',
                  () => _faceVal = s.first,
                )
              : null,
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Text(
              'Rotation',
              style: TextStyle(color: C.muted, fontSize: 13),
            ),
            const SizedBox(width: 12),
            Flexible(
              child: Text(
                'or long-press the watch',
                textAlign: TextAlign.right,
                style: TextStyle(
                  color: C.muted.withValues(alpha: 0.7),
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        Row(
          children: [
            for (var r = 0; r < 4; r++) ...[
              if (r > 0) const SizedBox(width: 8),
              Expanded(
                child: _btn(
                  '${r * 90}°',
                  primary: _hasScreen && _rotVal == r,
                  onPressed: _hasScreen && _rotVal != r
                      ? () => _sendByte(_rot, r, '', () => _rotVal = r)
                      : null,
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            const Icon(Icons.light_mode_rounded, size: 16, color: C.muted),
            const SizedBox(width: 6),
            Text(
              'Brightness $_brightVal%',
              style: const TextStyle(color: C.muted, fontSize: 13),
            ),
          ],
        ),
        Slider(
          value: _brightVal.toDouble(),
          min: 5,
          max: 100,
          divisions: 19,
          label: '$_brightVal%',
          onChanged: _on && _bright != null
              ? (v) => _set(() => _brightVal = v.round())
              : null,
          onChangeEnd: _on && _bright != null
              ? (v) => _sendByte(_bright, v.round(), '', () {})
              : null,
        ),
        const Text(
          'Screen sleep (pendant battery saver)',
          style: TextStyle(color: C.muted, fontSize: 13),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final s in sleeps)
              ChoiceChip(
                label: Text(sleepLabel(s)),
                selected: _sleepVal == s,
                showCheckmark: false,
                selectedColor: C.accent,
                backgroundColor: C.btn,
                side: const BorderSide(color: C.line),
                labelStyle: TextStyle(
                  color: _sleepVal == s ? Colors.white : C.text,
                  fontWeight: FontWeight.w600,
                ),
                onSelected: _on && _sleep != null
                    ? (_) => _sendByte(
                        _sleep,
                        s,
                        s == 0
                            ? 'Screen stays on'
                            : 'Screen sleeps after ${sleepLabel(s)} · tap to wake',
                        () => _sleepVal = s,
                      )
                    : null,
              ),
          ],
        ),
        if (_on && _rot == null)
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: Text(
              'This watch firmware has no display controls.',
              style: TextStyle(color: C.muted, fontSize: 12),
            ),
          ),
      ],
    );
  }

  static String _sensWord(int v) =>
      v <= 3 ? 'strict' : (v >= 8 ? 'sensitive' : 'balanced');

  Widget _stepsCard() {
    return _card(
      children: [
        _label('Steps', icon: Icons.directions_walk_rounded),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _goalCtl,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(fontSize: 16, color: C.text),
                decoration: InputDecoration(
                  labelText: 'Daily goal',
                  filled: true,
                  fillColor: C.plotBg,
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            SizedBox(
              width: 90,
              child: _btn(
                'Send',
                primary: true,
                onPressed: _on ? _sendGoal : null,
              ),
            ),
          ],
        ),
        Row(
          children: [
            for (final (i, g) in const [5000, 8000, 10000, 12000].indexed) ...[
              if (i > 0) const SizedBox(width: 8),
              Expanded(
                child: _btn(
                  '${g ~/ 1000}k',
                  onPressed: () => _set(() => _goalCtl.text = '$g'),
                ),
              ),
            ],
          ],
        ),
        const SizedBox(height: 12),
        Text(
          'Sensitivity $_sensVal — ${_sensWord(_sensVal)}',
          style: const TextStyle(color: C.muted, fontSize: 13),
        ),
        Slider(
          value: _sensVal.toDouble(),
          min: 1,
          max: 10,
          divisions: 9,
          label: '$_sensVal',
          onChanged: _on ? (v) => _set(() => _sensVal = v.round()) : null,
          onChangeEnd: _on
              ? (v) => _sendByte(
                  _sens,
                  v.round(),
                  'Sensitivity ${v.round()} sent',
                  () {},
                )
              : null,
        ),
        _btn(
          'Reset steps on watch',
          danger: true,
          onPressed: _on ? _resetSteps : null,
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Scan sheet: nearby StepCounter watches (iOS has no browser device picker).
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
