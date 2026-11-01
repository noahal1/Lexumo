// Version numbers: parsing, ordering, and the one comparison that decides
// whether an update is offered.
//
// Three groups, each pinning a mistake that is easy to make:
//
//   1. **Ordering.** `"0.10.0"` sorts *before* `"0.9.0"` as a string, so a
//      lexicographic comparison would tell every user of 0.10 that 0.9 is the
//      newer release. These cases exist so nobody "simplifies" the comparison
//      back to `String.compareTo`.
//   2. **Pre-releases.** SemVer 2.0 §11.3: `0.2.0-rc.1 < 0.2.0`. Getting this
//      backwards offers a release candidate as an upgrade over the release.
//   3. **Build numbers win.** Android rejects an APK whose `versionCode` is not
//      greater than the installed one, so a manifest that bumped only the name
//      must not produce an install the device will refuse.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/domain/version.dart';

void main() {
  group('SemVer.tryParse', () {
    test('reads the three numbers', () {
      final v = SemVer.tryParse('1.2.3')!;
      expect(v.major, 1);
      expect(v.minor, 2);
      expect(v.patch, 3);
      expect(v.preRelease, '');
      expect(v.isPreRelease, isFalse);
      expect(v.toString(), '1.2.3');
    });

    test('accepts a release tag prefix and surrounding space', () {
      expect(SemVer.tryParse('v0.2.0'), const SemVer(0, 2, 0));
      expect(SemVer.tryParse('  V1.0.0 '), const SemVer(1, 0, 0));
    });

    test('keeps pre-release identifiers, dots included', () {
      final v = SemVer.tryParse('1.0.0-rc.1')!;
      expect(v.preRelease, 'rc.1');
      expect(v.isPreRelease, isTrue);
      expect(v.toString(), '1.0.0-rc.1');
    });

    test('refuses what is not a version', () {
      for (final bad in <String?>[
        null,
        '',
        '   ',
        '1.2',
        '1.2.3.4',
        '1.2.x',
        '1.2.-3',
        '1.2.+3',
        '1.0.0-',
        '1.0.0-rc..1',
        '1.0.0-rc 1',
        'one.two.three',
      ]) {
        expect(SemVer.tryParse(bad), isNull, reason: 'accepted "$bad"');
      }
    });

    test('parsing is idempotent through toString', () {
      const raw = '2.10.1-beta.3';
      expect(SemVer.tryParse(SemVer.tryParse(raw).toString()), SemVer.tryParse(raw));
    });
  });

  group('SemVer.compareTo', () {
    int cmp(String a, String b) => SemVer.tryParse(a)!.compareTo(
          SemVer.tryParse(b)!,
        );

    test('compares numerically, not as text', () {
      // The whole reason this class exists.
      expect(cmp('0.10.0', '0.9.0'), greaterThan(0));
      expect(cmp('1.0.0', '1.0.10'), lessThan(0));
      expect(cmp('10.0.0', '9.99.99'), greaterThan(0));
    });

    test('orders by major, then minor, then patch', () {
      expect(cmp('2.0.0', '1.99.99'), greaterThan(0));
      expect(cmp('1.2.0', '1.1.99'), greaterThan(0));
      expect(cmp('1.1.2', '1.1.1'), greaterThan(0));
      expect(cmp('1.1.1', '1.1.1'), 0);
    });

    test('a pre-release sorts before the release it leads to', () {
      expect(cmp('0.2.0-rc.1', '0.2.0'), lessThan(0));
      expect(cmp('0.2.0', '0.2.0-rc.1'), greaterThan(0));
      expect(cmp('0.2.0-alpha', '0.2.0-beta'), lessThan(0));
    });

    test('numeric identifiers sort before alphanumeric ones', () {
      expect(cmp('1.0.0-1', '1.0.0-alpha'), lessThan(0));
      expect(cmp('1.0.0-rc.2', '1.0.0-rc.10'), lessThan(0));
      expect(cmp('1.0.0-rc.1', '1.0.0-rc.1.1'), lessThan(0));
    });

    test('equality and hashing agree', () {
      expect(SemVer.tryParse('1.2.3'), SemVer.tryParse('1.2.3'));
      expect(SemVer.tryParse('1.2.3').hashCode, SemVer.tryParse('1.2.3').hashCode);
      expect(SemVer.tryParse('1.2.3') == SemVer.tryParse('1.2.4'), isFalse);
    });
  });

  group('ReleaseVersion', () {
    test('reads a name plus a build number in the shapes a manifest uses', () {
      final fromInt = ReleaseVersion.tryParse(name: '0.2.0', build: 2)!;
      expect(fromInt.name, const SemVer(0, 2, 0));
      expect(fromInt.build, 2);
      expect(fromInt.display, '0.2.0 · 2');

      // A JSON number arrives as `num`, a query string as `String`.
      expect(ReleaseVersion.tryParse(name: '0.2.0', build: 2.0)!.build, 2);
      expect(ReleaseVersion.tryParse(name: '0.2.0', build: ' 2 ')!.build, 2);
    });

    test('refuses a missing or non-positive build', () {
      for (final bad in <Object?>[null, 0, -1, 'x', 1.9]) {
        expect(
          ReleaseVersion.tryParse(name: '0.2.0', build: bad),
          isNull,
          reason: 'accepted build $bad',
        );
      }
      expect(ReleaseVersion.tryParse(name: 'nope', build: 1), isNull);
    });

    test('the build number decides, because Android compares it', () {
      // Same name, higher build: newer. Android's own rule.
      final a = ReleaseVersion.tryParse(name: '0.2.0', build: 2)!;
      final b = ReleaseVersion.tryParse(name: '0.2.0', build: 3)!;
      expect(a.compareTo(b), lessThan(0));
      expect(a.isOlderThan(b), isTrue);
      expect(b.isOlderThan(a), isFalse);
    });

    test('a bumped name with an unchanged build is not an update', () {
      // This is the manifest bug that must not become an install attempt:
      // different name, same versionCode, and the device answers
      // INSTALL_FAILED_VERSION_DOWNGRADE.
      final current = ReleaseVersion.tryParse(name: '0.1.0', build: 4)!;
      final manifest = ReleaseVersion.tryParse(name: '0.2.0', build: 4)!;
      expect(current.isOlderThan(manifest), isFalse);
      // The name still breaks the tie, so the difference is reported rather
      // than silently ignored.
      expect(current.compareTo(manifest), lessThan(0));
    });

    test('equal versions are not an update', () {
      final a = ReleaseVersion.tryParse(name: '0.2.0', build: 2)!;
      final b = ReleaseVersion.tryParse(name: '0.2.0', build: 2)!;
      expect(a.isOlderThan(b), isFalse);
      expect(a, b);
    });
  });
}
