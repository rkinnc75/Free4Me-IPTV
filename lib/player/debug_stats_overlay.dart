import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/player/mpv_engine.dart';

/// fix564: a compact, semi-transparent playback-stats panel pinned to the
/// top-right of single-cell full-screen video. Shown ONLY when debug logging
/// is on (gated at the call site in Player.build). Polls libmpv once a second
/// via [MpvEngine.readPlaybackStats], shows the decode path / fps / dropped-
/// frame rate / A/V sync / cache, and writes the same snapshot to [AppLog]
/// (tagged `STATS`) every tick so it also lands in the uploaded report log for
/// offline review.
///
/// The widget returns a [Positioned] so it can be dropped straight into the
/// player's [Stack], and is wrapped in [IgnorePointer] so it never intercepts
/// D-pad focus or touches.
class DebugStatsOverlay extends StatefulWidget {
  final MpvEngine engine;

  /// fix588 (#22): when true, render a reduced 2-line panel (res + fps + drops)
  /// at a smaller font, sized for a multi-view / PiP cell where the full 8-row
  /// panel does not fit. The 1 Hz poll + STATS log line are unchanged.
  final bool compact;

  const DebugStatsOverlay({
    super.key,
    required this.engine,
    this.compact = false,
  });

  @override
  State<DebugStatsOverlay> createState() => _DebugStatsOverlayState();
}

class _DebugStatsOverlayState extends State<DebugStatsOverlay> {
  Timer? _timer;
  Map<String, String> _stats = const {};
  int? _lastVoDrop;
  int? _lastDecDrop;
  int _voDropDelta = 0;
  int _decDropDelta = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _tick());
    _tick();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _tick() async {
    final s = await widget.engine.readPlaybackStats();
    if (!mounted || s.isEmpty) return;

    final voDrop = int.tryParse(s['frame-drop-count'] ?? '');
    final decDrop = int.tryParse(s['decoder-frame-drop-count'] ?? '');
    final voDelta =
        (voDrop != null && _lastVoDrop != null) ? voDrop - _lastVoDrop! : 0;
    final decDelta =
        (decDrop != null && _lastDecDrop != null) ? decDrop - _lastDecDrop! : 0;
    _lastVoDrop = voDrop;
    _lastDecDrop = decDrop;

    setState(() {
      _stats = s;
      _voDropDelta = voDelta;
      _decDropDelta = decDelta;
    });

    // Mirror every snapshot to the log so a report upload captures the
    // time-series during a stutter (deltas are drops since the previous tick).
    AppLog.info(
      'MpvEngine: STATS hwdec-req="${s['hwdec']}" '
      'current="${s['hwdec-current']}" codec="${s['video-codec']}" '
      'vfFps="${s['estimated-vf-fps']}" srcFps="${s['container-fps']}" '
      'voDrop=${s['frame-drop-count']}(+$voDelta) '
      'decDrop=${s['decoder-frame-drop-count']}(+$decDelta) '
      'avsync="${s['avsync']}" vbitrate="${s['video-bitrate']}" '
      'cache="${s['demuxer-cache-duration']}" '
      'pausedForCache="${s['paused-for-cache']}" '
      // fix750 (DIAGNOSTIC ONLY — no behavior change): demuxer progress, to
      // distinguish a legitimate pause from a starved/wedged demuxer.
      'demuxTime="${s['demuxer-cache-time']}" '
      'cacheSpeed="${s['cache-speed']}" '
      'coreIdle="${s['core-idle']}" '
      'eof="${s['eof-reached']}" '
      // fix751 (DIAGNOSTIC ONLY): mpv's own pause flag — the discriminator
      // between "someone paused this" and "this is wedged".
      'pause="${s['pause']}" '
      'res=${s['width']}x${s['height']} '
      'framedrop="${s['framedrop']}" videoSync="${s['video-sync']}"',
    );
  }

  // ---- formatting helpers -------------------------------------------------

  String _fps(String? raw) {
    final v = double.tryParse(raw ?? '');
    return v == null ? '—' : v.toStringAsFixed(1);
  }

  String _mbps(String? raw) {
    final v = double.tryParse(raw ?? '');
    return v == null ? '—' : '${(v / 1e6).toStringAsFixed(2)} Mb/s';
  }

  String _ms(String? raw) {
    final v = double.tryParse(raw ?? '');
    if (v == null) return '—';
    final ms = (v * 1000).round();
    return '${ms >= 0 ? '+' : ''}$ms ms';
  }

  String _secs(String? raw) {
    final v = double.tryParse(raw ?? '');
    return v == null ? '—' : '${v.toStringAsFixed(1)}s';
  }

  /// hwdec-current is '' or 'no' when decode fell back to software.
  bool get _isSoftware {
    final cur = (_stats['hwdec-current'] ?? '').trim();
    return cur.isEmpty || cur == 'no';
  }

  bool get _avsyncBad {
    final v = double.tryParse(_stats['avsync'] ?? '');
    return v != null && v.abs() > 0.08;
  }

  bool get _renderingBehind {
    final vf = double.tryParse(_stats['estimated-vf-fps'] ?? '');
    final src = double.tryParse(_stats['container-fps'] ?? '');
    return vf != null && src != null && src > 0 && vf < src - 2.0;
  }

  @override
  Widget build(BuildContext context) {
    if (_stats.isEmpty) return const SizedBox.shrink();

    const labelStyle = TextStyle(
      color: Colors.white70,
      fontSize: 11,
      fontFamily: 'monospace',
      height: 1.35,
    );
    TextStyle val(bool warn) => TextStyle(
          color: warn ? const Color(0xFFFFC107) : Colors.white,
          fontSize: 11,
          fontFamily: 'monospace',
          fontWeight: FontWeight.w600,
          height: 1.35,
        );

    Widget row(String label, String value, {bool warn = false}) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              child: Text(label, style: labelStyle),
            ),
            Flexible(child: Text(value, style: val(warn))),
          ],
        );

    final cur = (_stats['hwdec-current'] ?? '').trim();
    final hwLine =
        '${_stats['hwdec'] ?? '—'} -> ${cur.isEmpty ? '(software)' : cur}';

    // fix588 (#22) + fix622: compact variant for small multi-view / PiP cells.
    // Three short lines — resolution+codec, fps+drops, and buffer seconds — at
    // the top-left so it clears the cell's own top-right volume badge and
    // bottom info bar.
    if (widget.compact) {
      const cStyle = TextStyle(
        color: Colors.white,
        fontSize: 8,
        fontFamily: 'monospace',
        height: 1.25,
        fontWeight: FontWeight.w600,
      );
      final dropWarn = _voDropDelta > 0 || _decDropDelta > 0;
      // fix622: buffer health as a 3rd compact line. demuxer-cache-duration is
      // mpv's seconds of buffered content (the same value the full panel's
      // 'cache' row shows). Polled at 1 Hz like the rest, so it updates live —
      // it hovers near the configured livestream/VOD cache target when healthy
      // and visibly counts DOWN when the network can't keep up, flipping to the
      // warn colour once paused-for-cache=yes (an imminent rebuffer).
      final cachePaused = (_stats['paused-for-cache'] ?? '') == 'yes';
      return Positioned(
        top: 4,
        left: 4,
        child: IgnorePointer(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_stats['width'] ?? '—'}x${_stats['height'] ?? '—'} '
                  '${_stats['video-codec'] ?? ''}',
                  style: cStyle,
                ),
                Text(
                  '${_fps(_stats['estimated-vf-fps'])}fps  '
                  'd ${_stats['frame-drop-count'] ?? '—'}/'
                  '${_stats['decoder-frame-drop-count'] ?? '—'}',
                  style: cStyle.copyWith(
                    color: dropWarn ? const Color(0xFFFFC107) : Colors.white,
                  ),
                ),
                Text(
                  'buf ${_secs(_stats['demuxer-cache-duration'])}',
                  style: cStyle.copyWith(
                    color: cachePaused
                        ? const Color(0xFFFF5252)
                        : Colors.white,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Positioned(
      top: 8,
      right: 8,
      child: IgnorePointer(
        child: Container(
          constraints: const BoxConstraints(maxWidth: 230),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.66),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'PLAYBACK (debug)',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 4),
              row('hwdec', hwLine, warn: _isSoftware),
              row('fps',
                  '${_fps(_stats['estimated-vf-fps'])} / ${_fps(_stats['container-fps'])}',
                  warn: _renderingBehind),
              row('drop',
                  'vo ${_stats['frame-drop-count'] ?? '—'} (+$_voDropDelta)  '
                      'dec ${_stats['decoder-frame-drop-count'] ?? '—'} (+$_decDropDelta)',
                  warn: _voDropDelta > 0 || _decDropDelta > 0),
              row('avsync', _ms(_stats['avsync']), warn: _avsyncBad),
              row('bitrate', _mbps(_stats['video-bitrate'])),
              row('cache', _secs(_stats['demuxer-cache-duration']),
                  warn: (_stats['paused-for-cache'] ?? '') == 'yes'),
              row('res',
                  '${_stats['width'] ?? '—'}x${_stats['height'] ?? '—'}  ${_stats['video-codec'] ?? ''}'),
              // Active display/audio tunables in effect — "drop video"
              // (framedrop) and "sync audio" (video-sync). Reflects the
              // effective values libmpv is running (after any low-RAM
              // framedrop auto-upgrade), so a settings sweep is visible
              // on-screen, not just in logcat.
              row('mode',
                  'drop=${_stats['framedrop'] ?? '—'}  sync=${_stats['video-sync'] ?? '—'}'),
            ],
          ),
        ),
      ),
    );
  }
}
