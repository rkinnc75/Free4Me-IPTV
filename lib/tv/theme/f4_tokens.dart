import 'package:flutter/material.dart';

/// fix701 (TV GUI redesign, Phase 0) — the single static token tree for TV mode.
///
/// One immutable object IS the TV design language: colors, spacing, radii, type,
/// elevation, scrim, focus geometry, and the poster-grid spec. Delivered as a
/// [ThemeExtension] on the existing dark `ThemeData` and read via [F4.of]. These
/// are STATIC (never change at runtime) — the live accent is separate
/// (`AccentScope`). TV-scoped: the phone UI never imports this.
///
/// The base leans Peer4 near-black neutral (the 60%); player panels pick up
/// Peer2 slate-blue (the 40%); section/tab identity colors are our own win and
/// live in `tv_shell.dart`, not here.

@immutable
class F4Colors {
  const F4Colors({
    this.background = const Color(0xFF08090A),
    this.backgroundOled = const Color(0xFF000000),
    this.surface = const Color(0xFF0D0D0D),
    this.surfaceElevated = const Color(0xFF1A1A1A),
    this.panelSlate = const Color(0xFF0B0F19),
    this.glassFill = const Color(0xCC0B0F19),
    this.epgCell = const Color(0xFF14161C),
    this.epgCellFocused = const Color(0xFF1B1D25),
    this.textPrimary = const Color(0xFFEDEDED),
    this.textSecondary = const Color(0xB3EDEDED),
    this.textDisabled = const Color(0x4DEDEDED),
    this.hairline = const Color(0x1FEDEDED),
    this.glassStroke = const Color(0x26FFFFFF),
    this.liveRed = const Color(0xFFFF3B30),
    this.watchedGreen = const Color(0xFF22C55E),
    this.inProgressGrey = const Color(0xFF757575),
  });

  // Base surfaces (Peer4 near-black, +Peer2 slate in player panels).
  final Color background; // app bg
  final Color backgroundOled; // OLED-black toggle
  final Color surface; // cards / tiles
  final Color surfaceElevated; // menus / modals
  final Color panelSlate; // player panels base (Peer2)
  final Color glassFill; // 80% slate glass (Peer2), static alpha
  final Color epgCell; // guide cell
  final Color epgCellFocused; // focused guide row

  // Foreground ramp (Peer4 Arctic, opacity baked in).
  final Color textPrimary;
  final Color textSecondary; // 70%
  final Color textDisabled; // 30%
  final Color hairline; // 12% borders / dividers
  final Color glassStroke; // 15% white (Peer2 glass stroke)

  // Semantic.
  final Color liveRed; // LIVE badge / REC dot
  final Color watchedGreen; // watched check
  final Color inProgressGrey;
  // NB: the focus-ring color is resolved from `AccentScope` at draw time and is
  // deliberately NOT stored here.

  F4Colors lerp(F4Colors o, double t) => F4Colors(
        background: Color.lerp(background, o.background, t)!,
        backgroundOled: Color.lerp(backgroundOled, o.backgroundOled, t)!,
        surface: Color.lerp(surface, o.surface, t)!,
        surfaceElevated: Color.lerp(surfaceElevated, o.surfaceElevated, t)!,
        panelSlate: Color.lerp(panelSlate, o.panelSlate, t)!,
        glassFill: Color.lerp(glassFill, o.glassFill, t)!,
        epgCell: Color.lerp(epgCell, o.epgCell, t)!,
        epgCellFocused: Color.lerp(epgCellFocused, o.epgCellFocused, t)!,
        textPrimary: Color.lerp(textPrimary, o.textPrimary, t)!,
        textSecondary: Color.lerp(textSecondary, o.textSecondary, t)!,
        textDisabled: Color.lerp(textDisabled, o.textDisabled, t)!,
        hairline: Color.lerp(hairline, o.hairline, t)!,
        glassStroke: Color.lerp(glassStroke, o.glassStroke, t)!,
        liveRed: Color.lerp(liveRed, o.liveRed, t)!,
        watchedGreen: Color.lerp(watchedGreen, o.watchedGreen, t)!,
        inProgressGrey: Color.lerp(inProgressGrey, o.inProgressGrey, t)!,
      );
}

@immutable
class F4Spacing {
  const F4Spacing();
  final double xs = 4, sm = 8, md = 16, lg = 24, xl = 36;
  final double contentStartTv = 36; // Peer4 TV content start (mobile stays 16)
  final double railWidth = 210; // our current rail (kept; Peer4 uses 170)
  final double settingsRailWidth = 300; // our current (kept)
}

@immutable
class F4Radius {
  const F4Radius();
  final double sm = 8, card = 12, panel = 16, modal = 20;
  // inner = modal(20) − 1dp glass stroke, for content clipped inside a modal.
  final double inner = 19;
  final double pill = 999;
}

@immutable
class F4Type {
  const F4Type();
  // sp, Inter, TV-tuned (Peer4 10-foot scale).
  final double hero = 48,
      title = 20,
      section = 20,
      cardTitle = 15,
      body = 13,
      caption = 11,
      badge = 9;
  // EPG micro-ramp (hard ceiling 11, floor 7).
  final double epgChannel = 11,
      epgProgram = 10,
      epgCell = 9,
      epgSynopsis = 8,
      epgMono = 8;
}

@immutable
class F4Elevation {
  const F4Elevation();
  final double cardRest = 4, cardFocused = 32; // Peer4 chrome
  final double osdRest = 2, osdFocused = 8; // Peer2 player buttons (2→8dp lift)
}

@immutable
class F4Scrim {
  const F4Scrim();
  final double playerRest = 0.0; // video fully visible when no menu
  final double playerMenu = 0.6; // Peer2 scrim target on menu open
  final double modalBarrier = 0.65; // Peer4 modal scrim
  final double pastProgramDim = 0.55; // Peer4 dimmed past EPG cells
}

@immutable
class F4Focus {
  const F4Focus();
  final double ringCard = 2.5; // tiles / cards
  final double ringChrome = 3.0; // nav chrome (tabs, rails)
  final double nowGlowRadius = 8; // EPG NOW-line glow blur radius
}

/// Poster-grid spec — extracted so the `130 / 0.838 / 6` magic numbers stop
/// being duplicated across the three grid views (browse / categories / search).
@immutable
class F4Grid {
  const F4Grid();
  final double maxTileExtent = 130; // max cross-axis extent per poster
  final double childAspectRatio = 0.838; // poster w:h
  final double spacing = 6; // main + cross axis gap
}

/// Genre → (primary, brand-tint) color pairs for the Peer4 EPG on-now-cell
/// left-edge tint and typographic-logo fallback. Keyed by the 7 normalized
/// buckets; `Program.category` free-text is mapped onto these in Phase 3 (see
/// the §2.2 data-layer scope caveat — there is no per-channel genre).
const Map<String, (Color, Color)> kGenreColors = <String, (Color, Color)>{
  'news': (Color(0xFFEF4444), Color(0xFF7F1D1D)),
  'sport': (Color(0xFF22C55E), Color(0xFF14532D)),
  'movies': (Color(0xFF8B5CF6), Color(0xFF3B0764)),
  'kids': (Color(0xFFF59E0B), Color(0xFF78350F)),
  'music': (Color(0xFFEC4899), Color(0xFF831843)),
  'docs': (Color(0xFF06B6D4), Color(0xFF164E63)),
  'general': (Color(0xFF64748B), Color(0xFF1E293B)),
};

/// The static TV token tree, attached to `ThemeData` as a [ThemeExtension].
@immutable
class F4Tokens extends ThemeExtension<F4Tokens> {
  const F4Tokens({
    this.colors = const F4Colors(),
    this.spacing = const F4Spacing(),
    this.radius = const F4Radius(),
    this.typography = const F4Type(),
    this.elevation = const F4Elevation(),
    this.scrim = const F4Scrim(),
    this.focus = const F4Focus(),
    this.grid = const F4Grid(),
  });

  final F4Colors colors;
  final F4Spacing spacing;
  final F4Radius radius;
  final F4Type typography;
  final F4Elevation elevation;
  final F4Scrim scrim;
  final F4Focus focus;
  final F4Grid grid;

  /// The default (and, today, only) token tree.
  factory F4Tokens.defaults() => const F4Tokens();

  @override
  F4Tokens copyWith({
    F4Colors? colors,
    F4Spacing? spacing,
    F4Radius? radius,
    F4Type? typography,
    F4Elevation? elevation,
    F4Scrim? scrim,
    F4Focus? focus,
    F4Grid? grid,
  }) =>
      F4Tokens(
        colors: colors ?? this.colors,
        spacing: spacing ?? this.spacing,
        radius: radius ?? this.radius,
        typography: typography ?? this.typography,
        elevation: elevation ?? this.elevation,
        scrim: scrim ?? this.scrim,
        focus: focus ?? this.focus,
        grid: grid ?? this.grid,
      );

  @override
  F4Tokens lerp(ThemeExtension<F4Tokens>? other, double t) {
    if (other is! F4Tokens) return this;
    // Only the color ramp is worth interpolating; the geometry/type tokens are
    // structural constants (one instance app-wide), so they snap.
    return F4Tokens(
      colors: colors.lerp(other.colors, t),
      spacing: other.spacing,
      radius: other.radius,
      typography: other.typography,
      elevation: other.elevation,
      scrim: other.scrim,
      focus: other.focus,
      grid: other.grid,
    );
  }
}

/// Sugar for reading the TV token tree: `F4.of(context)`.
///
/// Asserts the extension is installed (the TV theme always attaches it); if a
/// caller reaches this off the TV path it is a wiring bug, not a silent
/// fallback.
class F4 {
  F4._();

  static F4Tokens of(BuildContext context) {
    final t = Theme.of(context).extension<F4Tokens>();
    assert(t != null, 'F4Tokens not found — TV theme must attach it (fix701).');
    return t ?? F4Tokens.defaults();
  }
}
