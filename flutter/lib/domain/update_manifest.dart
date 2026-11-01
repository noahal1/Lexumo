/// The update manifest: what a release advertises, and what this build makes
/// of it.
///
/// One JSON document describes the newest release. It is fetched over the same
/// `HttpClient` the sync engine uses and parsed by [ReleaseManifest.fromJson],
/// which is written to survive a hostile document — every field is optional,
/// every wrong type is a null rather than a throw, and a manifest missing the
/// two fields that matter (version, apk) is rejected whole. A single bad field
/// must never blank the update check: the worst acceptable outcome is "there is
/// no update", which is also what an offline phone sees.
///
/// Shape:
///
/// ```json
/// {
///   "version": "0.2.0",
///   "build": 2,
///   "published": "2026-11-02T10:00:00Z",
///   "minSupportedBuild": 1,
///   "notes": { "zh": "…", "en": "…" },
///   "apk": {
///     "url": "https://github.com/noahal1/Lexumo/releases/download/v0.2.0/lexumo-0.2.0.apk",
///     "size": 20462854,
///     "sha256": "…64 hex…"
///   }
/// }
/// ```
///
/// Why `sha256` is required rather than optional: an APK downloaded over the
/// network is executed with the user's full permissions once installed. Android
/// will verify the signature at install time, but it verifies it against
/// whatever certificate the file carries — the wrong file is refused only after
/// the installer has already been opened, and a downgrade attempt shows the
/// user a bare `INSTALL_FAILED_UPDATE_INCOMPATIBLE`. A digest check before the
/// installer is opened turns both into a plain sentence the app can write.
library;

import 'dart:convert';

import '../domain/version.dart';

/// Where an APK can be downloaded, and how to prove it arrived intact.
class ApkArtifact {
  const ApkArtifact({
    required this.url,
    required this.bytes,
    required this.sha256,
  });

  final Uri url;

  /// Size in bytes, when the release advertises one. Used to decide whether a
  /// download is even worth starting (and whether free space allows it), never
  /// as the integrity check — that is [sha256].
  final int? bytes;

  /// Lowercase hex of the SHA-256 digest.
  final String sha256;

  static ApkArtifact? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final url = _uri(raw['url']);
    final sha = _hex(raw['sha256'], 64);
    if (url == null || sha == null) return null;
    // Only https is accepted. `http` would let anything on the path swap the
    // payload, and the digest in the same manifest cannot help — an attacker
    // who controls the transport controls the manifest too.
    if (url.scheme != 'https') return null;
    final size = _positiveInt(raw['size']);
    return ApkArtifact(url: url, bytes: size, sha256: sha);
  }

  static Uri? _uri(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    final parsed = Uri.tryParse(raw);
    if (parsed == null || !parsed.hasAuthority) return null;
    return parsed;
  }

  static int? _positiveInt(Object? raw) => switch (raw) {
        final int v => v > 0 ? v : null,
        final num v when v > 0 => v.toInt(),
        final String v => switch (int.tryParse(v.trim())) {
            final int n when n > 0 => n,
            _ => null,
          },
        _ => null,
      };

  static String? _hex(Object? raw, int length) {
    if (raw is! String) return null;
    final text = raw.trim().toLowerCase();
    if (text.length != length) return null;
    for (final unit in text.codeUnits) {
      final isDigit = unit >= 0x30 && unit <= 0x39;
      final isLower = unit >= 0x61 && unit <= 0x66;
      if (!isDigit && !isLower) return null;
    }
    return text;
  }
}

/// A release as advertised by the manifest.
class ReleaseManifest {
  const ReleaseManifest({
    required this.version,
    required this.apk,
    this.notes = const <String, String>{},
    this.published,
    this.minSupportedBuild,
  });

  final ReleaseVersion version;
  final ApkArtifact apk;

  /// Release notes keyed by UI language (`zh`, `en`). A missing key is normal:
  /// see [notesFor].
  final Map<String, String> notes;

  /// When the release was published, when the manifest says. Display only.
  final DateTime? published;

  /// The oldest build number still able to use this app.
  ///
  /// Anything at or above it gets the ordinary "an update is available" offer;
  /// anything below it is told the update is required. Kept optional because
  /// most releases do not raise the floor, and a manifest that always named a
  /// floor would turn every release into a forced one.
  final int? minSupportedBuild;

  /// Parse [raw], or `null` when the document is not a usable manifest.
  ///
  /// [raw] may be the decoded JSON value or the JSON text itself; `null` and
  /// malformed text both return `null` rather than throwing, because this runs
  /// inside a background check whose only failure mode should be silence.
  static ReleaseManifest? parse(Object? raw) {
    Object? decoded = raw;
    if (decoded is String) {
      try {
        decoded = jsonDecode(decoded);
      } catch (_) {
        return null;
      }
    }
    if (decoded is! Map) return null;

    final versionField = decoded['version'];
    final version = ReleaseVersion.tryParse(
      name: versionField is String ? versionField : null,
      build: decoded['build'],
    );
    final apk = ApkArtifact.fromJson(decoded['apk']);
    if (version == null || apk == null) return null;

    return ReleaseManifest(
      version: version,
      apk: apk,
      notes: _notes(decoded['notes']),
      published: _date(decoded['published']),
      minSupportedBuild: _positiveIntOrNull(decoded['minSupportedBuild']),
    );
  }

  static Map<String, String> _notes(Object? raw) {
    if (raw is! Map) return const <String, String>{};
    final out = <String, String>{};
    raw.forEach((key, value) {
      if (key is String && key.isNotEmpty && value is String) {
        final text = value.trim();
        if (text.isNotEmpty) out[key.toLowerCase()] = text;
      }
    });
    return out;
  }

  static DateTime? _date(Object? raw) =>
      raw is String ? DateTime.tryParse(raw)?.toUtc() : null;

  static int? _positiveIntOrNull(Object? raw) => switch (raw) {
        final int v when v >= 1 => v,
        final num v when v >= 1 => v.toInt(),
        final String v => switch (int.tryParse(v.trim())) {
            final int n when n >= 1 => n,
            _ => null,
          },
        _ => null,
      };

  /// The notes for [lang], falling back to `zh` and then to any available entry.
  ///
  /// Same fallback order as `I18n`: the Chinese dictionary is the reference, so
  /// a release that only wrote Chinese notes still says something in English
  /// rather than an empty panel.
  String? notesFor(String lang) {
    if (notes.isEmpty) return null;
    final key = lang.toLowerCase();
    final exact = notes[key];
    if (exact != null) return exact;
    // `zh-CN`/`zh_TW` should both find `zh`.
    for (final entry in notes.entries) {
      if (key.startsWith(entry.key)) return entry.value;
    }
    final reference = notes['zh'];
    if (reference != null) return reference;
    return notes.values.first;
  }

  /// Whether [current] is below the floor this manifest declares.
  bool isRequiredFor(ReleaseVersion current) {
    final floor = minSupportedBuild;
    if (floor == null) return false;
    return current.build < floor;
  }
}

/// The outcome of one update check, in the terms the UI needs.
///
/// Four states, not three: [unsupported] exists because a desktop build has no
/// Play Store equivalent to fall back on and no in-app installer either — the
/// settings row has to say something different from "you are up to date".
sealed class UpdateCheck {
  const UpdateCheck();
}

/// This build is the newest, or the manifest is unusable — either way there is
/// nothing to offer. [reason] exists for the settings row's second line and is
/// never shown as an error.
class UpdateUpToDate extends UpdateCheck {
  const UpdateUpToDate({this.current});

  final ReleaseVersion? current;
}

/// A newer release exists.
class UpdateAvailable extends UpdateCheck {
  const UpdateAvailable({
    required this.current,
    required this.manifest,
    required this.required,
  });

  final ReleaseVersion current;
  final ReleaseManifest manifest;

  /// The release below the manifest's floor: the update is not optional.
  final bool required;

  /// Versions to show in the sheet's title, e.g. `0.2.0`.
  String get target => manifest.version.name.toString();
}

/// The check could not be completed. [reason] is a wire code, translated by the
/// page, so a network error and a broken manifest stay distinguishable.
class UpdateFailed extends UpdateCheck {
  const UpdateFailed(this.reason);

  /// `offline`, `server`, `manifest` or `unsupported`.
  final String reason;
}

/// This platform has no in-app update path.
class UpdateUnsupported extends UpdateCheck {
  const UpdateUnsupported(this.current);

  final ReleaseVersion? current;
}
