import 'package:flutter/material.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player/mpv_engine.dart';
import 'package:open_tv/player/player_engine.dart';

/// Singleton that manages the picture-in-picture overlay player.
///
/// The overlay always uses [MpvEngine] (supports all stream formats) and
/// plays muted.  The full-screen [Player] widget registers itself so the
/// swap operation can pop it and start a fresh [Player] for the ex-overlay
/// channel.
class OverlayPlayerController extends ChangeNotifier {
  OverlayPlayerController._();
  static final instance = OverlayPlayerController._();

  // ── Overlay state ──────────────────────────────────────────────────────────

  Channel? _channel;
  Settings? _settings;
  Source? _source;
  MpvEngine? _engine;
  Alignment _corner = Alignment.bottomRight;

  Channel? get channel => _channel;
  MpvEngine? get engine => _engine;
  Alignment get corner => _corner;

  // ── Main player registration (set by the active Player route) ─────────────

  Channel? _mainChannel;
  Settings? _mainSettings;
  Source? _mainSource;
  PlayerEngine? _mainEngine;

  Channel? get mainChannel => _mainChannel;
  Settings? get mainSettings => _mainSettings;
  Source? get mainSource => _mainSource;

  void registerMain(Channel ch, Settings s, Source? src, PlayerEngine engine) {
    _mainChannel = ch;
    _mainSettings = s;
    _mainSource = src;
    _mainEngine = engine;
  }

  void unregisterMain() {
    _mainChannel = null;
    _mainSettings = null;
    _mainSource = null;
    _mainEngine = null;
  }

  /// Mutes the currently active main player so audio doesn't bleed during
  /// the swap navigation transition.
  Future<void> muteMain() async {
    await _mainEngine?.setVolume(0.0);
  }

  // ── Overlay lifecycle ──────────────────────────────────────────────────────

  /// Start (or restart) the overlay for [ch].
  Future<void> startOverlay(Channel ch, Settings s, Source? src) async {
    await _disposeEngine();
    _channel = ch;
    _settings = s;
    _source = src;
    notifyListeners();

    final url = ch.url;
    if (url == null || url.isEmpty) return;

    final engine = MpvEngine(
      channel: ch,
      settings: s,
      fullscreenOnOpen: false,
    );
    _engine = engine;
    notifyListeners();

    await engine.open(url: url);
    // Mute immediately — overlay is always silent
    await engine.setVolume(0.0);
  }

  /// Stop the overlay and release all resources.
  Future<void> stopOverlay() async {
    await _disposeEngine();
    _channel = null;
    _settings = null;
    _source = null;
    notifyListeners();
  }

  void setCorner(Alignment corner) {
    _corner = corner;
    notifyListeners();
  }

  // ── Swap helpers (called by OverlayPlayerWidget) ───────────────────────────

  /// Returns a snapshot of the current overlay state and disposes the engine,
  /// clearing the channel.  Returns null if no overlay is active.
  Future<({Channel ch, Settings s, Source? src})?> consumeOverlay() async {
    final ch = _channel;
    final s = _settings;
    final src = _source;
    if (ch == null || s == null) return null;

    await _disposeEngine();
    _channel = null;
    _settings = null;
    _source = null;
    notifyListeners();
    return (ch: ch, s: s, src: src);
  }

  // ── Internal ───────────────────────────────────────────────────────────────

  Future<void> _disposeEngine() async {
    final e = _engine;
    _engine = null;
    await e?.dispose();
  }
}
