import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:open_tv/backend/app_logger.dart';
import 'package:open_tv/backend/sql.dart';
import 'package:open_tv/models/channel.dart';
import 'package:open_tv/models/settings.dart';
import 'package:open_tv/player/mpv_engine.dart';

/// fix510: single-engine, dwell-gated, MUTED live preview controller for the
/// TV Live-guide hero. TV-only — constructed and owned by [TvGuideView].
///
/// Owns AT MOST ONE [MpvEngine] (previewMode) at any instant. A generation
/// token (mirrors `MultiViewCell._openGeneration`) cancels in-flight opens when
/// the focused channel changes, and the prior engine is disposed-and-awaited
/// before the next is constructed — so D-pad scrolling never leaks or overlaps
/// engines and never holds more than one provider connection. Software decode
/// is FORCED (`forceSoftwareDecode: true`) so the preview never hits the
/// Amlogic `mediacodec-copy` texture-attach failure. Any stream error falls
/// back to art (never auto-restart). Extends [ChangeNotifier] so the hero
/// rebuilds when the preview goes live / falls back to art.
class TvHeroPreview extends ChangeNotifier {
  MpvEngine? _engine;
  StreamSubscription<String>? _errSub;
  StreamSubscription<bool>? _bufSub;
  Timer? _dwell;
  int _gen = 0;
  bool _live = false;
  bool _disposed = false;

  /// True once the preview engine has produced its first frame.
  bool get isLive => _live && _engine != null;

  /// The video texture for the hero box, or null when there is no live frame
  /// yet (the hero shows channel art underneath until then).
  Widget? buildVideoView(BuildContext context) =>
      isLive ? _engine!.buildVideoView(context) : null;

  /// Arm/replace the dwell timer for a newly-focused channel. With
  /// [liveEnabled] false (or no URL) we just tear down any preview (art-first).
  /// The preview opens only after focus settles for [dwellMs].
  void onChannelFocused(
    Channel ch, {
    required Settings settings,
    required int dwellMs,
    required bool liveEnabled,
  }) {
    if (_disposed) return;
    _dwell?.cancel();
    if (!liveEnabled || ch.url == null) {
      unawaited(stop()); // art-first: release any held connection
      return;
    }
    _dwell = Timer(
      Duration(milliseconds: dwellMs),
      () => unawaited(_warm(ch, settings)),
    );
  }

  Future<void> _warm(Channel ch, Settings settings) async {
    if (_disposed) return;
    final g = ++_gen;
    // Tear down the previous engine FIRST (serialized texture release) so only
    // one engine — and one provider connection — exists at any instant.
    await _teardownEngine();
    if (g != _gen || _disposed) return;

    // Fetch headers BEFORE allocating the native engine, so a superseding
    // _warm can never transiently hold two libmpv players.
    final headers = ch.id != null ? await Sql.getChannelHeaders(ch.id!) : null;
    if (g != _gen || _disposed) return;
    final ignoreSsl = headers != null &&
        (headers.ignoreSSL == '1' ||
            headers.ignoreSSL?.toLowerCase() == 'true');
    final engine = MpvEngine(
      channel: ch,
      settings: settings,
      fullscreenOnOpen: false,
      previewMode: true,
    );
    try {
      // reapplyOptions MUST precede open() (seek-probe contract). Force
      // software decode regardless of the multi-view decode setting.
      await engine.reapplyOptions(
        url: ch.url ?? '',
        ignoreSsl: ignoreSsl,
        forceSoftwareDecode: true,
      );
      if (g != _gen || _disposed) {
        await engine.dispose();
        return;
      }
      await engine.setVolume(0.0); // always muted while browsing
      if (g != _gen || _disposed) {
        await engine.dispose();
        return;
      }
      // Commit as the current engine, then open.
      _engine = engine;
      _errSub = engine.errorStream.listen((err) {
        if (g == _gen && !_disposed) {
          AppLog.warn('TvHeroPreview: preview error — $err');
          unawaited(stop()); // drop to art; never auto-restart
        }
      });
      _bufSub = engine.bufferingStream.listen((buffering) {
        if (!buffering && g == _gen && !_disposed && !_live) {
          _live = true;
          notifyListeners(); // cross-fade video over the art
        }
      });
      await engine.open(url: ch.url ?? '', isLive: true);
      // If superseded during open, the newer _warm already tore this engine
      // down — do nothing here.
      if (g != _gen || _disposed) return;
    } catch (e) {
      AppLog.warn('TvHeroPreview: warm failed — $e');
      if (identical(_engine, engine)) {
        await _teardownEngine();
      } else {
        await engine.dispose().catchError((Object _) {});
      }
    }
  }

  /// Dispose the current engine + its subscriptions. Does NOT bump the
  /// generation (callers that need cancellation bump it first). Awaitable.
  Future<void> _teardownEngine() async {
    await _errSub?.cancel();
    _errSub = null;
    await _bufSub?.cancel();
    _bufSub = null;
    final e = _engine;
    _engine = null;
    final wasLive = _live;
    _live = false;
    if (e != null) {
      await e.dispose().catchError((Object err) {
        AppLog.warn('TvHeroPreview: dispose error — $err');
      });
    }
    if (wasLive && !_disposed) notifyListeners();
  }

  /// Stop + release any preview (and its provider connection). Idempotent and
  /// awaitable — call before opening full-screen and on tab-away.
  Future<void> stop() async {
    _dwell?.cancel();
    _gen++; // cancel any in-flight open
    await _teardownEngine();
  }

  /// Tear down for good (widget dispose).
  void disposeController() {
    _disposed = true;
    _dwell?.cancel();
    _gen++;
    unawaited(_teardownEngine());
    super.dispose();
  }
}
