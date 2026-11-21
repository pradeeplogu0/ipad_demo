import 'package:material_ui/material_ui.dart';

import 'protocol.dart';

/// Turn arrows — same shapes as the display firmware (nav_ui.cpp), 100 x 100 box.
class TurnIcon extends StatelessWidget {
  const TurnIcon(
    this.turn, {
    super.key,
    this.size = 64,
    this.color = Colors.white,
    this.exit = 0,
  });
  final Turn turn;
  final double size;
  final Color color;
  final int exit;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: size,
    height: size,
    child: CustomPaint(painter: _TurnPainter(turn, color, exit)),
  );
}

class _TurnPainter extends CustomPainter {
  _TurnPainter(this.turn, this.color, this.exit);
  final Turn turn;
  final Color color;
  final int exit;

  static const _o = Offset.new;
  static final _shapes = <Turn, (List<Offset>, List<Offset>, int)>{
    Turn.straight: (
      [_o(50, 95), _o(50, 12)],
      [_o(24, 38), _o(50, 12), _o(76, 38)],
      0,
    ),
    Turn.slightLeft: (
      [_o(64, 95), _o(64, 60), _o(26, 22)],
      [_o(50, 20), _o(24, 20), _o(24, 46)],
      0,
    ),
    Turn.left: (
      [_o(70, 95), _o(70, 50), _o(18, 50)],
      [_o(38, 30), _o(16, 50), _o(38, 70)],
      0,
    ),
    Turn.sharpLeft: (
      [_o(70, 95), _o(70, 30), _o(30, 72)],
      [_o(30, 48), _o(28, 74), _o(54, 74)],
      0,
    ),
    Turn.slightRight: (
      [_o(36, 95), _o(36, 60), _o(74, 22)],
      [_o(50, 20), _o(76, 20), _o(76, 46)],
      0,
    ),
    Turn.right: (
      [_o(30, 95), _o(30, 50), _o(82, 50)],
      [_o(62, 30), _o(84, 50), _o(62, 70)],
      0,
    ),
    Turn.sharpRight: (
      [_o(30, 95), _o(30, 30), _o(70, 72)],
      [_o(70, 48), _o(72, 74), _o(46, 74)],
      0,
    ),
    Turn.uturn: (
      [_o(70, 95), _o(70, 36), _o(62, 20), _o(38, 20), _o(30, 36), _o(30, 70)],
      [_o(14, 54), _o(30, 72), _o(46, 54)],
      0,
    ),
    Turn.roundabout: (
      [_o(50, 96), _o(50, 76)],
      [_o(63, 37), _o(84, 16), _o(64, 16), _o(84, 16), _o(84, 36)],
      2,
    ),
    Turn.arrive: (<Offset>[], <Offset>[], 1),
    Turn.depart: (
      [_o(50, 95), _o(50, 12)],
      [_o(24, 38), _o(50, 12), _o(76, 38)],
      0,
    ),
  };

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 100;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 11 * k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final (shaft, head, ring) = _shapes[turn]!;
    void poly(List<Offset> p) {
      if (p.length < 2) return;
      final path = Path()..moveTo(p[0].dx * k, p[0].dy * k);
      for (final q in p.skip(1)) {
        path.lineTo(q.dx * k, q.dy * k);
      }
      canvas.drawPath(path, paint);
    }

    poly(shaft);
    poly(head);
    if (ring == 1) {
      canvas.drawCircle(
        Offset(50 * k, 50 * k),
        26 * k,
        paint
          ..color = const Color(0xFF3DD68C)
          ..strokeWidth = 12 * k,
      );
    } else if (ring == 2) {
      canvas.drawCircle(
        Offset(50 * k, 56 * k),
        15.5 * k,
        paint..strokeWidth = 9 * k,
      );
      if (exit > 0) {
        final tp = TextPainter(
          text: TextSpan(
            text: '$exit',
            style: TextStyle(
              color: color,
              fontSize: 16 * k,
              fontWeight: FontWeight.w800,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(50 * k - tp.width / 2, 56 * k - tp.height / 2));
      }
    }
  }

  @override
  bool shouldRepaint(_TurnPainter o) =>
      o.turn != turn || o.color != color || o.exit != exit;
}
