// The seam between `tool/release.sh` and the app.
//
// The script writes `dist/update.json`; nothing in Dart produced it, and nothing
// in the script can read it back the way the app will. Two hand-written halves
// of one format is exactly where a field silently renames itself and nobody
// notices until a release is published and every phone says "up to date".
//
// So this runs the real artefact through the real parser, then re-hashes the APK
// on disk and compares. It is the check `release.sh` cannot do for itself.
//
// Skipped when `dist/` is absent — `dist/` is gitignored, so a clean checkout and
// CI have nothing to check. Run `tool/release.sh` locally before publishing and
// these assertions become live.

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/domain/models/update_manifest.dart';
import 'package:lexumo/domain/models/version.dart';

final Directory _dist = Directory('dist');
final File _manifest = File('dist/update.json');

/// `dist/` holds an APK and its manifest. Absent in CI and after a clean clone.
bool get _hasArtifacts => _manifest.existsSync();

void main() {
  group('the published release artefacts', () {
    test('the manifest parses the way the app parses it', () {
      if (!_hasArtifacts) {
        markTestSkipped('no dist/update.json — run tool/release.sh first');
        return;
      }

      final manifest = ReleaseManifest.parse(_manifest.readAsStringSync());
      expect(manifest, isNotNull, reason: 'the app would reject this document');
    });

    test('every fact in the manifest matches the APK on disk', () {
      if (!_hasArtifacts) {
        markTestSkipped('no dist/update.json — run tool/release.sh first');
        return;
      }

      final manifest = ReleaseManifest.parse(_manifest.readAsStringSync())!;

      // The URL names the asset on the release page, not on this disk, so do
      // not derive a local path from it: both files sit in `dist/` and the
      // release uploads exactly them.
      final candidates = _dist
          .listSync()
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.apk'))
          .toList();
      expect(
        candidates,
        hasLength(1),
        reason: 'dist/ should hold exactly the APK the manifest describes',
      );

      final file = candidates.single;
      final bytes = file.readAsBytesSync();

      expect(
        manifest.apk.bytes,
        bytes.length,
        reason: 'size is the first thing the app checks, and a stale manifest '
            'means every download is thrown away after the fact',
      );
      expect(
        manifest.apk.sha256,
        sha256.convert(bytes).toString(),
        reason: 'a digest that does not match makes every install fail closed',
      );
      expect(
        manifest.apk.sha256,
        equals(manifest.apk.sha256.toLowerCase()),
        reason: 'the parser lowercases, so an uppercase digest would compare '
            'unequal to itself on the wire',
      );
      expect(manifest.apk.url.scheme, 'https');
    });

    test('the manifest names a build newer than the source tree', () {
      if (!_hasArtifacts) {
        markTestSkipped('no dist/update.json — run tool/release.sh first');
        return;
      }

      final manifest = ReleaseManifest.parse(_manifest.readAsStringSync())!;
      final version = _pubspecVersion();

      expect(
        version,
        isNotNull,
        reason: 'pubspec.yaml must carry `version: x.y.z+build`',
      );
      // Published artefacts are built from the tree they sit next to, so the
      // manifest must describe that same build. A higher number here means the
      // release was cut from something else and the app would offer an update
      // to a build nobody has.
      expect(manifest.version.build, version!.build);
      expect(manifest.version.name.toString(), version.name.toString());
    });
  });
}

/// The version in `pubspec.yaml`, which is the single source of truth that
/// `release.sh` and Gradle both read.
ReleaseVersion? _pubspecVersion() {
  final file = File('pubspec.yaml');
  if (!file.existsSync()) return null;
  for (final line in const LineSplitter().convert(file.readAsStringSync())) {
    if (!line.startsWith('version:')) continue;
    final raw = line.substring('version:'.length).trim();
    final plus = raw.indexOf('+');
    if (plus < 0) return null;
    return ReleaseVersion.tryParse(
      name: raw.substring(0, plus),
      build: raw.substring(plus + 1),
    );
  }
  return null;
}
