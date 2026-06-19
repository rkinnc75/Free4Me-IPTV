import 'package:flutter/material.dart';

/// fix404: how the video widget renders inside its parent (the screen, or
/// a multi-view cell). Cycles through three modes that control how the
/// video's decoded frame is mapped to the visible viewport.
///
/// The session-only `_zoomMode` lives on the Player State (matches the
/// pre-fix404 `bool fill` pattern). Per-cell override is not modelled —
/// multi-view cells inherit the player's current mode, consistent with
/// how the engine routes video to every open surface.
enum ZoomMode {
  /// Letterbox: preserve the video's native aspect ratio. The frame fits
  /// inside the viewport with black bars on the long axis when the
  /// video aspect ≠ device aspect. No distortion; may show bars.
  fit,

  /// Stretch: force the video's frame to fill the viewport, even if
  /// that means horizontal or vertical geometric distortion (people look
  /// fatter on a 4:3 stream stretched to 16:9). Maps to [BoxFit.fill].
  stretch,

  /// Fill with crop: scale the video to cover the entire viewport and
  /// clip the overflow. Useful for cinema/ultrawide content (21:9 on
  /// 16:9) where the original letterbox was intentional — fill crops
  /// the top/bottom rather than introducing distortion. Maps to
  /// [BoxFit.cover]. Some content is lost at the edges.
  crop;

  /// Cycle to the next mode. Order: fit → stretch → crop → fit.
  ZoomMode next() => switch (this) {
        ZoomMode.fit => ZoomMode.stretch,
        ZoomMode.stretch => ZoomMode.crop,
        ZoomMode.crop => ZoomMode.fit,
      };

  /// Material [BoxFit] that produces this mode's render behaviour when
  /// passed as `fit:` to `mkvideo.Video`. See lib/src/video/video_texture.dart
  /// in media_kit_video: the widget wraps a Texture in a FittedBox whose
  /// `fit` controls how the texture's SizedBox is mapped onto the
  /// parent container's bounds.
  BoxFit get boxFit => switch (this) {
        ZoomMode.fit => BoxFit.contain,
        ZoomMode.stretch => BoxFit.fill,
        ZoomMode.crop => BoxFit.cover,
      };

  /// Icon for the player-controls button when this mode is active. The
  /// icon visually represents the current mode (rectangle with bars /
  /// stretched / cropped) so the user can tell which mode they're in
  /// without reading the tooltip.
  IconData get icon => switch (this) {
        ZoomMode.fit => Icons.aspect_ratio_outlined,
        ZoomMode.stretch => Icons.fit_screen_outlined,
        ZoomMode.crop => Icons.crop_landscape_outlined,
      };

  /// Short tooltip for the player-controls button.
  String get tooltip => switch (this) {
        ZoomMode.fit => 'Fit (letterbox)',
        ZoomMode.stretch => 'Stretch to fill',
        ZoomMode.crop => 'Fill with crop',
      };
}
