import 'dart:async';

import 'package:flutter/material.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/models/source.dart';
import 'package:open_tv/player/mpv_engine.dart';
import 'package:open_tv/player/player_engine.dart';

/// Singleton that manages the picture-in-picture overlay player.
///
/// The overlay always uses [MpvEngine] (supports all stream formats) and
/// plays with audio when it is the only active player, and is muted while
/// a full-screen [Player] is active.  The full-screen Player registers
/// itself so the
/// swap operation can pop it and start a fresh [Player] for the ex-overlay
/// channel.
class OverlayPlayerController extends ChangeNotifier {
  OverlayPlayerController._();
  static final instance = OverlayPlayerController._();


  Channel? _channel;
  Settings? _settings;
  Source? _source;
  MpvEngine? _engine;
  Alignment _corner = Alignment.bottomRight;
  // Review finding 147: monotonic token so a superseded in-flight startOverlay
  // disposes its locally-created engine instead of leaking it, and a
  // stopOverlay racing an in-flight start wins.
  int _startGeneration = 0;

  Channel? get channel => _channel;
  MpvEngine? get engine => _engine;
  Alignment get corner => _corner;


  Channel? _mainChannel;
  Settings? _mainSettings;
  Source? _mainSource;
  PlayerEngine? _mainEngine;
  /// fix106: the outgoing full-screen player registers a halt callback so
  /// the swap path can synchronously stop it before pushReplacement,
  /// preventing phantom background reconnect engines.
  Future<void> Function()? _mainHalt;
  /// fix116: the outgoing full-screen player registers a "detach" callback
  /// that stops its reconnect/timers and returns its live engine WITHOUT
  /// disposing it, so the swap can hand that engine to the overlay.
  MpvEngine? Function()? _mainDetach;

  Channel? get mainChannel => _mainChannel;
  Settings? get mainSettings => _mainSettings;
  Source? get mainSource => _mainSource;

  void registerMain(Channel ch, Settings s, Source? src, PlayerEngine engine) {
    AppLog.info('OverlayController: registerMain channel="${ch.name}"');
    // fix100: mute the outgoing main engine on handoff so its audio doesn't
    // bleed under the new player. Replaces fix98.2's RouteAware muting,
    // which misfired on the newly-created player and opened it muted.
    final previous = _mainEngine;
    if (previous != null && previous != engine) {
      AppLog.info('OverlayController: muting outgoing main on handoff');
      unawaited(previous.setVolume(0.0));
    }
    // fix100: a full-screen player is taking over audio — mute the
    // mini-player overlay (if any) so only one source is audible.
    if (_engine != null) {
      AppLog.info('OverlayController: muting overlay — full-screen active');
      unawaited(_engine!.setVolume(0.0));
    }
    _mainChannel = ch;
    _mainSettings = s;
    _mainSource = src;
    _mainEngine = engine;
    _mainHalt = null;   // fix106: new player registers its own halt below
    _mainDetach = null; // fix116: new player registers its own detach below
  }

  /// Unregisters [engine] as the main player.  If [engine] is provided and
  /// no longer matches the currently registered engine (because a new Player
  /// already called [registerMain] during a swap transition), the call is a
  /// no-op — this prevents the old Player's [dispose] from wiping the new
  /// Player's registration.
  void unregisterMain([PlayerEngine? engine]) {
    if (engine != null && _mainEngine != engine) {
      AppLog.info('OverlayController: unregisterMain — stale engine, ignored');
      return;
    }
    AppLog.info('OverlayController: unregisterMain');
    _mainChannel = null;
    _mainSettings = null;
    _mainSource = null;
    _mainEngine = null;
    _mainHalt = null;   // fix106
    _mainDetach = null; // fix116
    // fix100: full-screen closed — if the mini-player is still up, it's now
    // the only player, so restore its audio.
    if (_engine != null) {
      AppLog.info('OverlayController: restoring overlay audio');
      unawaited(_engine!.setVolume(1.0));
    }
  }


  /// fix106: registers [halt] as the synchronous shutdown callback for the
  /// current main player. Called by the Player in [initState] immediately
  /// after [registerMain].
  void registerMainHalt(Future<void> Function() halt) {
    _mainHalt = halt;
  }

  /// fix106: halts the outgoing full-screen player synchronously.
  /// Disposes its engine and cancels its timers so it cannot fire a
  /// background reconnect after its route is replaced by pushReplacement.
  Future<void> haltMain() async {
    final h = _mainHalt;
    if (h != null) {
      AppLog.info('OverlayController: haltMain');
      await h();
    }
  }

  /// fix116: registers [detach] as the detach callback for the current main
  /// player. Called by the Player in [initState] after [registerMainHalt].
  void registerMainDetach(MpvEngine? Function() detach) {
    _mainDetach = detach;
  }

  /// fix116: detach the current full-screen engine for handoff. Returns the
  /// live engine (still playing) or null if none / not detachable.
  MpvEngine? detachMain() {
    final d = _mainDetach;
    if (d != null) {
      final e = d();
      AppLog.info('OverlayController: detachMain →'
          ' eid=${e == null ? 'null' : identityHashCode(e)}');
      return e;
    }
    AppLog.info('OverlayController: detachMain — no detach callback');
    return null;
  }

  /// fix116: RETURNS the live engine instead of disposing it, so the caller
  /// (swap) can hand it to the new full-screen
  /// Player. The overlay's references are cleared but the engine keeps
  /// playing. Returns null if no overlay is active.
  ({Channel ch, Settings s, Source? src, MpvEngine engine})?
      detachOverlayEngine() {
    final ch = _channel;
    final s = _settings;
    final src = _source;
    final e = _engine;
    if (ch == null || s == null || e == null) {
      AppLog.warn('OverlayController: detachOverlayEngine — nothing to detach');
      return null;
    }
    AppLog.info('OverlayController: detachOverlayEngine'
        ' eid=${identityHashCode(e)} channel="${ch.name}"');
    // Clear references WITHOUT disposing — ownership transfers to the Player.
    _engine = null;
    _channel = null;
    _settings = null;
    _source = null;
    notifyListeners();
    return (ch: ch, s: s, src: src, engine: e);
  }

  /// fix116: install an already-playing engine as the overlay (no open).
  /// Used by swap to demote the ex-full-screen engine into the mini-player.
  void adoptOverlayEngine(
    Channel ch,
    Settings s,
    Source? src,
    MpvEngine engine, {
    bool muted = true,
  }) {
    AppLog.info('OverlayController: adoptOverlayEngine'
        ' eid=${identityHashCode(engine)}'
        ' channel="${ch.name}" muted=$muted');
    _channel = ch;
    _settings = s;
    _source = src;
    _engine = engine;
    unawaited(engine.setVolume(muted ? 0.0 : 1.0));
    notifyListeners();
  }


  /// Start (or restart) the overlay for [ch].
  ///
  /// [forceMuted] forces the overlay to start muted regardless of whether a
  /// full-screen player is currently registered. Used by the swap path
  /// (fix100.4) where the new full-screen player's [registerMain] may not
  /// have fired yet when this is called.
  Future<void> startOverlay(
    Channel ch,
    Settings s,
    Source? src, {
    bool forceMuted = false,
  }) async {
    AppLog.info('OverlayController: startOverlay channel="${ch.name}"');
    final int gen = ++_startGeneration; // review finding 147
    await _disposeEngine();
    if (gen != _startGeneration) return; // superseded during dispose
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
      // The overlay is always a small preview window, never full-screen.
      // previewMode swaps in mini-buffer sizes and forces software decode,
      // which avoids contending with the main player for the device's
      // hardware decoder pool and shared bandwidth budget.
      previewMode: true,
    );
    // fix100: the mini-player now plays WITH audio when it is the only
    // active player. If a full-screen player is already registered, start
    // muted (full-screen owns audio); otherwise start audible.
    // fix100.4: forceMuted covers the swap transition where the new full-screen
    // player's registerMain may not have fired yet.
    final fullScreenActive = forceMuted || _mainEngine != null;
    await engine.setVolume(fullScreenActive ? 0.0 : 1.0);
    if (gen != _startGeneration) {
      // Review finding 147: a newer start/stop superseded us before we stored
      // this engine — dispose the orphan so it does not keep decoding.
      await engine.dispose();
      return;
    }
    _engine = engine;
    notifyListeners();

    // fix110: apply mpv options (hwdec, demuxer, buffer) BEFORE open().
    // Without this the overlay engine never gets fix108's mediacodec-copy
    // hwdec and ran on mpv's default decode path, which stalled on these
    // streams — the mini-player opened but never rendered (frozen black).
    await engine.reapplyOptions(url: url);
    await engine.open(url: url);
    AppLog.info('OverlayController: overlay open() succeeded channel="${ch.name}"');
  }

  /// Stop the overlay and release all resources.
  Future<void> stopOverlay() async {
    AppLog.info('OverlayController: stopOverlay channel="${_channel?.name ?? 'none'}"');
    ++_startGeneration; // review finding 147: invalidate any in-flight start
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



  Future<void> _disposeEngine() async {
    final e = _engine;
    _engine = null;
    await e?.dispose();
  }
}
