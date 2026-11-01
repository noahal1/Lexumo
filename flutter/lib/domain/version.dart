/// Version numbers, as the update check needs them: parse, compare, display.
///
/// The app carries two numbers and they answer different questions:
///
///   · `versionName` — `0.2.0`. What a person reads in the About card.
///   · `build` — `2`. What Android compares when deciding whether one APK may
///     replace another. Monotonic, never displayed.
///
/// Both come from `pubspec.yaml`'s `version: 0.2.0+2`, which is why the update
/// decision reads the build number and *not* the name: `flutter.versionCode`
/// and `flutter.versionName` are both derived from that one line at build time,
/// so they cannot disagree, and the build number is the one the platform
/// enforces.
///
/// Comparing display names is not an option, and this is the reason the class
/// below exists rather than a `String.compareTo`: lexicographically `"0.10.0"`
/// sorts *before* `"0.9.0"`, so a string comparison would tell every user of
/// 0.10 that 0.9 is the newer release. The build number alone would be enough
/// to *decide*, but the release notes need to say which version is newer, and
/// that comparison has to be correct too.
library;

/// A parsed `MAJOR.MINOR.PATCH[-PRERELEASE]` version, ordered per SemVer 2.0.
///
/// Build metadata (`+` in SemVer) is deliberately not part of this type: the
/// `+N` in a Flutter `version:` line is the build number, not build metadata,
/// and it lives on [ReleaseVersion] instead. Two versions differing only in
/// build metadata are equal by definition, so accepting it here would create a
/// field that must be ignored — an invitation to depend on it.
class SemVer implements Comparable<SemVer> {
  const SemVer(this.major, this.minor, this.patch, {this.preRelease = ''});

  final int major;
  final int minor;
  final int patch;

  /// The dot-separated pre-release identifiers, without the leading `-`.
  /// Empty for a release.
  final String preRelease;

  bool get isPreRelease => preRelease.isNotEmpty;

  /// Parse [raw], or `null` when it is not a version.
  ///
  /// Returning null rather than throwing is the contract the update check
  /// wants: a manifest from the network is untrusted input, and "this is not a
  /// version" has to be a normal branch, not an exception that unwinds through
  /// a download loop.
  ///
  /// Leading `v` is accepted because release tags are conventionally `v0.2.0`
  /// while the application id is not; insisting on one spelling would put a
  /// strip-the-prefix step in every caller.
  static SemVer? tryParse(String? raw) {
    if (raw == null) return null;
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (text.startsWith('v') || text.startsWith('V')) text = text.substring(1);

    // Split off the pre-release before splitting on dots: a pre-release may
    // itself contain dots (`1.0.0-rc.1`).
    final dash = text.indexOf('-');
    final core = dash < 0 ? text : text.substring(0, dash);
    final pre = dash < 0 ? '' : text.substring(dash + 1);

    final parts = core.split('.');
    if (parts.length != 3) return null;

    final major = _intOf(parts[0]);
    final minor = _intOf(parts[1]);
    final patch = _intOf(parts[2]);
    if (major == null || minor == null || patch == null) return null;
    if (dash >= 0 && pre.isEmpty) return null; // "1.0.0-" is not a version
    if (pre.isNotEmpty) {
      // An identifier is [0-9A-Za-z-]+ and may not be empty, so "1.0.0-rc..1"
      // is malformed rather than merely unusual.
      for (final id in pre.split('.')) {
        if (id.isEmpty) return null;
        if (!_identifier.hasMatch(id)) return null;
      }
    }

    return SemVer(major, minor, patch, preRelease: pre);
  }

  static final RegExp _identifier = RegExp(r'^[0-9A-Za-z-]+$');

  static int? _intOf(String text) {
    // `int.tryParse` accepts a leading `+`/`-`; a version component may not be
    // signed, so reject those before parsing rather than after.
    if (text.isEmpty) return null;
    for (final unit in text.codeUnits) {
      if (unit < 0x30 || unit > 0x39) return null;
    }
    return int.tryParse(text);
  }

  @override
  int compareTo(SemVer other) {
    if (major != other.major) return major.compareTo(other.major);
    if (minor != other.minor) return minor.compareTo(other.minor);
    if (patch != other.patch) return patch.compareTo(other.patch);

    // SemVer 2.0 §11.3: a pre-release sorts *before* the release it leads up
    // to, so `0.2.0-rc.1 < 0.2.0`. Getting this backwards would offer users a
    // release candidate as an upgrade over the release.
    if (preRelease.isEmpty && other.preRelease.isEmpty) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;

    final a = preRelease.split('.');
    final b = other.preRelease.split('.');
    for (var i = 0; i < a.length && i < b.length; i++) {
      final byId = _compareIdentifier(a[i], b[i]);
      if (byId != 0) return byId;
    }
    // A larger set of identifiers is higher when every shared one is equal.
    return a.length.compareTo(b.length);
  }

  static int _compareIdentifier(String a, String b) {
    final numA = int.tryParse(a);
    final numB = int.tryParse(b);
    if (numA != null && numB != null) return numA.compareTo(numB);
    // §11.4.3: numeric identifiers always sort before alphanumeric ones.
    if (numA != null) return -1;
    if (numB != null) return 1;
    return a.compareTo(b);
  }

  bool operator >(SemVer other) => compareTo(other) > 0;

  bool operator <(SemVer other) => compareTo(other) < 0;

  bool operator >=(SemVer other) => compareTo(other) >= 0;

  bool operator <=(SemVer other) => compareTo(other) <= 0;

  @override
  bool operator ==(Object other) =>
      other is SemVer &&
      other.major == major &&
      other.minor == minor &&
      other.patch == patch &&
      other.preRelease == preRelease;

  @override
  int get hashCode => Object.hash(major, minor, patch, preRelease);

  /// The canonical form, without a leading `v`.
  @override
  String toString() =>
      isPreRelease ? '$major.$minor.$patch-$preRelease' : '$major.$minor.$patch';
}

/// A version name together with the monotonically increasing build number.
///
/// Ordered by build number first, because that is Android's own rule and the
/// one the installer will enforce: an APK whose `versionCode` is not greater
/// than the installed one is rejected (`INSTALL_FAILED_VERSION_DOWNGRADE`).
/// Comparing by name and merely *hoping* the build agrees would produce an
/// offer the device then refuses.
///
/// The name is the tie-breaker, for a case that should not occur — two builds
/// sharing a number — and it decides only which way the difference is reported,
/// never whether an install is attempted.
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion({
    required this.name,
    required this.build,
  });

  /// The display name, already parsed when [semver] is available.
  final SemVer name;
  final int build;

  SemVer get semver => name;

  /// Parse a manifest/`pubspec` pair, or `null` when either is unusable.
  static ReleaseVersion? tryParse({String? name, Object? build}) {
    final parsed = SemVer.tryParse(name);
    final code = switch (build) {
      final int v => v,
      // A JSON decoder produces `int` for whole numbers, so a `num` that is not
      // whole is a document saying something like `"build": 1.9` — refuse it
      // rather than truncate to 1 and install the wrong thing.
      final num v => v == v.roundToDouble() ? v.toInt() : null,
      final String v => int.tryParse(v.trim()),
      _ => null,
    };
    if (parsed == null || code == null || code < 1) return null;
    return ReleaseVersion(name: parsed, build: code);
  }

  /// Whether [candidate] is installable over this one — its build number is
  /// strictly higher.
  ///
  /// Deliberately *not* `compareTo(candidate) < 0`: that would also be true when
  /// only the display name moved, and offering such a release produces an
  /// install Android rejects with `INSTALL_FAILED_VERSION_DOWNGRADE`. The build
  /// number is the platform's own rule, so it alone decides whether an install
  /// is attempted; [compareTo] still orders the two for display.
  ///
  /// Equal builds are not newer either: re-offering the build the user already
  /// runs would make the update sheet appear on every launch and teach people
  /// to dismiss it, which is exactly how a real update gets ignored.
  bool isOlderThan(ReleaseVersion candidate) => build < candidate.build;

  /// Full ordering, used to say *which* version is newer in release notes.
  ///
  /// Build number first (the installer's rule), name second (the reader's).
  @override
  int compareTo(ReleaseVersion other) {
    if (build != other.build) return build.compareTo(other.build);
    return name.compareTo(other.name);
  }

  /// `0.2.0 · 2`, the form the About card shows.
  String get display => '$name · $build';

  @override
  bool operator ==(Object other) =>
      other is ReleaseVersion && other.build == build && other.name == name;

  @override
  int get hashCode => Object.hash(name, build);

  @override
  String toString() => display;
}
