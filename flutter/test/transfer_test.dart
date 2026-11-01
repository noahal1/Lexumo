/// Port of `src/lib/transfer.test.ts` (22 assertions).
///
/// One Dart test per vitest `it`, same fixtures, same expected strings, so the
/// two builds can be diffed case by case. The CSV column list and the import
/// parsers are a user-visible contract — people edit these files in Excel — so
/// a wrong column name or a dropped field is a data-loss bug, not a cosmetic
/// one.
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:lexumo/data/services/transfer.dart';
import 'package:lexumo/domain/models/types.dart';

const String listId = DEFAULT_LIST_ID;

Word makeWord({
  String? pos,
  String? exampleZh,
  String definition = '意外发现美好事物的能力',
  String example = 'a serendipitous meeting',
  String note = '',
}) {
  return Word(
    id: 'w1',
    term: 'serendipity',
    pos: pos,
    definition: definition,
    definition2: '',
    example: example,
    exampleZh: exampleZh,
    note: note,
    status: WordStatus.reviewing,
    favorite: false,
    listId: listId,
    sourceLang: 'en',
    targetLang: 'zh-CN',
    listenCount: 0,
    srs: null,
    createdAt: 0,
    updatedAt: 0,
  );
}

AppData makeData(List<Word> words) {
  return AppData(
    lists: const [
      WordList(
        id: listId,
        name: '默认词库',
        sourceLang: 'en',
        targetLang: 'zh-CN',
        createdAt: 0,
        updatedAt: 0,
      ),
    ],
    words: words,
  );
}

void main() {
  group('CSV export', () {
    test('writes the documented header in the documented order', () {
      final csv = exportCsv([makeWord()]);
      final header = csv.replaceFirst('\uFEFF', '').split('\r\n').first;
      expect(
        header,
        'term,pos,definition,definition2,example,exampleTranslation,note,status',
      );
    });

    test('writes the part of speech in its own column', () {
      final csv = exportCsv([makeWord(pos: 'n.')]);
      expect(csv, contains('serendipity,n.,意外发现美好事物的能力,'));
    });

    test('puts the example translation in its own column', () {
      final csv = exportCsv([makeWord(exampleZh: '一次机缘巧合的相遇')]);
      expect(csv, contains('a serendipitous meeting,一次机缘巧合的相遇,'));
    });

    test('has no tags column: the removed field never reaches the file', () {
      final csv = exportCsv([makeWord()]);
      expect(csv, isNot(contains('抽象')));
      final header = csv.replaceFirst('\uFEFF', '').split('\r\n').first;
      expect(header, isNot(contains('tag')));
    });

    test('quotes commas, quotes and newlines per RFC 4180', () {
      final csv = exportCsv([
        makeWord(definition: 'a, b', example: 'he said "hi"', note: 'line1\nline2'),
      ]);
      expect(csv, contains('"a, b"'));
      expect(csv, contains('"he said ""hi"""'));
      expect(csv, contains('"line1\nline2"'));
    });
  });

  group('CSV import', () {
    test('round-trips through export, keeping the example pair', () {
      final word = makeWord(exampleZh: '一次机缘巧合的相遇');
      final result = parseImport(exportCsv([word]), listId);

      expect(result.format, ImportFormat.csv);
      expect(result.skipped, 0);
      expect(result.words, hasLength(1));
      final w = result.words.first;
      expect(w.term, 'serendipity');
      expect(w.definition, '意外发现美好事物的能力');
      expect(w.example, 'a serendipitous meeting');
      expect(w.exampleZh, '一次机缘巧合的相遇');
      expect(w.status, WordStatus.reviewing);
      expect(w.listId, listId);
    });

    test('keeps the part of speech across an export and import', () {
      final result = parseImport(exportCsv([makeWord(pos: 'n.')]), listId);
      expect(result.words.first.pos, 'n.');
      expect(result.words.first.definition, '意外发现美好事物的能力');
    });

    test('accepts the part of speech under any of its aliases', () {
      for (final header in ['pos', 'part of speech', 'partOfSpeech', '词性']) {
        final text = 'term,$header,definition\nword one,adj.,一个词义\n';
        final result = parseImport(text, listId);
        expect(result.words.first.pos, 'adj.', reason: header);
      }
    });

    test('accepts the example translation under any of its aliases', () {
      for (final header in ['example_zh', 'exampleZh', '例句翻译', '例句译文']) {
        final text = 'term,example,$header\nword one,a sentence,一句话\n';
        final result = parseImport(text, listId);
        expect(result.words.first.exampleZh, '一句话', reason: header);
      }
    });

    test('leaves the translation undefined when the column is absent', () {
      final result = parseImport('term,definition\nhello,你好\n', listId);
      expect(result.words.first.exampleZh, isNull);
    });

    test('treats an empty translation cell as absent, not as an empty string', () {
      final result =
          parseImport('term,example,exampleTranslation\nhello,hi,\n', listId);
      expect(result.words.first.exampleZh, isNull);
    });

    test('skips rows with no term and counts them', () {
      final result = parseImport('term,definition\n,orphan\nhello,你好\n', listId);
      expect(result.words, hasLength(1));
      expect(result.skipped, 1);
    });

    test('accepts a BOM and CRLF from Excel', () {
      final result = parseImport('\uFEFFterm,definition\r\nhello,你好\r\n', listId);
      expect(result.words.first.term, 'hello');
    });

    test('ignores an unknown status instead of guessing one', () {
      final result = parseImport('term,status\nhello,weird\n', listId);
      expect(result.words.first.status, isNull);
    });
  });

  group('JSON import', () {
    test('keeps the example pair from a full snapshot', () {
      final word = makeWord(exampleZh: '一次机缘巧合的相遇');
      final result = parseImport(exportJson(makeData([word])), listId);
      expect(result.format, ImportFormat.json);
      expect(result.words.first.exampleZh, '一次机缘巧合的相遇');
    });

    test('accepts a bare array of words', () {
      final result = parseImport(
        jsonEncode([
          {'term': 'solo', 'exampleZh': '单独'},
        ]),
        listId,
      );
      expect(result.words.first.term, 'solo');
      expect(result.words.first.exampleZh, '单独');
    });

    test('restores only words — settings and logs in the file are ignored', () {
      final data = makeData([makeWord()]);
      final result = parseImport(exportJson(data), listId);
      expect(result.words, hasLength(1));
      // The Dart equivalent of `Object.keys(result)`: the result type has
      // exactly these three fields, and nothing from the file's settings
      // or logs survives the trip.
      expect(result.words.first.term, 'serendipity');
      expect(result.skipped, 0);
    });
  });

  group('Anki import', () {
    test('joins the non-first columns into the definition and strips HTML', () {
      final result = parseImport('candid\t<b>坦率</b>\tan opinion\n', listId);
      expect(result.format, ImportFormat.anki);
      final w = result.words.first;
      expect(w.term, 'candid');
      expect(w.definition, '坦率 an opinion');
      expect(w.example, '');
    });

    test('prefers tabs over commas, so a comma inside a definition survives', () {
      final result = parseImport('candid\ta, b, c\n', listId);
      expect(result.format, ImportFormat.anki);
      expect(result.words.first.definition, 'a, b, c');
    });
  });

  group('unknown input', () {
    test('reports nothing to import rather than throwing', () {
      final result = parseImport('just some prose with no separators', listId);
      expect(result.format, ImportFormat.unknown);
      expect(result.words, isEmpty);
    });
  });

  group('filename helpers', () {
    test('names backups by local day', () {
      final ts = DateTime(2026, 10, 30, 9, 5).millisecondsSinceEpoch;
      expect(exportJsonFilename(ts), 'lexumo-backup-2026-10-30.json');
      expect(exportCsvFilename(ts), 'lexumo-words-2026-10-30.csv');
    });
  });
}
