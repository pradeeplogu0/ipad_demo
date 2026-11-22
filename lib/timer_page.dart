import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'timers.dart';

const _bg = Color(0xFF0B0F14);
const _panel = Color(0xF0121820);
const _line = Color(0xFF2A3544);
const _text = Color(0xFFE8EEF6);
const _muted = Color(0xFF8B98A8);
const _accent = Color(0xFF3D8BFD);
const _bad = Color(0xFFFF6B6B);
const _btnBg = Color(0xFF1B2734);

/// Stopwatch + countdown timer, mirrored live with the watch.
class TimerPage extends StatefulWidget {
  const TimerPage({super.key, required this.timers, required this.canUse});
  final TimerController timers;
  final bool Function() canUse;

  @override
  State<TimerPage> createState() => _TimerPageState();
}

class _TimerPageState extends State<TimerPage> {
  int _mode = 0; // 0 stopwatch, 1 timer

  @override
  Widget build(BuildContext context) {
    final t = widget.timers;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        elevation: 0,
        title: const Text('Stopwatch & Timer'),
      ),
      body: ListenableBuilder(
        listenable: t,
        builder: (context, _) {
          final connected = widget.canUse();
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: [
                _tabs(),
                const SizedBox(height: 20),
                _display(t),
                const SizedBox(height: 24),
                if (!connected)
                  const Text(
                    'Connect to your watch to control it.',
                    style: TextStyle(color: _muted),
                  )
                else if (_mode == 0)
                  _stopwatchControls(t)
                else
                  _timerControls(t),
                const Spacer(),
                Text(
                  connected
                      ? 'Synced with the watch — long-press the watch face to open it there too.'
                      : 'Not connected.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _tabs() => Row(
    children: [
      Expanded(child: _tab('Stopwatch', 0)),
      const SizedBox(width: 10),
      Expanded(child: _tab('Timer', 1)),
    ],
  );

  Widget _tab(String label, int m) {
    final on = _mode == m;
    return GestureDetector(
      onTap: () => setState(() => _mode = m),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: on ? _accent : _btnBg,
          borderRadius: BorderRadius.circular(12),
        ),
        alignment: Alignment.center,
        child: Text(
          label,
          style: TextStyle(
            color: on ? Colors.white : _text,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _display(TimerController t) {
    final alarm = _mode == 1 && t.alarming;
    final txt = _mode == 0
        ? TimerController.fmtStopwatch(t.swElapsedMs)
        : TimerController.fmtTimer(t.ctRemainingMs);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: alarm ? _bad : _line),
      ),
      alignment: Alignment.center,
      child: Text(
        alarm ? 'TIME!' : txt,
        style: TextStyle(
          color: alarm ? _bad : _text,
          fontSize: 54,
          fontWeight: FontWeight.w800,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  Widget _stopwatchControls(TimerController t) => Row(
    children: [
      Expanded(
        child: _btn(
          t.swRunning ? 'Stop' : 'Start',
          color: t.swRunning ? _bad : _accent,
          onTap: () {
            HapticFeedback.mediumImpact();
            t.swStartStop();
          },
        ),
      ),
      const SizedBox(width: 12),
      Expanded(
        child: _btn(
          'Reset',
          color: _btnBg,
          onTap: () {
            HapticFeedback.selectionClick();
            t.swReset();
          },
        ),
      ),
    ],
  );

  Widget _timerControls(TimerController t) => Column(
    children: [
      Row(
        children: [
          for (final m in const [1, 5, 10]) ...[
            if (m != 1) const SizedBox(width: 8),
            Expanded(
              child: _btn(
                '${m}m',
                color: t.ctDurationMs == m * 60000 ? _accent : _btnBg,
                small: true,
                onTap: t.ctRunning
                    ? null
                    : () {
                        HapticFeedback.selectionClick();
                        t.ctSet(m * 60000);
                      },
              ),
            ),
          ],
        ],
      ),
      const SizedBox(height: 12),
      Row(
        children: [
          Expanded(
            child: _btn(
              t.alarming ? 'Stop' : (t.ctRunning ? 'Pause' : 'Start'),
              color: (t.ctRunning || t.alarming) ? _bad : _accent,
              onTap: () {
                HapticFeedback.mediumImpact();
                t.ctStartStop();
              },
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _btn(
              'Reset',
              color: _btnBg,
              onTap: () {
                HapticFeedback.selectionClick();
                t.ctReset();
              },
            ),
          ),
        ],
      ),
    ],
  );

  Widget _btn(
    String label, {
    required Color color,
    VoidCallback? onTap,
    bool small = false,
  }) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: EdgeInsets.symmetric(vertical: small ? 12 : 16),
            alignment: Alignment.center,
            child: Text(
              label,
              style: TextStyle(
                color: _text,
                fontSize: small ? 15 : 18,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
