import 'package:flutter/services.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

import 'voice.dart';

const _bg = Color(0xFF0B0F14);
const _panel = Color(0xF0121820);
const _line = Color(0xFF2A3544);
const _text = Color(0xFFE8EEF6);
const _muted = Color(0xFF8B98A8);
const _accent = Color(0xFF3D8BFD);
const _bad = Color(0xFFFF6B6B);

/// Record voice notes on the watch, pull them over BLE and play them back.
class VoicePage extends StatefulWidget {
  const VoicePage({super.key, required this.voice, required this.canUse});
  final VoiceController voice;
  final bool Function() canUse;

  @override
  State<VoicePage> createState() => _VoicePageState();
}

class _VoicePageState extends State<VoicePage> {
  final _player = AudioPlayer();
  String? _playingPath;

  @override
  void initState() {
    super.initState();
    widget.voice.loadNotes();
    _player.playerStateStream.listen((s) {
      if (s.processingState == ProcessingState.completed) {
        _player.stop();
        if (mounted) setState(() => _playingPath = null);
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _togglePlay(VoiceNote n) async {
    HapticFeedback.selectionClick();
    if (_playingPath == n.file.path) {
      await _player.stop();
      setState(() => _playingPath = null);
      return;
    }
    try {
      await _player.setFilePath(n.file.path);
      setState(() => _playingPath = n.file.path);
      await _player.play();
    } catch (_) {
      if (mounted) setState(() => _playingPath = null);
    }
  }

  String _fmtClock(int s) =>
      '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final v = widget.voice;
    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        foregroundColor: _text,
        elevation: 0,
        title: const Text('Voice notes'),
      ),
      body: ListenableBuilder(
        listenable: v,
        builder: (context, _) {
          final connected = widget.canUse();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _recorderCard(v, connected),
              const SizedBox(height: 14),
              if (v.notes.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Text(
                    'No voice notes yet. Record one on the watch and download it here.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: _muted),
                  ),
                )
              else
                ...v.notes.map((n) => _noteTile(v, n)),
            ],
          );
        },
      ),
    );
  }

  Widget _card(List<Widget> children) => Container(
    padding: const EdgeInsets.all(16),
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

  Widget _recorderCard(VoiceController v, bool connected) {
    final recording = v.phase == VoicePhase.recording;
    final receiving = v.phase == VoicePhase.receiving;
    final ready = v.phase == VoicePhase.ready;

    return _card([
      Center(
        child: Text(
          recording
              ? _fmtClock(v.seconds)
              : receiving
              ? 'Downloading ${(v.progress * 100).round()}%'
              : ready
              ? 'Clip ready (${v.seconds}s)'
              : 'Ready to record',
          style: TextStyle(
            color: recording ? _accent : _text,
            fontSize: 28,
            fontWeight: FontWeight.w800,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ),
      const SizedBox(height: 14),
      if (receiving)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: LinearProgressIndicator(
            value: v.progress == 0 ? null : v.progress,
            backgroundColor: _line,
            color: _accent,
          ),
        ),
      if (!connected)
        const Text(
          'Connect to your watch to record.',
          textAlign: TextAlign.center,
          style: TextStyle(color: _muted, fontSize: 13),
        )
      else
        Row(
          children: [
            Expanded(
              child: _bigBtn(
                recording ? 'Stop' : 'Record',
                icon: recording ? Icons.stop_rounded : Icons.mic_rounded,
                color: recording ? _bad : _accent,
                onTap: receiving
                    ? null
                    : () {
                        HapticFeedback.mediumImpact();
                        recording ? v.stop() : v.record();
                      },
              ),
            ),
            if (ready) ...[
              const SizedBox(width: 10),
              Expanded(
                child: _bigBtn(
                  'Download',
                  icon: Icons.download_rounded,
                  color: _panel,
                  border: true,
                  onTap: v.download,
                ),
              ),
            ],
          ],
        ),
    ]);
  }

  Widget _noteTile(VoiceController v, VoiceNote n) {
    final playing = _playingPath == n.file.path;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _panel,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _line),
      ),
      child: Row(
        children: [
          IconButton(
            icon: Icon(
              playing ? Icons.pause_circle_filled : Icons.play_circle_fill,
              color: _accent,
              size: 34,
            ),
            onPressed: () => _togglePlay(n),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${n.seconds}s note',
                  style: const TextStyle(
                    color: _text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  '${n.at.year}-${n.at.month.toString().padLeft(2, '0')}-${n.at.day.toString().padLeft(2, '0')}  '
                  '${n.at.hour.toString().padLeft(2, '0')}:${n.at.minute.toString().padLeft(2, '0')}',
                  style: const TextStyle(color: _muted, fontSize: 12),
                ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline_rounded, color: _muted),
            onPressed: () async {
              if (playing) {
                await _player.stop();
                setState(() => _playingPath = null);
              }
              await v.deleteNote(n);
            },
          ),
        ],
      ),
    );
  }

  Widget _bigBtn(
    String label, {
    required IconData icon,
    required Color color,
    VoidCallback? onTap,
    bool border = false,
  }) {
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: color,
        borderRadius: BorderRadius.circular(14),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: border
                ? BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _line),
                  )
                : null,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: _text, size: 20),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: const TextStyle(
                    color: _text,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
