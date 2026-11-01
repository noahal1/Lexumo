// The update manifest: what a release may say, and what this build believes.
//
// The manifest comes off the network, so every case here is "what happens when
// the document is wrong". The rule being pinned: a bad document means no update,
// never an exception and never a partial guess. An offline phone and a
// mangled manifest must both end in the same quiet place.
//
// The `sha256`-and-`https` requirements get their own tests because they are
// the two that look fussy and are actually load-bearing: without them the
// download is only as trustworthy as the transport.

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/domain/update_manifest.dart';
import 'package:lexumo/domain/version.dart';

/// A well-formed 64-hex digest; the value is irrelevant, only its shape is.
const String kSha =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';

/// Three ways a digest can be wrong: not hex, one digit short, upper case.
const String kShaZ =
    'zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz';
const String kShaShortUpper = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const String kShaUpper =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const String kShaB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

/// A well-formed document, with overrides so each test states only the field
/// it is about.
Map<String, Object?> manifestJson({
  Object? version = '0.2.0',
  Object? build = 2,
  Object? url = 'https://example.test/lexumo-0.2.0.apk',
  Object? sha256 = kSha,
  Object? size = 20462854,
  Object? notes,
  Object? published,
  Object? minSupportedBuild,
}) {
  return <String, Object?>{
    'version': version,
    'build': build,
    'notes': notes ??
        <String, Object?>{'zh': '改善了长词条的行距', 'en': 'Better line spacing'},
    'published': published ?? '2026-11-02T10:00:00Z',
    'minSupportedBuild': minSupportedBuild,
    'apk': <String, Object?>{'url': url, 'size': size, 'sha256': sha256},
  };
}

void main() {
  group('ApkArtifact', () {
    test('reads a complete artifact', () {
      final apk = ApkArtifact.fromJson(manifestJson()['apk'])!;
      expect(apk.url, Uri.parse('https://example.test/lexumo-0.2.0.apk'));
      expect(apk.bytes, 20462854);
      expect(apk.sha256, kSha);
    });

    test('refuses a plain-http download', () {
      // The digest in the same document cannot help: whoever can rewrite the
      // transport can rewrite the manifest too.
      final apk = manifestJson(url: 'http://example.test/a.apk')['apk'];
      expect(ApkArtifact.fromJson(apk), isNull);
    });

    test('refuses a missing or malformed digest', () {
      for (final bad in <Object?>[null, '', 'abc', kShaZ, kShaShortUpper, 5]) {
        final apk = manifestJson(sha256: bad)['apk'];
        expect(ApkArtifact.fromJson(apk), isNull, reason: 'accepted $bad');
      }
    });

    test('normalises an uppercase digest to lowercase', () {
      final apk = ApkArtifact.fromJson(manifestJson(sha256: kShaUpper)['apk'])!;
      expect(apk.sha256, kSha);
    });

    test('a missing size is allowed, a nonsensical one is dropped', () {
      expect(ApkArtifact.fromJson(manifestJson(size: null)['apk'])!.bytes, isNull);
      expect(ApkArtifact.fromJson(manifestJson(size: 0)['apk'])!.bytes, isNull);
      expect(ApkArtifact.fromJson(manifestJson(size: -4)['apk'])!.bytes, isNull);
      expect(ApkArtifact.fromJson(manifestJson(size: '1200')['apk'])!.bytes, 1200);
    });

    test('refuses a relative or schemeless url', () {
      for (final bad in <Object?>[null, '', 'lexumo.apk', '/download/a.apk', 42]) {
        expect(
          ApkArtifact.fromJson(manifestJson(url: bad)['apk']),
          isNull,
          reason: 'accepted $bad',
        );
      }
    });
  });

  group('ReleaseManifest.parse', () {
    test('reads the whole document', () {
      final m = ReleaseManifest.parse(manifestJson())!;
      expect(m.version.name, const SemVer(0, 2, 0));
      expect(m.version.build, 2);
      expect(m.apk.bytes, 20462854);
      expect(m.published, DateTime.utc(2026, 11, 2, 10));
      expect(m.minSupportedBuild, isNull);
      expect(m.notesFor('zh'), '改善了长词条的行距');
    });

    test('accepts JSON text as well as a decoded value', () {
      final text = '{"version":"1.0.0","build":1,'
          '"apk":{"url":"https://x.test/a.apk","sha256":"$kShaB"}}';
      expect(ReleaseManifest.parse(text)!.version.build, 1);
    });

    test('refuses text that is not JSON', () {
      expect(ReleaseManifest.parse('not json at all'), isNull);
      expect(ReleaseManifest.parse(''), isNull);
    });

    test('refuses a document missing either load-bearing field', () {
      // Version and apk are what the whole flow acts on; without them there is
      // no update to describe, so the document is not a manifest.
      expect(ReleaseManifest.parse(null), isNull);
      expect(ReleaseManifest.parse(<Object>[]), isNull);
      expect(ReleaseManifest.parse(<String, Object?>{'build': 2}), isNull);
      expect(
        ReleaseManifest.parse({
          'version': '0.2.0',
          'build': 2,
        }),
        isNull,
      );
    });

    test('a broken optional field does not sink the document', () {
      final m = ReleaseManifest.parse(
        manifestJson(notes: 'not a map', published: 'yesterday', minSupportedBuild: 'x'),
      )!;
      expect(m.notes, isEmpty);
      expect(m.published, isNull);
      expect(m.minSupportedBuild, isNull);
    });

    test('notes fall back to zh, then to anything', () {
      final onlyZh = ReleaseManifest.parse(
        manifestJson(notes: <String, Object?>{'zh': '只有中文'}),
      )!;
      expect(onlyZh.notesFor('en'), '只有中文');

      final onlyEn = ReleaseManifest.parse(
        manifestJson(notes: <String, Object?>{'en': 'English only'}),
      )!;
      expect(onlyEn.notesFor('zh-CN'), 'English only');

      // A regional tag should find its base language.
      final regional = ReleaseManifest.parse(
        manifestJson(notes: <String, Object?>{'zh': '基础', 'en': 'Base'}),
      )!;
      expect(regional.notesFor('zh-TW'), '基础');

      // An empty map, not null: `null` in the helper means "use the default
      // notes", so the absence case has to be spelled as an empty collection.
      final none = ReleaseManifest.parse(
        manifestJson(notes: <String, Object?>{}),
      )!;
      expect(none.notesFor('zh'), isNull);
    });

    test('the required-update floor is optional and compared by build', () {
      final m = ReleaseManifest.parse(manifestJson(minSupportedBuild: 3))!;
      expect(m.minSupportedBuild, 3);
      expect(
        m.isRequiredFor(ReleaseVersion.tryParse(name: '0.1.0', build: 2)!),
        isTrue,
      );
      expect(
        m.isRequiredFor(ReleaseVersion.tryParse(name: '0.1.0', build: 3)!),
        isFalse,
      );
      // No floor means no forced update, ever.
      expect(
        ReleaseManifest.parse(manifestJson())!
            .isRequiredFor(ReleaseVersion.tryParse(name: '0.1.0', build: 1)!),
        isFalse,
      );
    });
  });
}
