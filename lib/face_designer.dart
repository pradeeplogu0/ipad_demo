import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'face_layout.dart';
import 'face_painter.dart';

const _panel = Color(0xF0121820);
const _inset = Color(0xFF0C1219);
const _line = Color(0xFF2A3544);
const _text = Color(0xFFE8EEF6);
const _muted = Color(0xFF8B98A8);
const _accent = Color(0xFF3D8BFD);
const _btn = Color(0xFF1B2734);

/// Apple-Watch-style face editor. Edits the shared [layout] in place and
/// sends every change to the watch through [onEdit].
class FaceDesignerPage extends StatefulWidget {
  const FaceDesignerPage({
    super.key,
    required this.layout,
    required this.initialFace,
    required this.faceFor,
    required this.onEdit,
    required this.onReset,
    required this.onShowFace,
    required this.onDragging,
  });

  final FaceLayout layout;
  final int initialFace;

  /// Live values (time, battery…) for drawing the given face.
  final WatchFace Function(int face) faceFor;
  final Future<void> Function(El e) onEdit;
  final Future<void> Function() onReset;
  final Future<void> Function(int face) onShowFace;

  /// Element being dragged (so watch echoes don't snap it back), or null.
  final void Function((int, int)? el) onDragging;

  @override
  State<FaceDesignerPage> createState() => _FaceDesignerPageState();
}

class _FaceDesignerPageState extends State<FaceDesignerPage> {
  late int _face = widget.initialFace;
  int _sel = elDate;
  Timer? _tick;
  WatchFacePainter? _lastPainter;
  bool _dragging = false;

  List<El> get _els => widget.layout.faces[_face];
  El get _e => _els[_sel];
  ElInfo get _info => kElInfo[_sel];

  @override
  void initState() {
    super.initState();
    _tick = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && !_dragging) setState(() {});
    });
    widget.onShowFace(_face);
  }

  @override
  void dispose() {
    _tick?.cancel();
    widget.onDragging(null);
    super.dispose();
  }

  void _send() {
    HapticFeedback.selectionClick();
    widget.onEdit(_e);
    setState(() {});
  }

  void _setFace(int f) {
    setState(() => _face = f);
    widget.onShowFace(f);
  }

  // ---------------- gestures on the preview ----------------
  int? _hit(Offset local, double size) {
    final s = size / 240;
    final p = Offset(local.dx / s - 120, local.dy / s - 120);
    int? best;
    var bestD = double.infinity;
    _lastPainter?.bounds.forEach((id, r) {
      final d = r.inflate(10).contains(p) ? 0.0 : (r.center - p).distance;
      if (d < bestD && d < 30) {
        bestD = d;
        best = id;
      }
    });
    if (best == null) {
      final dist = p.distance;
      if (dist > 96 && dist < 122) best = elRing;
    }
    return best;
  }

  void _panStart(DragStartDetails d, double size) {
    final hit = _hit(d.localPosition, size);
    if (hit != null && hit != elRing) {
      setState(() => _sel = hit);
    }
    if (_info.ring) return;
    _dragging = true;
    widget.onDragging((_face, _sel));
  }

  void _panUpdate(DragUpdateDetails d, double size) {
    if (!_dragging || _info.ring) return;
    final s = size / 240;
    final (x, y) = clampToDial(_e.x + d.delta.dx / s, _e.y + d.delta.dy / s);
    setState(() {
      _e.x = x;
      _e.y = y;
    });
  }

  void _panEnd() {
    if (!_dragging) return;
    _dragging = false;
    widget.onDragging(null);
    _send();
  }

  // ---------------- UI ----------------
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0B0F14),
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B0F14),
        foregroundColor: _text,
        title: const Text(
          'Face designer',
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton.icon(
            onPressed: _confirmReset,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: const Text('Reset'),
            style: TextButton.styleFrom(foregroundColor: _muted),
          ),
        ],
      ),
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, box) {
            final wide = box.maxWidth >= 820;
            final previewSize = math
                .min(wide ? 420.0 : box.maxWidth - 48, 420.0)
                .toDouble();
            final preview = _preview(previewSize);
            final controls = _controls();
            return SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1000),
                  child: wide
                      ? Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Expanded(child: preview),
                            const SizedBox(width: 20),
                            Expanded(child: controls),
                          ],
                        )
                      : Column(
                          children: [
                            preview,
                            const SizedBox(height: 16),
                            controls,
                          ],
                        ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _preview(double size) {
    final face = widget.faceFor(_face);
    final painter = WatchFacePainter(face, selected: _sel, showHidden: true);
    _lastPainter = painter;
    return Column(
      children: [
        SegmentedButton<int>(
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(
              value: faceDigital,
              icon: Icon(Icons.watch_rounded),
              label: Text('Digital'),
            ),
            ButtonSegment(
              value: facePendant,
              icon: Icon(Icons.diamond_outlined),
              label: Text('Pendant'),
            ),
          ],
          selected: {_face},
          onSelectionChanged: (s) => _setFace(s.first),
        ),
        const SizedBox(height: 16),
        Container(
          width: size + 16,
          height: size + 16,
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: _face == facePendant
                  ? const [Color(0xFFE9CF7A), Color(0xFF8A6A1E)]
                  : const [Color(0xFF3A4656), Color(0xFF141B24)],
            ),
          ),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) {
              final hit = _hit(d.localPosition, size);
              if (hit != null) {
                HapticFeedback.selectionClick();
                setState(() => _sel = hit);
              }
            },
            onPanStart: (d) => _panStart(d, size),
            onPanUpdate: (d) => _panUpdate(d, size),
            onPanEnd: (_) => _panEnd(),
            onPanCancel: _panEnd,
            child: SizedBox(
              key: const ValueKey('face-preview'),
              width: size,
              height: size,
              child: CustomPaint(painter: painter),
            ),
          ),
        ),
        const SizedBox(height: 10),
        const Text(
          'Tap an element to select it, then drag it into place.\n'
          'Faded items are hidden. Changes appear on the watch instantly.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _card(List<Widget> children) => Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(14),
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

  Widget _caption(String t) => Padding(
    padding: const EdgeInsets.only(bottom: 8, top: 4),
    child: Text(
      t.toUpperCase(),
      style: const TextStyle(
        color: _muted,
        fontSize: 11,
        letterSpacing: 1.4,
        fontWeight: FontWeight.w700,
      ),
    ),
  );

  Widget _controls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _card([
          _caption('Elements'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (var i = 0; i < elCount; i++)
                FilterChip(
                  avatar: Icon(
                    kElInfo[i].icon,
                    size: 16,
                    color: _els[i].visible
                        ? (_sel == i ? Colors.white : _text)
                        : _muted,
                  ),
                  label: Text(kElInfo[i].name),
                  selected: _sel == i,
                  showCheckmark: false,
                  selectedColor: _accent,
                  backgroundColor: _btn,
                  side: BorderSide(color: _sel == i ? _accent : _line),
                  labelStyle: TextStyle(
                    color: _sel == i
                        ? Colors.white
                        : (_els[i].visible ? _text : _muted),
                    decoration: _els[i].visible
                        ? null
                        : TextDecoration.lineThrough,
                    fontWeight: FontWeight.w600,
                  ),
                  onSelected: (_) => setState(() => _sel = i),
                ),
            ],
          ),
        ]),
        _card([
          Row(
            children: [
              Icon(_info.icon, color: _accent, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  _info.name,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Text('Show', style: TextStyle(color: _muted)),
              Switch(
                value: _e.visible,
                activeThumbColor: _accent,
                onChanged: (v) {
                  _e.visible = v;
                  _send();
                },
              ),
            ],
          ),
          _caption(_info.ring ? 'Thickness' : 'Size'),
          SegmentedButton<int>(
            showSelectedIcon: false,
            segments: [
              for (var i = 0; i < 4; i++)
                ButtonSegment(
                  value: i,
                  label: Text(_info.ring ? kRingSizeNames[i] : kSizeNames[i]),
                ),
            ],
            selected: {_e.size},
            onSelectionChanged: (s) {
              _e.size = s.first;
              _send();
            },
          ),
          const SizedBox(height: 8),
          _caption('Colour'),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [for (var i = 0; i < kPalette.length; i++) _swatch(i)],
          ),
          if (!_info.ring) ...[
            const SizedBox(height: 8),
            _caption('Position  ·  x ${_e.x}, y ${_e.y}'),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              runSpacing: 4,
              children: [
                _nudge(Icons.keyboard_arrow_left_rounded, -2, 0),
                _nudge(Icons.keyboard_arrow_up_rounded, 0, -2),
                _nudge(Icons.keyboard_arrow_down_rounded, 0, 2),
                _nudge(Icons.keyboard_arrow_right_rounded, 2, 0),
                TextButton.icon(
                  onPressed: () {
                    _e.x = 0;
                    _send();
                  },
                  icon: const Icon(
                    Icons.align_horizontal_center_rounded,
                    size: 18,
                  ),
                  label: const Text('Centre'),
                ),
              ],
            ),
          ],
          if (_sel == elAmPm)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'AM/PM only shows on the watch in 12-hour mode.',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ),
          if (_sel == elSteps)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text(
                'Steps count only with a motion sensor fitted.',
                style: TextStyle(color: _muted, fontSize: 12),
              ),
            ),
        ]),
      ],
    );
  }

  Widget _swatch(int i) {
    final selected = _e.color == i;
    final auto = i == 0;
    return GestureDetector(
      onTap: () {
        _e.color = i;
        _send();
      },
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: auto ? _inset : kPalette[i],
          gradient: auto
              ? const SweepGradient(
                  colors: [
                    Color(0xFF3DD68C),
                    Color(0xFFF5C542),
                    Color(0xFFFF6B6B),
                    Color(0xFF3DD68C),
                  ],
                )
              : null,
          border: Border.all(
            color: selected ? Colors.white : _line,
            width: selected ? 3 : 1,
          ),
        ),
        child: auto
            ? const Center(
                child: Text(
                  'A',
                  style: TextStyle(
                    color: Colors.black,
                    fontWeight: FontWeight.w900,
                    fontSize: 13,
                  ),
                ),
              )
            : null,
      ),
    );
  }

  Widget _nudge(IconData icon, int dx, int dy) => Padding(
    padding: const EdgeInsets.only(right: 6),
    child: IconButton.filledTonal(
      onPressed: () {
        final (x, y) = clampToDial(
          (_e.x + dx).toDouble(),
          (_e.y + dy).toDouble(),
        );
        _e.x = x;
        _e.y = y;
        _send();
      },
      icon: Icon(icon),
      style: IconButton.styleFrom(
        backgroundColor: _btn,
        foregroundColor: _text,
      ),
    ),
  );

  Future<void> _confirmReset() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: _panel,
        title: const Text('Reset both faces?', style: TextStyle(color: _text)),
        content: const Text(
          'Digital and Pendant go back to the default layout.',
          style: TextStyle(color: _muted),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    widget.layout.resetDefaults();
    await widget.onReset();
    if (mounted) setState(() {});
  }
}
