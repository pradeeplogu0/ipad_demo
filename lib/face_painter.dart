import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import 'face_layout.dart';

const _gold = Color(0xFFD4AF37);
const _muted = Color(0xFF7A8794);
const _ok = Color(0xFF3DD68C);
const _warn = Color(0xFFF5C542);
const _bad = Color(0xFFFF6B6B);
const _bleOn = Color(0xFF2ED3A0);

/// Live values + layout needed to draw one watch face.
class WatchFace {
  const WatchFace({
    required this.face,
    required this.elements,
    required this.h12,
    required this.time,
    required this.batPct,
    required this.batMv,
    required this.rotation,
    required this.connected,
    required this.steps,
  });
  final int face; // faceDigital / facePendant
  final List<El> elements;
  final bool h12, connected;
  final DateTime? time;
  final int? batPct, batMv;
  final int rotation, steps;

  bool get pendant => face == facePendant;
}

/// Draws the watch face exactly like the firmware: 240 x 240 coordinates,
/// every text element centred at (120 + x, 120 + y).
class WatchFacePainter extends CustomPainter {
  WatchFacePainter(this.f, {this.selected, this.showHidden = false});
  final WatchFace f;
  final int? selected; // element id to highlight (designer)
  final bool showHidden; // designer: draw hidden elements faintly

  static const _wd = ['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'];
  static const _mo = [
    'JAN',
    'FEB',
    'MAR',
    'APR',
    'MAY',
    'JUN',
    'JUL',
    'AUG',
    'SEP',
    'OCT',
    'NOV',
    'DEC',
  ];

  /// Element bounds in watch coordinates (filled while painting) for hit tests.
  final bounds = <int, Rect>{};

  Color _batColor() {
    final p = f.batPct;
    if (p == null) return _muted;
    return p > 30 ? _ok : (p > 15 ? _warn : _bad);
  }

  Color colorOf(El e) {
    if (e.color != 0) return kPalette[e.color];
    switch (e.id) {
      case elBatPct:
      case elRing:
        return _batColor();
      case elBle:
        return f.connected ? _bleOn : _muted;
      case elAmPm:
        return _gold;
      default:
        return Colors.white;
    }
  }

  (IconData?, String) textOf(int id) {
    final t = f.time;
    String two(int n) => n.toString().padLeft(2, '0');
    switch (id) {
      case elTime:
        if (t == null) return (null, '--:--');
        if (!f.h12) return (null, '${two(t.hour)}:${two(t.minute)}');
        final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
        return (null, '$h:${two(t.minute)}');
      case elSeconds:
        return (null, t == null ? '' : two(t.second));
      case elAmPm:
        return (
          null,
          t == null || !f.h12
              ? (showHidden ? 'PM' : '')
              : (t.hour < 12 ? 'AM' : 'PM'),
        );
      case elDate:
        return (
          null,
          t == null
              ? 'sync time'
              : '${_wd[t.weekday % 7]} ${t.day} ${_mo[t.month - 1]}',
        );
      case elBatPct:
        return (
          Icons.battery_full_rounded,
          f.batPct == null ? '--%' : '${f.batPct}%',
        );
      case elBatV:
        return (
          null,
          f.batMv == null
              ? '-.-- V'
              : '${(f.batMv! / 1000).toStringAsFixed(2)} V',
        );
      case elRot:
        return (Icons.sync_rounded, '${f.rotation * 90}°');
      case elBle:
        return (Icons.bluetooth_rounded, f.connected ? 'ON' : '');
      case elSteps:
        return (null, '${f.steps} steps');
    }
    return (null, '');
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 240;
    final c = size.center(Offset.zero);
    canvas.drawCircle(c, 120 * s, Paint()..color = Colors.black);
    bounds.clear();

    // Battery ring (drawn first)
    final ring = f.elements[elRing];
    if (ring.visible || showHidden) {
      final w = kRingWidths[ring.size];
      final r = (f.pendant ? 118 : 110) - w / 2;
      final rect = Rect.fromCircle(center: c, radius: r * s);
      const start = 135 * math.pi / 180, sweep = 270 * math.pi / 180;
      final alpha = ring.visible ? 1.0 : 0.25;
      final p = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = w * s
        ..strokeCap = StrokeCap.round;
      canvas.drawArc(
        rect,
        start,
        sweep,
        false,
        p
          ..color =
              (f.pendant ? const Color(0xFF10161E) : const Color(0xFF18222E))
                  .withValues(alpha: alpha),
      );
      final pct = ((f.batPct ?? 0) / 100).clamp(0.0, 1.0);
      if (pct > 0) {
        canvas.drawArc(
          rect,
          start,
          sweep * pct,
          false,
          p..color = colorOf(ring).withValues(alpha: alpha),
        );
      }
      if (selected == elRing) {
        canvas.drawCircle(
          c,
          r * s,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFF3D8BFD),
        );
      }
    }

    // Pendant ticks
    if (f.pendant) {
      for (var i = 0; i < 12; i++) {
        final major = i % 3 == 0;
        final a = i * 30 * math.pi / 180;
        final dir = Offset(math.sin(a), -math.cos(a));
        canvas.drawLine(
          c + dir * ((major ? 92 : 102) * s),
          c + dir * (110 * s),
          Paint()
            ..color = major ? _gold : const Color(0xFF3A4656)
            ..strokeWidth = (major ? 4 : 2) * s
            ..strokeCap = StrokeCap.round,
        );
      }
    }

    // Text elements
    for (final e in f.elements) {
      if (e.id == elRing) continue;
      if (!e.visible && !showHidden) continue;
      final (icon, text) = textOf(e.id);
      if (text.isEmpty && icon == null) continue;
      final fs = kFontSizes[e.size] * s;
      final col = colorOf(e).withValues(alpha: e.visible ? 1 : 0.28);
      final style = TextStyle(
        color: col,
        fontSize: fs,
        fontWeight: e.size == 3 ? FontWeight.w700 : FontWeight.w500,
        fontFeatures: const [FontFeature.tabularFigures()],
      );
      final tp = TextPainter(
        text: TextSpan(
          children: [
            if (icon != null)
              TextSpan(
                text: String.fromCharCode(icon.codePoint),
                style: style.copyWith(
                  fontFamily: icon.fontFamily,
                  package: icon.fontPackage,
                ),
              ),
            if (icon != null && text.isNotEmpty) const TextSpan(text: ' '),
            TextSpan(text: text, style: style),
          ],
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final center = c + Offset(e.x * s, e.y * s);
      final box = Rect.fromCenter(
        center: center,
        width: tp.width,
        height: tp.height,
      );
      tp.paint(canvas, box.topLeft);
      bounds[e.id] = Rect.fromCenter(
        center: Offset(e.x.toDouble(), e.y.toDouble()),
        width: tp.width / s,
        height: tp.height / s,
      );
      if (selected == e.id) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(box.inflate(4), const Radius.circular(6)),
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5
            ..color = const Color(0xFF3D8BFD),
        );
      }
    }

    // Pendant hands on top
    if (f.pendant) {
      final t = f.time;
      if (t != null) {
        void hand(double deg, double len, double tail, double w, Color col) {
          final a = deg * math.pi / 180;
          final dir = Offset(math.sin(a), -math.cos(a));
          canvas.drawLine(
            c - dir * tail * s,
            c + dir * len * s,
            Paint()
              ..color = col
              ..strokeWidth = w * s
              ..strokeCap = StrokeCap.round,
          );
        }

        final sec = t.second.toDouble(), min = t.minute + sec / 60;
        hand(
          ((t.hour % 12) + min / 60) * 30,
          54,
          10,
          7,
          const Color(0xFFE8EEF6),
        );
        hand(min * 6, 82, 12, 5, const Color(0xFFE8EEF6));
        hand(sec * 6, 94, 18, 2, _gold);
      }
      canvas.drawCircle(c, 6 * s, Paint()..color = _gold);
    }
  }

  @override
  bool shouldRepaint(WatchFacePainter old) => true;
}

/// Round bezel + live face, rotated like the real screen.
class WatchPreview extends StatelessWidget {
  const WatchPreview({
    super.key,
    required this.face,
    this.size = 220,
    this.onTap,
  });
  final WatchFace face;
  final double size;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final bezel = Container(
      width: size,
      height: size,
      padding: EdgeInsets.all(size * 0.035),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: face.pendant
              ? const [Color(0xFFE9CF7A), Color(0xFF8A6A1E)]
              : const [Color(0xFF3A4656), Color(0xFF141B24)],
        ),
        boxShadow: [
          BoxShadow(
            color: (face.pendant ? _gold : const Color(0xFF3D8BFD)).withValues(
              alpha: 0.18,
            ),
            blurRadius: 40,
            spreadRadius: 2,
          ),
        ],
      ),
      child: AnimatedRotation(
        turns: face.rotation / 4,
        duration: const Duration(milliseconds: 450),
        curve: Curves.easeInOutCubic,
        child: CustomPaint(painter: WatchFacePainter(face)),
      ),
    );
    return onTap == null ? bezel : GestureDetector(onTap: onTap, child: bezel);
  }
}
