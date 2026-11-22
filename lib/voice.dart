import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Voice-note capture driven by the watch.
///
/// Protocol (service 4b0ad7a0-…):
///   ctrl (b1)  app writes 1=start, 0=stop, 2=download, 3=cancel.
///              watch notifies [state, secLo, secHi] (state: VoicePhase index
///              on the watch — 0 idle, 1 recording, 2 ready, 3 sending).
///   data (b2)  0x01 header  [u32 samples, u16 rate, u32 packets]
///              0x02 packet  [u16 seq, i16 predictor, u8 index, nibbles…]
///              0x03 end
/// Each data packet is a self-contained IMA-ADPCM block (4:1); we decode it to
/// PCM16 and, at the end marker, write a standard WAV into app documents.

typedef CmdWriter = Future<void> Function(int cmd);

enum VoicePhase { idle, recording, ready, receiving, saving }

class VoiceNote {
  VoiceNote(this.file, this.at, this.seconds);
  final File file;
  final DateTime at;
  final int seconds;
}

class VoiceController extends ChangeNotifier {
  VoiceController({required this.resolveWriter});

  /// Returns a 1-byte command writer to the ctrl characteristic, or null when
  /// the watch is not connected / lacks the voice feature.
  final CmdWriter? Function() resolveWriter;
  CmdWriter? get _w => resolveWriter();
  bool get available => _w != null;

  VoicePhase phase = VoicePhase.idle;
  int seconds = 0; // recording timer reported by the watch
  int received = 0; // data packets received so far
  int totalPackets = 0; // from the header
  final List<VoiceNote> notes = <VoiceNote>[];

  bool get busy => phase == VoicePhase.receiving || phase == VoicePhase.saving;
  double get progress =>
      totalPackets == 0 ? 0 : (received / totalPackets).clamp(0.0, 1.0);

  int _rate = 16000;
  int _totalSamples = 0;
  final List<int> _pcm = <int>[];

  // ---------------- commands ----------------
  Future<void> record() async {
    _pcm.clear();
    await _w?.call(1);
  }

  Future<void> stop() async => _w?.call(0);

  Future<void> download() async {
    if (_w == null) return;
    _pcm.clear();
    received = 0;
    totalPackets = 0;
    await _w!.call(2);
  }

  Future<void> discard() async {
    await _w?.call(3);
    phase = VoicePhase.idle;
    seconds = 0;
    notifyListeners();
  }

  // ---------------- incoming ----------------
  void onStatus(List<int> v) {
    if (v.isEmpty) return;
    seconds = v.length >= 3 ? (v[1] | (v[2] << 8)) : 0;
    switch (v[0]) {
      case 1:
        phase = VoicePhase.recording;
        break;
      case 2: // ready on the watch
        if (!busy) phase = VoicePhase.ready;
        break;
      case 0:
        if (!busy) phase = VoicePhase.idle;
        break;
    }
    notifyListeners();
  }

  Future<void> onData(List<int> v) async {
    if (v.isEmpty) return;
    switch (v[0]) {
      case 0x01:
        if (v.length >= 11) {
          final b = ByteData.sublistView(Uint8List.fromList(v));
          _totalSamples = b.getUint32(1, Endian.little);
          _rate = b.getUint16(5, Endian.little);
          totalPackets = b.getUint32(7, Endian.little);
        }
        _pcm.clear();
        received = 0;
        phase = VoicePhase.receiving;
        notifyListeners();
        break;
      case 0x02:
        _decode(v);
        received++;
        if (received % 8 == 0) notifyListeners();
        break;
      case 0x03:
        await _finish();
        break;
    }
  }

  void _decode(List<int> v) {
    if (v.length < 6) return;
    var predictor = v[3] | (v[4] << 8);
    if (predictor >= 0x8000) predictor -= 0x10000; // int16
    var index = v[5];
    _pcm.add(predictor);
    for (var i = 6; i < v.length; i++) {
      final byte = v[i];
      for (final code in [byte & 0x0F, (byte >> 4) & 0x0F]) {
        final step = _stepTab[index];
        var diff = step >> 3;
        if ((code & 4) != 0) diff += step;
        if ((code & 2) != 0) diff += step >> 1;
        if ((code & 1) != 0) diff += step >> 2;
        predictor += (code & 8) != 0 ? -diff : diff;
        if (predictor > 32767) predictor = 32767;
        if (predictor < -32768) predictor = -32768;
        index += _idxAdj[code];
        if (index < 0) index = 0;
        if (index > 88) index = 88;
        _pcm.add(predictor);
      }
    }
  }

  Future<void> _finish() async {
    phase = VoicePhase.saving;
    notifyListeners();
    final n = (_totalSamples > 0 && _totalSamples <= _pcm.length)
        ? _totalSamples
        : _pcm.length;
    final wav = _buildWav(_pcm.sublist(0, n), _rate);
    final dir = await _notesDir();
    final file = File(
      '${dir.path}/note_${DateTime.now().millisecondsSinceEpoch}.wav',
    );
    await file.writeAsBytes(wav, flush: true);
    notes.insert(
      0,
      VoiceNote(file, DateTime.now(), _rate == 0 ? 0 : (n / _rate).round()),
    );
    _pcm.clear();
    phase = VoicePhase.idle;
    seconds = 0;
    notifyListeners();
  }

  // ---------------- storage ----------------
  Future<Directory> _notesDir() async {
    final base = await getApplicationDocumentsDirectory();
    final d = Directory('${base.path}/voice_notes');
    if (!await d.exists()) await d.create(recursive: true);
    return d;
  }

  Future<void> loadNotes() async {
    final d = await _notesDir();
    final files = d
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.wav'))
        .toList()
      ..sort((a, b) => b.path.compareTo(a.path));
    notes
      ..clear()
      ..addAll(
        files.map((f) {
          final bytes = f.lengthSync();
          return VoiceNote(f, f.statSync().modified, ((bytes - 44) ~/ 32000));
        }),
      );
    notifyListeners();
  }

  Future<void> deleteNote(VoiceNote n) async {
    try {
      await n.file.delete();
    } catch (_) {}
    notes.remove(n);
    notifyListeners();
  }

  Uint8List _buildWav(List<int> pcm, int rate) {
    final dataLen = pcm.length * 2;
    final bd = ByteData(44 + dataLen);
    void str(int o, String a) {
      for (var i = 0; i < a.length; i++) {
        bd.setUint8(o + i, a.codeUnitAt(i));
      }
    }

    str(0, 'RIFF');
    bd.setUint32(4, 36 + dataLen, Endian.little);
    str(8, 'WAVE');
    str(12, 'fmt ');
    bd.setUint32(16, 16, Endian.little);
    bd.setUint16(20, 1, Endian.little); // PCM
    bd.setUint16(22, 1, Endian.little); // mono
    bd.setUint32(24, rate, Endian.little);
    bd.setUint32(28, rate * 2, Endian.little);
    bd.setUint16(32, 2, Endian.little);
    bd.setUint16(34, 16, Endian.little);
    str(36, 'data');
    bd.setUint32(40, dataLen, Endian.little);
    var o = 44;
    for (final v in pcm) {
      bd.setInt16(o, v, Endian.little);
      o += 2;
    }
    return bd.buffer.asUint8List();
  }
}

const List<int> _idxAdj = [-1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8];
const List<int> _stepTab = [
  7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
  50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230,
  253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963,
  1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327,
  3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442,
  11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794,
  32767,
];
