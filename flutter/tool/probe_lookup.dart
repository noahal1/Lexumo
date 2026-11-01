// Real-network smoke test for the lookup client.
//
// The unit tests in `test/translate_test.dart` all run against a fake HTTP
// client, so they prove the parsing and the fallback chain but not that the
// live endpoints still answer in the shape the adapters expect. This script
// makes the real calls, once per provider, and prints what came back.
//
//   ../.flutter-sdk/flutterc run tool/probe_lookup.dart
//
// It is a tool, not a test: it needs the network and the providers' goodwill.
import 'dart:io';

import 'package:lexumo/data/services/translate.dart';

Future<void> main(List<String> args) async {
  final List<String> terms = args.isEmpty ? <String>['candid', 'zephyr'] : args;
  int failures = 0;

  for (final String term in terms) {
    stdout.writeln('--- forward: $term');
    try {
      final LookupResult r = await defaultLookup.lookupTerm(
        term,
        const LookupOptions(force: true),
      );
      stdout.writeln('  provider : ${r.provider}');
      stdout.writeln('  phonetic : ${r.phonetic}');
      stdout.writeln('  senses   : ${r.senses.length} ${r.senses.take(2).map((DictSense s) => '${s.pos} ${s.meaning}').join(' | ')}');
      stdout.writeln('  examples : ${r.examples.length}');
      if (r.senses.isEmpty && r.phonetic.isEmpty) {
        stdout.writeln('  !! empty result');
        failures++;
      }
    } on Object catch (e) {
      stdout.writeln('  FAILED: $e');
      failures++;
    }
  }

  stdout.writeln('--- reverse: 苹果 -> en');
  try {
    final LookupResult r = await defaultLookup.lookupTerm(
      '苹果',
      const LookupOptions(
        from: 'zh-CN',
        to: 'en',
        force: true,
        prefer: <ProviderId>[ProviderId.google, ProviderId.myMemory],
      ),
    );
    final String word = primaryMeaning(r).trim();
    stdout.writeln('  provider : ${r.provider}');
    stdout.writeln('  term     : "$word"');
    // A sentence here would mean the engine order is wrong: Youdao renders a
    // bare noun as polite prose (`りんごです`), which nobody adds to a wordbook.
    if (word.isEmpty || word.split(' ').length > 2) {
      stdout.writeln('  !! not a lemma');
      failures++;
    }
  } on Object catch (e) {
    stdout.writeln('  FAILED: $e');
    failures++;
  }

  stdout.writeln('--- cache: ${defaultLookup.cacheSize()} entries at ${lookupCacheFile()}');
  stdout.writeln(failures == 0 ? 'verdict : OK' : 'verdict : $failures FAILURE(S)');
  exit(failures == 0 ? 0 : 1);
}
