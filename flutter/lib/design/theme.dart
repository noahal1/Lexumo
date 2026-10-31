/// Builds the two `ThemeData` objects from `tokens.dart`.
library;

import 'package:flutter/material.dart';

import 'tokens.dart';

/// IBM Plex is not bundled with the app, so every text style names the family
/// that would be used *if* the asset were present and falls back to the system
/// face. That keeps one switch to flip once the fonts ship (see
/// `docs/flutter-design.md`), and it means the port renders identically on a
/// machine that has Plex installed and one that does not.
TextStyle _style({
  required double size,
  required Color color,
  double height = Lh.snug,
  FontWeight weight = FontWeight.w400,
  String? family,
  double? letterSpacing,
}) {
  return TextStyle(
    fontSize: size,
    color: color,
    height: height,
    fontWeight: weight,
    fontFamily: family,
    fontFamilyFallback: Fonts.cjkFallback,
    letterSpacing: letterSpacing,
  );
}

ThemeData buildTheme(Palette p) {
  final scheme = ColorScheme(
    brightness: p.isDark ? Brightness.dark : Brightness.light,
    primary: p.accent,
    onPrimary: p.onAccent,
    primaryContainer: p.accentSoft,
    onPrimaryContainer: p.accentInk,
    secondary: p.info,
    onSecondary: p.onAccent,
    error: p.danger,
    onError: p.onDanger,
    errorContainer: p.dangerSoft,
    onErrorContainer: p.danger,
    surface: p.bg,
    onSurface: p.ink,
    surfaceContainerLowest: p.bgDeep,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface2,
    surfaceContainerHigh: p.surfaceHover,
    surfaceContainerHighest: p.surfaceSunken,
    onSurfaceVariant: p.ink3,
    outline: p.line,
    outlineVariant: p.lineStrong,
    scrim: p.scrim,
    inverseSurface: p.frame,
    onInverseSurface: p.frameInk,
  );

  final text = TextTheme(
    // Display type: the headword, the page title.
    displayLarge: _style(
      size: Fs.x3xl,
      color: p.ink,
      height: Lh.display,
      weight: FontWeight.w600,
      family: Fonts.display,
    ),
    displayMedium: _style(
      size: Fs.x2xl,
      color: p.ink,
      height: Lh.title,
      weight: FontWeight.w600,
      family: Fonts.display,
    ),
    displaySmall: _style(
      size: Fs.xl,
      color: p.ink,
      height: Lh.title,
      weight: FontWeight.w600,
      family: Fonts.display,
    ),
    headlineMedium: _style(
      size: Fs.lg,
      color: p.ink,
      height: Lh.title,
      weight: FontWeight.w600,
    ),
    headlineSmall: _style(
      size: Fs.md,
      color: p.ink,
      height: Lh.tight,
      weight: FontWeight.w600,
    ),
    titleLarge: _style(
      size: Fs.md,
      color: p.ink,
      height: Lh.tight,
      weight: FontWeight.w600,
    ),
    titleMedium: _style(
      size: Fs.base,
      color: p.ink,
      height: Lh.tight,
      weight: FontWeight.w600,
    ),
    titleSmall: _style(
      size: Fs.sm,
      color: p.ink2,
      height: Lh.tight,
      weight: FontWeight.w600,
    ),
    bodyLarge: _style(size: Fs.md, color: p.ink, height: Lh.body),
    bodyMedium: _style(size: Fs.base, color: p.ink, height: Lh.body),
    bodySmall: _style(size: Fs.sm, color: p.ink2, height: Lh.body),
    labelLarge: _style(
      size: Fs.base,
      color: p.ink,
      height: Lh.tight,
      weight: FontWeight.w600,
    ),
    labelMedium: _style(
      size: Fs.sm,
      color: p.ink2,
      height: Lh.tight,
      weight: FontWeight.w500,
    ),
    labelSmall: _style(
      size: Fs.xs,
      color: p.ink3,
      height: Lh.tight,
      weight: FontWeight.w500,
      letterSpacing: 0.04,
    ),
  );

  return ThemeData(
    useMaterial3: true,
    brightness: p.isDark ? Brightness.dark : Brightness.light,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    dividerColor: p.line,
    fontFamily: Fonts.ui,
    fontFamilyFallback: Fonts.cjkFallback,
    textTheme: text,
    extensions: <ThemeExtension<dynamic>>[p],
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: p.surfaceHover,
    visualDensity: VisualDensity.standard,

    // A hairline everywhere: the app has no Material elevation language.
    dividerTheme: DividerThemeData(color: p.line, thickness: 1, space: 1),

    // The web build drew its own scrollbars in the page's ink at low opacity.
    scrollbarTheme: ScrollbarThemeData(
      thumbColor: WidgetStatePropertyAll(p.ink4.withValues(alpha: 0.45)),
      thickness: const WidgetStatePropertyAll(6),
      radius: const Radius.circular(R.full),
    ),

    tooltipTheme: TooltipThemeData(
      decoration: BoxDecoration(
        color: p.frame2,
        borderRadius: R.borderSm,
        border: Border.all(color: p.frameLine),
      ),
      textStyle: _style(size: Fs.xs, color: p.frameInk, height: Lh.tight),
      waitDuration: const Duration(milliseconds: 420),
    ),

    // Dialogs float, so they get the one real elevation.
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: R.borderLg,
        side: BorderSide(color: p.line),
      ),
      titleTextStyle: _style(
        size: Fs.lg,
        color: p.ink,
        height: Lh.title,
        weight: FontWeight.w600,
        family: Fonts.display,
      ),
    ),

    textSelectionTheme: TextSelectionThemeData(
      cursorColor: p.accent,
      selectionColor: p.accentSoft,
      selectionHandleColor: p.accent,
    ),

    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: Sp.x3,
        vertical: Sp.x2 + 2,
      ),
      hintStyle: _style(size: Fs.base, color: p.ink4, height: Lh.body),
      labelStyle: _style(size: Fs.sm, color: p.ink3, height: Lh.tight),
      border: OutlineInputBorder(
        borderRadius: R.borderMd,
        borderSide: BorderSide(color: p.lineControl),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: R.borderMd,
        borderSide: BorderSide(color: p.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: R.borderMd,
        borderSide: BorderSide(color: p.accent, width: 1.5),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: R.borderMd,
        borderSide: BorderSide(color: p.danger),
      ),
    ),

    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.onAccent : p.ink3,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.surfaceSunken,
      ),
      trackOutlineColor: WidgetStateProperty.resolveWith(
        (s) => s.contains(WidgetState.selected) ? p.accent : p.lineControl,
      ),
    ),

    sliderTheme: SliderThemeData(
      activeTrackColor: p.accent,
      inactiveTrackColor: p.line,
      thumbColor: p.accent,
      overlayColor: p.accentSoft,
      trackHeight: 3,
    ),

    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.accent,
      linearTrackColor: p.surfaceSunken,
      circularTrackColor: p.surfaceSunken,
    ),
  );
}
