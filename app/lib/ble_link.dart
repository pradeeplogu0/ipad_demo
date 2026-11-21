import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'protocol.dart';

enum LinkState { off, scanning, connecting, connected }

/// BLE central for the NavDisplay: scan, connect, auto-reconnect, ordered
/// writes (with iOS flow control), keepalive pings and STATUS decoding.
class BleLink extends ChangeNotifier {
  LinkState state = LinkState.off;
  String message = 'Not connected';
  int? batteryPct, batteryMv;
  int payload = 20; // max message size = MTU - 3

  final _status = StreamController<DisplayStatus>.broadcast();
  Stream<DisplayStatus> get statuses => _status.stream;

  BluetoothDevice? _device;
  BluetoothCharacteristic? _rx;
  final _subs = <StreamSubscription>[];
  Future<void> _queue = Future.value();
  Timer? _ping, _retry;
  DateTime _lastSend = DateTime.fromMillisecondsSinceEpoch(0);
  bool _wanted = false; // user wants to be connected → auto-reconnect
  int _attempt = 0;
  static const _prefKey = 'navdisplay_id';

  bool get connected => state == LinkState.connected;

  void _set(LinkState s, String msg) {
    state = s;
    message = msg;
    notifyListeners();
  }

  /// Connect (and keep reconnecting) to the NavDisplay.
  Future<void> start() async {
    _wanted = true;
    _attempt = 0;
    await _connectOnce();
  }

  Future<void> stop() async {
    _wanted = false;
    _retry?.cancel();
    _ping?.cancel();
    final d = _device;
    _cleanup();
    try {
      await d?.disconnect();
    } catch (_) {}
    _set(LinkState.off, 'Disconnected');
  }

  Future<void> forget() async {
    await stop();
    _device = null;
    try {
      (await SharedPreferences.getInstance()).remove(_prefKey);
    } catch (_) {}
  }

  void _cleanup() {
    for (final s in _subs) {
      s.cancel();
    }
    _subs.clear();
    _rx = null;
  }

  Future<void> _connectOnce() async {
    if (!_wanted ||
        state == LinkState.connecting ||
        state == LinkState.connected) {
      return;
    }
    try {
      if (!await FlutterBluePlus.isSupported) {
        _set(LinkState.off, 'Bluetooth LE not supported');
        return;
      }
      final adapter = await FlutterBluePlus.adapterState
          .where((s) => s != BluetoothAdapterState.unknown)
          .first
          .timeout(
            const Duration(seconds: 5),
            onTimeout: () => BluetoothAdapterState.unknown,
          );
      if (adapter != BluetoothAdapterState.on) {
        _set(
          LinkState.off,
          adapter == BluetoothAdapterState.unauthorized
              ? 'Allow Bluetooth for NavLink in Settings'
              : 'Turn on Bluetooth',
        );
        _scheduleRetry();
        return;
      }
      final device = _device ?? await _scan();
      if (device == null) {
        _set(LinkState.off, 'NavDisplay not found');
        _scheduleRetry();
        return;
      }
      _set(LinkState.connecting, 'Connecting…');
      await device.connect(
        license: License.nonprofit,
        timeout: const Duration(seconds: 15),
      );
      _device = device;
      await _setup(device);
      try {
        (await SharedPreferences.getInstance()).setString(
          _prefKey,
          device.remoteId.str,
        );
      } catch (_) {}
      _attempt = 0;
    } catch (e) {
      _cleanup();
      _set(LinkState.off, 'Connection failed');
      _scheduleRetry();
    }
  }

  Future<BluetoothDevice?> _scan() async {
    _set(LinkState.scanning, 'Searching for NavDisplay…');
    String? saved;
    try {
      saved = (await SharedPreferences.getInstance()).getString(_prefKey);
    } catch (_) {}
    final found = Completer<BluetoothDevice?>();
    final sub = FlutterBluePlus.onScanResults.listen((rs) {
      for (final r in rs) {
        final name = r.advertisementData.advName.isNotEmpty
            ? r.advertisementData.advName
            : r.device.platformName;
        final match =
            r.device.remoteId.str == saved ||
            name == deviceName ||
            r.advertisementData.serviceUuids.contains(Guid(serviceUuid));
        if (match && !found.isCompleted) found.complete(r.device);
      }
    });
    try {
      await FlutterBluePlus.startScan(
        withServices: [Guid(serviceUuid)],
        withNames: const [deviceName],
        timeout: const Duration(seconds: 10),
        webOptionalServices: [Guid(serviceUuid)],
      );
      return await found.future.timeout(
        const Duration(seconds: 11),
        onTimeout: () => null,
      );
    } finally {
      await sub.cancel();
      await FlutterBluePlus.stopScan();
    }
  }

  Future<void> _setup(BluetoothDevice d) async {
    _subs.add(
      d.connectionState.listen((s) {
        if (s == BluetoothConnectionState.disconnected &&
            state == LinkState.connected) {
          _cleanup();
          _ping?.cancel();
          _set(LinkState.off, 'Connection lost — reconnecting…');
          _scheduleRetry(quick: true);
        }
      }),
    );
    final svcs = await d.discoverServices();
    final svc = svcs.firstWhere(
      (s) => s.uuid == Guid(serviceUuid),
      orElse: () => throw 'Not a NavDisplay',
    );
    BluetoothCharacteristic ch(String u) =>
        svc.characteristics.firstWhere((c) => c.uuid == Guid(u));
    _rx = ch(navRxUuid);
    final status = ch(statusUuid);
    _subs.add(
      status.onValueReceived.listen((v) {
        final st = decodeStatus(v);
        if (st is StatusReady) {
          batteryPct = st.batteryPct;
          batteryMv = st.batteryMv;
          notifyListeners();
        }
        if (st != null) _status.add(st);
      }),
    );
    await status.setNotifyValue(true);
    payload = (d.mtuNow - 3).clamp(20, 240);
    _subs.add(d.mtu.listen((m) => payload = (m - 3).clamp(20, 240)));
    _set(LinkState.connected, 'Connected to NavDisplay');
    await send(encodeTimeSync(DateTime.now()));
    _ping?.cancel();
    _ping = Timer.periodic(const Duration(seconds: 2), (_) {
      if (connected &&
          DateTime.now().difference(_lastSend) >
              const Duration(milliseconds: 1900)) {
        send(encodePing());
      }
    });
  }

  void _scheduleRetry({bool quick = false}) {
    if (!_wanted) return;
    _retry?.cancel();
    _attempt++;
    final secs = quick && _attempt < 3 ? 2 : (_attempt < 5 ? 5 : 15);
    _retry = Timer(Duration(seconds: secs), _connectOnce);
  }

  /// Queues one message (in order). Silently dropped when not connected.
  Future<void> send(Uint8List msg) {
    _queue = _queue.then((_) => _write(msg)).catchError((_) {});
    return _queue;
  }

  Future<void> _write(Uint8List msg) async {
    final rx = _rx;
    if (rx == null || !connected) return;
    for (var tries = 0; ; tries++) {
      try {
        await rx.write(msg, withoutResponse: true);
        _lastSend = DateTime.now();
        return;
      } catch (e) {
        // iOS: buffer full ("canSendWriteWithoutResponse is false") → back off.
        if (tries > 40 || !connected) rethrow;
        await Future<void>.delayed(const Duration(milliseconds: 15));
      }
    }
  }

  @override
  void dispose() {
    _wanted = false;
    _retry?.cancel();
    _ping?.cancel();
    _cleanup();
    _status.close();
    super.dispose();
  }
}
