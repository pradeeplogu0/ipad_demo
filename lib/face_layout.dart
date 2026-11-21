import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Watch-face layout model — mirrors `El` / `DEFAULT_LAYOUT` in the firmware
/// (firmware/RoundWatchESP32/RoundWatchESP32.ino). Coordinates are offsets in
/// watch pixels from the centre of the 240 x 240 round screen.
class El {
  El(this.face, this.id, this.visible, this.x, this.y, this.size, this.color);

  final int face, id;
  bool visible;
  int x, y, size, color;

  El copy() => El(face, id, visible, x, y, size, color);

  List<int> encode() => [
    face,
    id,
    visible ? 1 : 0,
    x & 0xFF,
    y & 0xFF,
    size,
    color,
  ];

  void setFrom(El o) {
    visible = o.visible;
    x = o.x;
    y = o.y;
    size = o.size;
    color = o.color;
  }
}

class ElInfo {
  const ElInfo(this.name, this.icon, {this.ring = false});
  final String name;
  final IconData icon;
  final bool ring;
}

const elTime = 0,
    elSeconds = 1,
    elAmPm = 2,
    elDate = 3,
    elBatPct = 4,
    elBatV = 5,
    elRot = 6,
    elBle = 7,
    elSteps = 8,
    elRing = 9;
const elCount = 10;
const faceDigital = 0, facePendant = 1;

const kElInfo = <ElInfo>[
  ElInfo('Time', Icons.schedule_rounded),
  ElInfo('Seconds', Icons.timer_outlined),
  ElInfo('AM / PM', Icons.wb_twilight_rounded),
  ElInfo('Date', Icons.calendar_today_rounded),
  ElInfo('Battery %', Icons.battery_full_rounded),
  ElInfo('Battery V', Icons.bolt_rounded),
  ElInfo('Rotation', Icons.screen_rotation_alt_rounded),
  ElInfo('Bluetooth', Icons.bluetooth_rounded),
  ElInfo('Steps', Icons.directions_walk_rounded),
  ElInfo('Battery ring', Icons.radio_button_unchecked_rounded, ring: true),
];

const kFontSizes = [14.0, 16.0, 20.0, 48.0];
const kRingWidths = [4.0, 8.0, 14.0, 20.0];
const kSizeNames = ['S', 'M', 'L', 'XL'];
const kRingSizeNames = ['Thin', 'Normal', 'Thick', 'Bold'];

/// Index 0 = "auto" (battery level / Bluetooth state / white).
const kPalette = <Color>[
  Color(0x00000000),
  Color(0xFFFFFFFF),
  Color(0xFFC0D0E0),
  Color(0xFF7A8794),
  Color(0xFFD4AF37),
  Color(0xFF3DD68C),
  Color(0xFF4DABF7),
  Color(0xFFFF8C5A),
  Color(0xFFF5C542),
  Color(0xFFFF6B6B),
  Color(0xFFB197FC),
  Color(0xFF22D3EE),
];

const _defaults = <List<List<int>>>[
  [
    // Digital: visible, x, y, size, color
    [1, 0, -4, 3, 1],
    [1, 0, 32, 1, 3],
    [1, 0, -44, 0, 4],
    [1, 0, -76, 1, 2],
    [1, -36, 56, 0, 0],
    [1, 36, 56, 0, 7],
    [1, 0, 76, 0, 8],
    [1, 0, 96, 0, 0],
    [0, 0, -60, 0, 6],
    [1, 0, 0, 2, 0],
  ],
  [
    // Pendant
    [0, 0, -66, 1, 1],
    [0, 0, 66, 0, 3],
    [1, 0, 64, 0, 4],
    [1, 0, 46, 0, 4],
    [1, 0, -46, 0, 0],
    [0, 0, -28, 0, 7],
    [0, 0, 28, 0, 8],
    [1, 0, 84, 0, 0],
    [0, 0, -28, 0, 6],
    [1, 0, 0, 0, 0],
  ],
];

class FaceLayout {
  FaceLayout() : faces = [_build(0), _build(1)];

  /// faces[face][elementId]
  final List<List<El>> faces;

  static List<El> _build(int f) => [
    for (var i = 0; i < elCount; i++)
      El(
        f,
        i,
        _defaults[f][i][0] == 1,
        _defaults[f][i][1],
        _defaults[f][i][2],
        _defaults[f][i][3],
        _defaults[f][i][4],
      ),
  ];

  void resetDefaults() {
    for (var f = 0; f < 2; f++) {
      final d = _build(f);
      for (var i = 0; i < elCount; i++) {
        faces[f][i].setFrom(d[i]);
      }
    }
  }

  /// Applies the watch's full layout value (7 bytes per element).
  /// [skip] (face, id) is left alone — e.g. the element being dragged.
  void apply(List<int> b, {(int, int)? skip}) {
    for (var i = 0; i + 6 < b.length; i += 7) {
      final f = b[i], id = b[i + 1];
      if (f > 1 || id >= elCount) continue;
      if (skip != null && skip.$1 == f && skip.$2 == id) continue;
      int s8(int v) => v > 127 ? v - 256 : v;
      final e = faces[f][id];
      e.visible = b[i + 2] != 0;
      e.x = s8(b[i + 3]);
      e.y = s8(b[i + 4]);
      e.size = b[i + 5].clamp(0, 3);
      e.color = b[i + 6].clamp(0, kPalette.length - 1);
    }
  }
}

/// Clamp a position so the element stays on the round screen.
(int, int) clampToDial(double x, double y, {double r = 110}) {
  final d = math.sqrt(x * x + y * y);
  if (d > r) {
    x = x / d * r;
    y = y / d * r;
  }
  return (x.round(), y.round());
}
