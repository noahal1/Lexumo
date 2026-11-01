/// Design tokens, ported 1:1 from `src/styles/tokens.css`.
///
/// The CSS was the source of truth for the web build; this file is the Flutter
/// equivalent. Both materials survive the port:
///
///   · stone — the frame. Navigation, the streak, the tab bar. Dark in both
///     themes, because it is the desk the work sits on, not a surface you read.
///   · paper — the page. Every screen you work in is paper.
///
/// One accent only: azurite 石青. Cinnabar 朱砂 is destruction alone.
///
/// Nothing in this file may be hard-coded at a call site. If a screen needs a
/// colour, a space or a duration, it comes from here.
library;

// `material` (not `widgets`) because [Palette] extends `ThemeExtension`, which
// is declared there; `widgets` alone leaves it undefined.
import 'package:flutter/material.dart';

/// ---------------------------------------------------------------------------
/// Palette — the light ("paper") theme.
/// ---------------------------------------------------------------------------
abstract final class Paper {
  // page
  static const bg = Color(0xFFF9F7F3);
  static const bgDeep = Color(0xFFF3F1EB);
  static const surface = Color(0xFFFEFDFA);
  static const surface2 = Color(0xFFF3F1EB);
  static const surfaceHover = Color(0xFFEEECE5);
  static const surfaceSunken = Color(0xFFECEAE4);

  // rules
  static const line = Color(0xFFE0DED7);
  static const lineStrong = Color(0xFFC1BFB8);
  static const lineControl = Color(0xFF8B8982);

  // ink — contrast ratios against `bg` are noted where they matter.
  static const ink = Color(0xFF1E221E); // 15.1:1
  static const ink2 = Color(0xFF454B46); //  8.4:1
  static const ink3 = Color(0xFF696F6A); //  4.8:1
  static const ink4 = Color(0xFF848984); //  3.3:1 — decoration only

  // accent: azurite
  static const accent = Color(0xFF175B72);
  static const accentHover = Color(0xFF094E64);
  static const accentSoft = Color(0xFFDCECF3);
  static const accentInk = Color(0xFF083747);
  static const onAccent = Color(0xFFF9FCFE);

  // state
  static const danger = Color(0xFFA83B2E);
  static const dangerSoft = Color(0xFFFCE6E2);
  static const onDanger = Color(0xFFFEFBFA);
  static const warn = Color(0xFF8B6119);
  static const warnSoft = Color(0xFFF9EBD7);
  static const ok = Color(0xFF2E684E);
  static const okSoft = Color(0xFFDEEEE5);

  // chart series
  static const info = Color(0xFF416791);
  static const infoSoft = Color(0xFFE2ECF7);

  // stone: the frame
  static const frame = Color(0xFF252C28);
  static const frame2 = Color(0xFF1C221F);
  static const frame3 = Color(0xFF313935);
  static const frameLine = Color(0xFF3F4743);
  static const frameInk = Color(0xFFE7EBE7); // 11.9:1
  static const frameInk2 = Color(0xFFACB1AD); //  6.6:1
  static const frameInk3 = Color(0xFF9AA09B); //  5.4:1 on frame
  static const frameAccent = Color(0xFF82C8D4);
  static const frameAccentSoft = Color(0xFF264343);
  static const frameWarm = Color(0xFFD8A86B);

  static const scrim = Color(0x70101411); // rgba(16,20,17,0.44)

  /// Hover tint for controls sitting on an inverted surface (the toast).
  static const wash = Color(0x387F7F7F);
}

/// ---------------------------------------------------------------------------
/// Palette — the dark ("slate") theme. Frame gets *darker* than the page here:
/// the desk recedes and the work comes forward, the same relationship as light.
/// ---------------------------------------------------------------------------
abstract final class Slate {
  static const bg = Color(0xFF1D231F);
  static const bgDeep = Color(0xFF121614);
  static const surface = Color(0xFF262C27);
  static const surface2 = Color(0xFF2D342E);
  static const surfaceHover = Color(0xFF343B34);
  static const surfaceSunken = Color(0xFF121613);

  static const line = Color(0xFF2F3633);
  static const lineStrong = Color(0xFF4F5754);
  static const lineControl = Color(0xFF6B7470);

  static const ink = Color(0xFFE7E6E1);
  static const ink2 = Color(0xFFBABBB5);
  static const ink3 = Color(0xFF9AA09A);
  static const ink4 = Color(0xFF6C726D);

  static const accent = Color(0xFF66ADC5);
  static const accentHover = Color(0xFF82C2D8);
  static const accentSoft = Color(0xFF1B343B);
  static const accentInk = Color(0xFFA9D2DE);
  static const onAccent = Color(0xFF06171C);

  static const danger = Color(0xFFE88572);
  static const dangerSoft = Color(0xFF44241F);
  static const onDanger = Color(0xFF150A08);
  static const warn = Color(0xFFDCB46E);
  static const warnSoft = Color(0xFF3D2D14);
  static const ok = Color(0xFF86C8AB);
  static const okSoft = Color(0xFF1D3328);

  static const info = Color(0xFF96BBE3);
  static const infoSoft = Color(0xFF232F3D);

  // The stone goes darker than the page.
  static const frame = Color(0xFF050706);
  static const frame2 = Color(0xFF030504);
  static const frame3 = Color(0xFF0F1412);
  static const frameLine = Color(0xFF39443E);
  static const frameInk = Color(0xFFDDDFDA);
  static const frameInk2 = Color(0xFFA2A6A1);
  static const frameInk3 = Color(0xFF757B76);
  static const frameAccent = Color(0xFF7CC2D6);
  static const frameAccentSoft = Color(0xFF132B2C);
  static const frameWarm = Color(0xFFDCAE74);

  static const scrim = Color(0x99000000); // rgba(0,0,0,0.6)
  static const wash = Color(0x387F7F7F);
  /// The paper's edge catching light. Only used in dark.
  static const edge = Color(0x0EFFFFFF); // rgba(255,255,255,0.055)
}

/// ---------------------------------------------------------------------------
/// The semantic palette the widgets consume. One instance per theme, so a
/// widget reads `sem.accent` instead of branching on brightness.
/// ---------------------------------------------------------------------------
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.bgDeep,
    required this.surface,
    required this.surface2,
    required this.surfaceHover,
    required this.surfaceSunken,
    required this.line,
    required this.lineStrong,
    required this.lineControl,
    required this.ink,
    required this.ink2,
    required this.ink3,
    required this.ink4,
    required this.accent,
    required this.accentHover,
    required this.accentSoft,
    required this.accentInk,
    required this.onAccent,
    required this.danger,
    required this.dangerSoft,
    required this.onDanger,
    required this.warn,
    required this.warnSoft,
    required this.ok,
    required this.okSoft,
    required this.info,
    required this.infoSoft,
    required this.frame,
    required this.frame2,
    required this.frame3,
    required this.frameLine,
    required this.frameInk,
    required this.frameInk2,
    required this.frameInk3,
    required this.frameAccent,
    required this.frameAccentSoft,
    required this.frameWarm,
    required this.scrim,
    required this.wash,
    required this.edge,
    required this.isDark,
  });

  final Color bg, bgDeep, surface, surface2, surfaceHover, surfaceSunken;
  final Color line, lineStrong, lineControl;
  final Color ink, ink2, ink3, ink4;
  final Color accent, accentHover, accentSoft, accentInk, onAccent;
  final Color danger, dangerSoft, onDanger, warn, warnSoft, ok, okSoft, info, infoSoft;
  final Color frame, frame2, frame3, frameLine, frameInk, frameInk2, frameInk3;
  final Color frameAccent, frameAccentSoft, frameWarm;
  final Color scrim, wash, edge;
  final bool isDark;

  static const light = Palette(
    bg: Paper.bg,
    bgDeep: Paper.bgDeep,
    surface: Paper.surface,
    surface2: Paper.surface2,
    surfaceHover: Paper.surfaceHover,
    surfaceSunken: Paper.surfaceSunken,
    line: Paper.line,
    lineStrong: Paper.lineStrong,
    lineControl: Paper.lineControl,
    ink: Paper.ink,
    ink2: Paper.ink2,
    ink3: Paper.ink3,
    ink4: Paper.ink4,
    accent: Paper.accent,
    accentHover: Paper.accentHover,
    accentSoft: Paper.accentSoft,
    accentInk: Paper.accentInk,
    onAccent: Paper.onAccent,
    danger: Paper.danger,
    dangerSoft: Paper.dangerSoft,
    onDanger: Paper.onDanger,
    warn: Paper.warn,
    warnSoft: Paper.warnSoft,
    ok: Paper.ok,
    okSoft: Paper.okSoft,
    info: Paper.info,
    infoSoft: Paper.infoSoft,
    frame: Paper.frame,
    frame2: Paper.frame2,
    frame3: Paper.frame3,
    frameLine: Paper.frameLine,
    frameInk: Paper.frameInk,
    frameInk2: Paper.frameInk2,
    frameInk3: Paper.frameInk3,
    frameAccent: Paper.frameAccent,
    frameAccentSoft: Paper.frameAccentSoft,
    frameWarm: Paper.frameWarm,
    scrim: Paper.scrim,
    wash: Paper.wash,
    edge: Color(0x00000000),
    isDark: false,
  );

  static const dark = Palette(
    bg: Slate.bg,
    bgDeep: Slate.bgDeep,
    surface: Slate.surface,
    surface2: Slate.surface2,
    surfaceHover: Slate.surfaceHover,
    surfaceSunken: Slate.surfaceSunken,
    line: Slate.line,
    lineStrong: Slate.lineStrong,
    lineControl: Slate.lineControl,
    ink: Slate.ink,
    ink2: Slate.ink2,
    ink3: Slate.ink3,
    ink4: Slate.ink4,
    accent: Slate.accent,
    accentHover: Slate.accentHover,
    accentSoft: Slate.accentSoft,
    accentInk: Slate.accentInk,
    onAccent: Slate.onAccent,
    danger: Slate.danger,
    dangerSoft: Slate.dangerSoft,
    onDanger: Slate.onDanger,
    warn: Slate.warn,
    warnSoft: Slate.warnSoft,
    ok: Slate.ok,
    okSoft: Slate.okSoft,
    info: Slate.info,
    infoSoft: Slate.infoSoft,
    frame: Slate.frame,
    frame2: Slate.frame2,
    frame3: Slate.frame3,
    frameLine: Slate.frameLine,
    frameInk: Slate.frameInk,
    frameInk2: Slate.frameInk2,
    frameInk3: Slate.frameInk3,
    frameAccent: Slate.frameAccent,
    frameAccentSoft: Slate.frameAccentSoft,
    frameWarm: Slate.frameWarm,
    scrim: Slate.scrim,
    wash: Slate.wash,
    edge: Slate.edge,
    isDark: true,
  );

  @override
  Palette copyWith({
    Color? bg, Color? bgDeep, Color? surface, Color? surface2,
    Color? surfaceHover, Color? surfaceSunken, Color? line, Color? lineStrong,
    Color? lineControl, Color? ink, Color? ink2, Color? ink3, Color? ink4,
    Color? accent, Color? accentHover, Color? accentSoft, Color? accentInk,
    Color? onAccent, Color? danger, Color? dangerSoft, Color? onDanger,
    Color? warn, Color? warnSoft, Color? ok, Color? okSoft, Color? info,
    Color? infoSoft, Color? frame, Color? frame2, Color? frame3,
    Color? frameLine, Color? frameInk, Color? frameInk2, Color? frameInk3,
    Color? frameAccent, Color? frameAccentSoft, Color? frameWarm,
    Color? scrim, Color? wash, Color? edge, bool? isDark,
  }) {
    return Palette(
      bg: bg ?? this.bg,
      bgDeep: bgDeep ?? this.bgDeep,
      surface: surface ?? this.surface,
      surface2: surface2 ?? this.surface2,
      surfaceHover: surfaceHover ?? this.surfaceHover,
      surfaceSunken: surfaceSunken ?? this.surfaceSunken,
      line: line ?? this.line,
      lineStrong: lineStrong ?? this.lineStrong,
      lineControl: lineControl ?? this.lineControl,
      ink: ink ?? this.ink,
      ink2: ink2 ?? this.ink2,
      ink3: ink3 ?? this.ink3,
      ink4: ink4 ?? this.ink4,
      accent: accent ?? this.accent,
      accentHover: accentHover ?? this.accentHover,
      accentSoft: accentSoft ?? this.accentSoft,
      accentInk: accentInk ?? this.accentInk,
      onAccent: onAccent ?? this.onAccent,
      danger: danger ?? this.danger,
      dangerSoft: dangerSoft ?? this.dangerSoft,
      onDanger: onDanger ?? this.onDanger,
      warn: warn ?? this.warn,
      warnSoft: warnSoft ?? this.warnSoft,
      ok: ok ?? this.ok,
      okSoft: okSoft ?? this.okSoft,
      info: info ?? this.info,
      infoSoft: infoSoft ?? this.infoSoft,
      frame: frame ?? this.frame,
      frame2: frame2 ?? this.frame2,
      frame3: frame3 ?? this.frame3,
      frameLine: frameLine ?? this.frameLine,
      frameInk: frameInk ?? this.frameInk,
      frameInk2: frameInk2 ?? this.frameInk2,
      frameInk3: frameInk3 ?? this.frameInk3,
      frameAccent: frameAccent ?? this.frameAccent,
      frameAccentSoft: frameAccentSoft ?? this.frameAccentSoft,
      frameWarm: frameWarm ?? this.frameWarm,
      scrim: scrim ?? this.scrim,
      wash: wash ?? this.wash,
      edge: edge ?? this.edge,
      isDark: isDark ?? this.isDark,
    );
  }

  @override
  Palette lerp(ThemeExtension<Palette>? other, double t) {
    if (other is! Palette) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    return Palette(
      bg: c(bg, other.bg),
      bgDeep: c(bgDeep, other.bgDeep),
      surface: c(surface, other.surface),
      surface2: c(surface2, other.surface2),
      surfaceHover: c(surfaceHover, other.surfaceHover),
      surfaceSunken: c(surfaceSunken, other.surfaceSunken),
      line: c(line, other.line),
      lineStrong: c(lineStrong, other.lineStrong),
      lineControl: c(lineControl, other.lineControl),
      ink: c(ink, other.ink),
      ink2: c(ink2, other.ink2),
      ink3: c(ink3, other.ink3),
      ink4: c(ink4, other.ink4),
      accent: c(accent, other.accent),
      accentHover: c(accentHover, other.accentHover),
      accentSoft: c(accentSoft, other.accentSoft),
      accentInk: c(accentInk, other.accentInk),
      onAccent: c(onAccent, other.onAccent),
      danger: c(danger, other.danger),
      dangerSoft: c(dangerSoft, other.dangerSoft),
      onDanger: c(onDanger, other.onDanger),
      warn: c(warn, other.warn),
      warnSoft: c(warnSoft, other.warnSoft),
      ok: c(ok, other.ok),
      okSoft: c(okSoft, other.okSoft),
      info: c(info, other.info),
      infoSoft: c(infoSoft, other.infoSoft),
      frame: c(frame, other.frame),
      frame2: c(frame2, other.frame2),
      frame3: c(frame3, other.frame3),
      frameLine: c(frameLine, other.frameLine),
      frameInk: c(frameInk, other.frameInk),
      frameInk2: c(frameInk2, other.frameInk2),
      frameInk3: c(frameInk3, other.frameInk3),
      frameAccent: c(frameAccent, other.frameAccent),
      frameAccentSoft: c(frameAccentSoft, other.frameAccentSoft),
      frameWarm: c(frameWarm, other.frameWarm),
      scrim: c(scrim, other.scrim),
      wash: c(wash, other.wash),
      edge: c(edge, other.edge),
      isDark: t < 0.5 ? isDark : other.isDark,
    );
  }

  /// Read the palette without threading a BuildContext through every helper.
  static Palette of(BuildContext context) =>
      Theme.of(context).extension<Palette>() ?? light;
}

/// ---------------------------------------------------------------------------
/// Spacing — one 4px grid, no exceptions.
/// ---------------------------------------------------------------------------
abstract final class Sp {
  static const x1 = 4.0;
  static const x2 = 8.0;
  static const x3 = 12.0;
  static const x4 = 16.0;
  static const x5 = 20.0;
  static const x6 = 24.0;
  static const x7 = 28.0;
  static const x8 = 32.0;
  static const x10 = 40.0;
  static const x12 = 48.0;
  static const x16 = 64.0;
}

/// ---------------------------------------------------------------------------
/// Radii — one per level, concentric.
/// ---------------------------------------------------------------------------
abstract final class R {
  static const x2xs = 2.0;
  static const xs = 3.0;
  static const sm = 4.0;
  static const md = 6.0;
  static const lg = 8.0;
  static const xl = 10.0;
  static const full = 999.0;

  static const border2xs = BorderRadius.all(Radius.circular(x2xs));
  static const borderXs = BorderRadius.all(Radius.circular(xs));
  static const borderSm = BorderRadius.all(Radius.circular(sm));
  static const borderMd = BorderRadius.all(Radius.circular(md));
  static const borderLg = BorderRadius.all(Radius.circular(lg));
  static const borderXl = BorderRadius.all(Radius.circular(xl));
}

/// ---------------------------------------------------------------------------
/// Elevation. Only for things that float over the page — a card sits on the
/// page with a hairline, it does not hover above it.
/// ---------------------------------------------------------------------------
abstract final class Shadows {
  static const overlay = <BoxShadow>[
    BoxShadow(
      color: Color(0x47141A16),
      offset: Offset(0, 16),
      blurRadius: 40,
      spreadRadius: -16,
    ),
    BoxShadow(color: Color(0x14141A16), offset: Offset(0, 2), blurRadius: 8),
  ];

  static const pop = <BoxShadow>[
    BoxShadow(
      color: Color(0x3D141A16),
      offset: Offset(0, 6),
      blurRadius: 18,
      spreadRadius: -8,
    ),
  ];

  static const overlayDark = <BoxShadow>[
    BoxShadow(
      color: Color(0xCC000000),
      offset: Offset(0, 18),
      blurRadius: 44,
      spreadRadius: -18,
    ),
    BoxShadow(color: Color(0x80000000), offset: Offset(0, 2), blurRadius: 10),
  ];

  static const popDark = <BoxShadow>[
    BoxShadow(
      color: Color(0xB3000000),
      offset: Offset(0, 8),
      blurRadius: 20,
      spreadRadius: -8,
    ),
  ];

  static const tabbar = <BoxShadow>[
    BoxShadow(color: Color(0x08141A16), offset: Offset(0, -1), blurRadius: 0),
    BoxShadow(
      color: Color(0x38141A16),
      offset: Offset(0, -6),
      blurRadius: 20,
      spreadRadius: -12,
    ),
  ];

  static const tabbarDark = <BoxShadow>[
    BoxShadow(color: Color(0x66000000), offset: Offset(0, -1), blurRadius: 0),
    BoxShadow(
      color: Color(0xCC000000),
      offset: Offset(0, -6),
      blurRadius: 20,
      spreadRadius: -12,
    ),
  ];

  static List<BoxShadow> overlayFor(bool isDark) => isDark ? overlayDark : overlay;
  static List<BoxShadow> popFor(bool isDark) => isDark ? popDark : pop;
  static List<BoxShadow> tabbarFor(bool isDark) => isDark ? tabbarDark : tabbar;
}

/// ---------------------------------------------------------------------------
/// Motion. Arrivals decelerate, exits accelerate, nothing overshoots.
/// ---------------------------------------------------------------------------
abstract final class Motion {
  static const ease = Cubic(0.22, 0.61, 0.36, 1);
  static const easeOut = Cubic(0.16, 1, 0.3, 1);
  static const easeIn = Cubic(0.4, 0, 0.7, 0.2);
  static const easeTurn = Cubic(0.32, 0.72, 0.4, 1);

  static const dur1 = Duration(milliseconds: 120);
  static const dur2 = Duration(milliseconds: 180);
  static const dur3 = Duration(milliseconds: 260);
  static const dur4 = Duration(milliseconds: 420);
  static const dur5 = Duration(milliseconds: 620);

  static const stagger = Duration(milliseconds: 16);
}

/// ---------------------------------------------------------------------------
/// Layout constants.
/// ---------------------------------------------------------------------------
abstract final class Layout {
  static const sidebarW = 232.0;
  static const sidebarRailW = 64.0;
  static const contentMax = 1180.0;
  static const controlH = 36.0;
  static const controlHSm = 32.0;

  /// The window title bar. 36px keeps the caption buttons on the same rhythm
  /// as every other control.
  static const frameBarH = 36.0;

  /// Minimum touch target on a phone.
  static const tap = 44.0;

  /// Breakpoints, matching the media queries in the web build.
  static const railBreakpoint = 1000.0;
  static const mobileBreakpoint = 720.0;
}

/// ---------------------------------------------------------------------------
/// The type scale. Ratio 1.2 on a 15px body, fixed rather than fluid: this is a
/// tool, and a heading that resizes with the window is a marketing habit.
/// ---------------------------------------------------------------------------
abstract final class Fs {
  static const xs = 12.0;
  static const sm = 13.0;
  static const base = 15.0;
  static const md = 16.0;
  static const lg = 19.0;
  static const xl = 24.0;
  static const x2xl = 30.0;
  static const x3xl = 38.0;
}

/// Line heights. Above 1.2 is for reading; below it is for display type, where
/// the line box should hug the glyphs.
abstract final class Lh {
  static const none = 1.0;
  static const display = 1.05;
  static const title = 1.15;
  static const tight = 1.2;
  static const snug = 1.4;
  static const body = 1.6;
  static const loose = 1.7;
}

/// ---------------------------------------------------------------------------
/// Font families.
///
/// The web build used IBM Plex Sans / Serif / Mono from a webfont. Offline and
/// on mobile that bundle is not free, so the Flutter port names the same three
/// roles and lets the platform supply the glyphs: the family lists fall through
/// to the system face, which is what the CSS did for Chinese anyway.
/// ---------------------------------------------------------------------------
abstract final class Fonts {
  /// Interface text. Falls through to the system UI face for CJK.
  static const ui = 'IBM Plex Sans';

  /// The word being learned — the app's voice is serif.
  static const display = 'IBM Plex Serif';

  /// Figures and keycaps.
  static const mono = 'IBM Plex Mono';

  /// Present so `fontFamilyFallback` can be written once.
  static const cjkFallback = <String>[
    'PingFang SC',
    'Hiragino Sans GB',
    'Microsoft YaHei UI',
    'Microsoft YaHei',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Source Han Sans SC',
  ];
}
