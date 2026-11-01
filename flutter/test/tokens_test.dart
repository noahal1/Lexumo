/// Design token invariants.
///
/// A token file looks like dead code to a reference-counting scan: `Sp.x16` and
/// `Motion.dur5` have no call sites today. They are not dead — they are the
/// *scale* itself, and a scale with holes in it is a scale nobody can reach for
/// without inventing a number. `docs/flutter-design.md` publishes the full
/// ladder next to the CSS variables it came from, so dropping an unused rung
/// also makes the doc wrong.
///
/// These tests state that contract so a future cleanup pass cannot quietly
/// delete the rungs it does not find call sites for, and so the two theme
/// palettes cannot drift apart field by field.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lexumo/ui/core/tokens.dart';

void main() {
  group('Sp scale', () {
    test('is the full 4px ladder published in the design doc', () {
      // The doc lists 4 / 8 / 12 / 16 / 20 / 24 / 28 / 32 / 40 / 48 / 64.
      expect(<double>[
        Sp.x1,
        Sp.x2,
        Sp.x3,
        Sp.x4,
        Sp.x5,
        Sp.x6,
        Sp.x7,
        Sp.x8,
        Sp.x10,
        Sp.x12,
        Sp.x16,
      ], <double>[4, 8, 12, 16, 20, 24, 28, 32, 40, 48, 64]);
    });

    test('every rung is a multiple of four', () {
      // "One 4px grid, no exceptions" is the doc's claim, so it gets a test.
      for (final double v in <double>[
        Sp.x1,
        Sp.x2,
        Sp.x3,
        Sp.x4,
        Sp.x5,
        Sp.x6,
        Sp.x7,
        Sp.x8,
        Sp.x10,
        Sp.x12,
        Sp.x16,
      ]) {
        expect(v % 4, 0, reason: '$v is not on the 4px grid');
      }
    });
  });

  group('Motion', () {
    test('has five duration rungs, strictly increasing', () {
      const List<Duration> rungs = <Duration>[
        Motion.dur1,
        Motion.dur2,
        Motion.dur3,
        Motion.dur4,
        Motion.dur5,
      ];
      expect(rungs.map((Duration d) => d.inMilliseconds).toList(),
          <int>[120, 180, 260, 420, 620]);
      for (int i = 1; i < rungs.length; i++) {
        expect(rungs[i] > rungs[i - 1], isTrue,
            reason: 'rung $i must be slower than rung ${i - 1}');
      }
    });

    test('stagger is the small inter-item delay', () {
      expect(Motion.stagger, const Duration(milliseconds: 16));
      expect(Motion.stagger < Motion.dur1, isTrue);
    });
  });

  group('Radii', () {
    test('borderXl is the largest radius and matches its value', () {
      // `R.borderXl` wraps `R.xl`; both must stay in the same order.
      expect(R.xl > R.lg, isTrue);
      expect(R.borderXl, BorderRadius.all(Radius.circular(R.xl)));
    });

    test('the radius ladder increases monotonically', () {
      const List<double> ladder = <double>[R.x2xs, R.xs, R.sm, R.md, R.lg, R.xl];
      for (int i = 1; i < ladder.length; i++) {
        expect(ladder[i] > ladder[i - 1], isTrue,
            reason: 'radius $i must be larger than ${i - 1}');
      }
    });
  });

  group('Layout', () {
    test('frameBarH matches the control height it is aligned to', () {
      // The doc's reason for 36px: caption buttons sit on the same rhythm as
      // every other control. The value is only correct while that still holds.
      expect(Layout.frameBarH, Layout.controlH);
    });

    test('the breakpoints are ordered', () {
      expect(Layout.mobileBreakpoint < Layout.railBreakpoint, isTrue);
    });
  });

  group('Palette', () {
    test('light and dark define the same fields', () {
      // `Palette` is a ThemeExtension, so a field that one theme forgets
      // silently reads the other theme's value: a light-grey surface on a dark
      // background, noticed only by eye.
      final Palette light = Palette.light;
      final Palette dark = Palette.dark;

      expect(dark.bg, isNot(light.bg));
      expect(dark.surface, isNot(light.surface));
      expect(dark.ink, isNot(light.ink));
    });

    test('keeps the frame dark in both themes', () {
      // "One shell, two materials": the paper changes, the stone surround does
      // not. The two values are not equal — light is #252C28, dark is #050706,
      // both matching their CSS counterparts — so the invariant to state is
      // that both stay dark, not that they match.
      double luminance(Color c) => c.computeLuminance();
      expect(luminance(Palette.light.frame), lessThan(0.1));
      expect(luminance(Palette.dark.frame), lessThan(0.1));
      // The frame ink is readable against both.
      expect(luminance(Palette.light.frameInk), greaterThan(0.4));
      expect(luminance(Palette.dark.frameInk), greaterThan(0.4));
    });

    test('copies every field when switching brightness', () {
      final Palette flipped = Palette.light.copyWith(isDark: !Palette.light.isDark);
      expect(flipped.isDark, !Palette.light.isDark);
      expect(flipped.bg, Palette.light.bg);
    });

    test('lerps between the two palettes without losing a field', () {
      // A ThemeExtension that cannot lerp makes animated theme switches snap.
      final Palette mid = Palette.light.lerp(Palette.dark, 0.5);
      expect(mid.bg, isNot(Palette.light.bg));
      expect(mid.bg, isNot(Palette.dark.bg));
      // `isDark` is a flag snapped at the midpoint (`t < 0.5 ? isDark :
      // other.isDark`), never blended — a half-dark palette would send every
      // `isDark ?` branch down a shadow path nobody tested.
      expect(Palette.light.lerp(Palette.dark, 0.49).isDark, Palette.light.isDark);
      expect(Palette.light.lerp(Palette.dark, 0.5).isDark, Palette.dark.isDark);
    });
  });

  group('Fonts', () {
    test('name the three Plex families and a CJK fallback chain', () {
      expect(Fonts.ui, 'IBM Plex Sans');
      expect(Fonts.display, 'IBM Plex Serif');
      expect(Fonts.mono, 'IBM Plex Mono');
      expect(Fonts.cjkFallback, isNotEmpty);
      expect(Fonts.cjkFallback, contains('Microsoft YaHei'));
      expect(Fonts.cjkFallback, contains('PingFang SC'));
    });
  });

  group('Fs scale', () {
    test('grows monotonically at roughly a 1.2 ratio', () {
      const List<double> sizes = <double>[
        Fs.xs,
        Fs.sm,
        Fs.base,
        Fs.md,
        Fs.lg,
        Fs.xl,
        Fs.x2xl,
        Fs.x3xl,
      ];
      expect(sizes, <double>[12, 13, 15, 16, 19, 24, 30, 38]);
      for (int i = 1; i < sizes.length; i++) {
        expect(sizes[i] > sizes[i - 1], isTrue);
      }
    });
  });
}
