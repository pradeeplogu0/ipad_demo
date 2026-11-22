import 'dart:async';

import 'package:flutter/foundation.dart';

/// Stopwatch + countdown timer, mirrored with the watch.
///
/// Protocol (service 4b0ad7a0-…):
///   cmd (b1, write):  [op] or [op, u32 ms little-endian]
///     0x01 sw-start 0x02 sw-stop 0x03 sw-reset
///     0x10 ct-start 0x11 ct-stop 0x12 ct-reset 0x13+u32 ct-set 0x14 ct-ack
///   state (b2, notify) 15 bytes:
///     [0] sw_run [1..4] sw_elapsed_ms [5] ct_run [6..9] ct_remaining_ms
///     [10..13] ct_duration_ms [14] flags(bit0 alarming)
///
/// The watch owns the clock; we extrapolate locally between notifications for a
/// smooth read-out and re-sync on every packet. Commands update optimistically.

typedef BytesWriter = Future<void> Function(List<int> bytes);

class TimerController extends ChangeNotifier {
  TimerController({required this.resolveWriter});
  final BytesWriter? Function() resolveWriter;
  BytesWriter? get _w => resolveWriter();
  bool get available => _w != null;

  bool swRunning = false;
  bool ctRunning = false;
  bool alarming = false;
  int ctDurationMs = 60000;

  int _swBase = 0; // elapsed ms at last sync
  int _ctBase = 60000; // remaining ms at last sync
  DateTime _syncAt = DateTime.now();
  Timer? _ticker;

  int get swElapsedMs =>
      swRunning ? _swBase + _since() : _swBase;
  int get ctRemainingMs {
    if (!ctRunning) return _ctBase;
    final r = _ctBase - _since();
    return r < 0 ? 0 : r;
  }

  int _since() => DateTime.now().difference(_syncAt).inMilliseconds;

  void _tickIfNeeded() {
    if (_ticker != null) return;
    _ticker = Timer.periodic(const Duration(milliseconds: 60), (_) {
      if (swRunning || ctRunning || alarming) {
        notifyListeners();
      } else {
        _ticker?.cancel();
        _ticker = null;
      }
    });
  }

  // ---------------- incoming state from the watch ----------------
  void onState(List<int> v) {
    if (v.length < 15) return;
    final b = ByteData.sublistView(Uint8List.fromList(v));
    swRunning = v[0] != 0;
    _swBase = b.getUint32(1, Endian.little);
    ctRunning = v[5] != 0;
    _ctBase = b.getUint32(6, Endian.little);
    ctDurationMs = b.getUint32(10, Endian.little);
    alarming = (v[14] & 1) != 0;
    _syncAt = DateTime.now();
    _tickIfNeeded();
    notifyListeners();
  }

  // ---------------- commands (optimistic + send) ----------------
  Future<void> _send(List<int> b) async => _w?.call(b);

  Future<void> swStartStop() async {
    if (swRunning) {
      _swBase = swElapsedMs;
      swRunning = false;
    } else {
      _swBase = swElapsedMs;
      swRunning = true;
      _syncAt = DateTime.now();
      _tickIfNeeded();
    }
    notifyListeners();
    await _send([swRunning ? 0x01 : 0x02]);
  }

  Future<void> swReset() async {
    swRunning = false;
    _swBase = 0;
    notifyListeners();
    await _send([0x03]);
  }

  Future<void> ctStartStop() async {
    if (alarming) return ctAck();
    if (ctRunning) {
      _ctBase = ctRemainingMs;
      ctRunning = false;
    } else {
      if (ctRemainingMs == 0) _ctBase = ctDurationMs;
      _ctBase = ctRemainingMs;
      ctRunning = true;
      _syncAt = DateTime.now();
      _tickIfNeeded();
    }
    notifyListeners();
    await _send([ctRunning ? 0x10 : 0x11]);
  }

  Future<void> ctReset() async {
    ctRunning = false;
    alarming = false;
    _ctBase = ctDurationMs;
    notifyListeners();
    await _send([0x12]);
  }

  Future<void> ctSet(int ms) async {
    ctDurationMs = ms;
    ctRunning = false;
    alarming = false;
    _ctBase = ms;
    notifyListeners();
    await _send([
      0x13,
      ms & 0xFF,
      (ms >> 8) & 0xFF,
      (ms >> 16) & 0xFF,
      (ms >> 24) & 0xFF,
    ]);
  }

  Future<void> ctAck() async {
    alarming = false;
    ctRunning = false;
    _ctBase = ctDurationMs;
    notifyListeners();
    await _send([0x14]);
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  // ---------------- formatting ----------------
  static String fmtStopwatch(int ms) {
    final cs = (ms ~/ 10) % 100, s = (ms ~/ 1000) % 60, m = (ms ~/ 60000) % 60;
    final h = ms ~/ 3600000;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}.${two(cs)}';
  }

  static String fmtTimer(int ms) {
    final total = (ms + 999) ~/ 1000;
    final s = total % 60, m = (total ~/ 60) % 60, h = total ~/ 3600;
    String two(int n) => n.toString().padLeft(2, '0');
    if (h > 0) return '$h:${two(m)}:${two(s)}';
    return '${two(m)}:${two(s)}';
  }
}
