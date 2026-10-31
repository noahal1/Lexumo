/// Data transfer: JSON snapshots, CSV, and Anki TXT.
///
/// A direct port of `src/lib/transfer.ts` (302 lines). Two things are worth
/// knowing before reading it:
///
///   · **The CSV export is a superset of what the importer reads.** The header
///     carries `exampleTranslation` rather than the `exampleZh` field name,
///     because the file is for humans and spreadsheets, not for round-tripping
///     a Dart field name. [parseImport] accepts either spelling back.
///
///   · **Only words are imported, never settings or logs.** A backup file
///     carries the whole snapshot, but importing it merges words into the
///     current library rather than replacing it — silently overwriting the
///     user's settings from a file they picked is not a thing an "import"
///     button should do.
///
/// The `pending` / `tombstones` bookkeeping is deliberately absent from both
/// directions: it belongs to the sync engine, and a file that carried it would
/// resurrect stale flags.
library;

import 'dart:convert';

import '../domain/types.dart';
import '../domain/utils.dart' show dayKeyOfTs;
import 'store.dart' show NewWordInput;

/// Which shape [parseImport] recognised. `unknown` means "nothing to import",
/// not "malformed" — a file full of prose is a normal thing to be handed.
enum ImportFormat {
  json('json'),
  csv('csv'),
  anki('anki'),
  unknown('unknown');

  const ImportFormat(this.wire);

  final String wire;
}

/// What [parseImport] produced. [skipped] counts rows that had no term —
/// blank lines and header-only files land here rather than being an error.
class ImportResult {
  const ImportResult({
    required this.words,
    required this.skipped,
    required this.format,
  });

  final List<NewWordInput> words;
  final int skipped;
  final ImportFormat format;

  static const ImportResult empty =
      ImportResult(words: [], skipped: 0, format: ImportFormat.unknown);
}

/// Column order of [exportCsv], and the header row it writes.
///
/// Stable on purpose: a spreadsheet a user has built formulas around must not
/// shift when a field is added. New fields go on the end.
const List<String> csvColumns = [
  'term',
  'pos',
  'definition',
  'definition2',
  'example',
  'exampleTranslation',
  'note',
  'status',
];

/* ------------------------------------------------------------------ */
/* Export                                                              */
/* ------------------------------------------------------------------ */

/// A JSON backup: the user's data, and only the user's data.
///
/// [AppData.toJson] is already the scrubbed projection — `Word.toJson` and
/// friends spell out every field rather than spreading the object, so no
/// server bookkeeping can leak in. `pending` and `tombstones` are dropped
/// explicitly for the same reason `src/lib/wire.ts` had `encodeAppData`.
///
/// Indented by two spaces so a diff between two backups is readable; that is
/// the whole point of a backup you might need to inspect by hand.
String exportJson(AppData data) {
  final snapshot = <String, dynamic>{
    'version': data.version,
    'lists': data.lists.map((l) => l.toJson()).toList(),
    'words': data.words.map((w) => w.toJson()).toList(),
    'logs': data.logs.map((l) => l.toJson()).toList(),
    'settings': data.settings.toJson(),
    'settingsUpdatedAt': data.settingsUpdatedAt,
  };
  return const JsonEncoder.withIndent('  ').convert(snapshot);
}

/// The name a backup should be saved under, e.g. `lexumo-backup-2026-10-30.json`.
String exportJsonFilename([int? now]) =>
    'lexumo-backup-${dayKeyOfTs(now ?? DateTime.now().millisecondsSinceEpoch)}.json';

/// The name a CSV should be saved under.
String exportCsvFilename([int? now]) =>
    'lexumo-words-${dayKeyOfTs(now ?? DateTime.now().millisecondsSinceEpoch)}.csv';

/// Quote a CSV cell per RFC 4180. Commas, quotes and newlines all force
/// quoting; an embedded quote is doubled.
String _csvCell(String value) =>
    RegExp(r'[",\r\n]').hasMatch(value)
        ? '"${value.replaceAll('"', '""')}"'
        : value;

/// CSV with a stable header row.
///
/// Returns a **BOM + CRLF** document. The BOM is what makes Excel open a file
/// of Chinese definitions as UTF-8 instead of mojibake; CRLF is what it
/// expects from a Windows-origin CSV. [parseImport] strips the BOM again.
String exportCsv(List<Word> words) {
  final rows = <String>[csvColumns.join(',')];
  for (final word in words) {
    rows.add([
      _csvCell(word.term),
      _csvCell(word.pos ?? ''),
      _csvCell(word.definition),
      _csvCell(word.definition2),
      _csvCell(word.example),
      _csvCell(word.exampleZh ?? ''),
      _csvCell(word.note),
      _csvCell(word.status.wire),
    ].join(','));
  }
  return '\uFEFF${rows.join('\r\n')}\r\n';
}

/* ------------------------------------------------------------------ */
/* Import                                                              */
/* ------------------------------------------------------------------ */

/// Detect the format of [text] and turn it into store-ready word inputs.
///
/// Detection order matters and is the same as the web build's:
///
///   1. `{` or `[` → try JSON. A file that starts like JSON but does not parse
///      falls through rather than erroring, because a CSV whose first cell is
///      `{word` is more likely than a corrupt JSON backup.
///   2. A tab in the **first line** → Anki. Tabs are a strong signal and must
///      win over commas, since English definitions routinely contain commas.
///   3. A comma in the first line → CSV.
///   4. A tab anywhere → Anki (a file with a prose first line).
///   5. Otherwise nothing.
ImportResult parseImport(String text, String listId) {
  final raw = text.replaceFirst(RegExp('^\uFEFF'), '').trim();
  if (raw.isEmpty) return ImportResult.empty;

  if (raw.startsWith('{') || raw.startsWith('[')) {
    final json = _parseJsonImport(raw, listId);
    if (json != null) return json;
  }

  final firstLine = raw.split(RegExp(r'\r?\n')).first;
  if (firstLine.contains('\t')) return _parseAnkiImport(raw, listId);
  if (firstLine.contains(',')) return _parseCsvImport(raw, listId);
  if (raw.contains('\t')) return _parseAnkiImport(raw, listId);
  return ImportResult.empty;
}

/// `null` means "this is not the JSON I expected" — not an error, so the
/// caller can fall through to the other formats.
ImportResult? _parseJsonImport(String text, String listId) {
  Object? parsed;
  try {
    parsed = jsonDecode(text);
  } on FormatException {
    return null;
  }

  final root = _asRecord(parsed);
  final List<Object?>? rawWords = root != null && root['words'] is List
      ? (root['words'] as List).cast<Object?>()
      : parsed is List
          ? parsed.cast<Object?>()
          : null;
  if (rawWords == null) return null;

  final words = <NewWordInput>[];
  var skipped = 0;
  for (final item in rawWords) {
    final rec = _asRecord(item);
    final term = rec == null ? '' : _asString(rec['term']);
    if (term.isEmpty) {
      skipped += 1;
      continue;
    }
    words.add(NewWordInput(
      term: term,
      pos: _optString(rec?['pos']),
      definition: _asString(rec?['definition']),
      definition2: _asString(rec?['definition2']),
      example: _asString(rec?['example']),
      exampleZh: _optString(rec?['exampleZh']),
      note: _asString(rec?['note']),
      status: _asStatus(rec?['status']),
      favorite: rec?['favorite'] == true,
      listId: listId,
    ));
  }
  return ImportResult(words: words, skipped: skipped, format: ImportFormat.json);
}

ImportResult _parseCsvImport(String text, String listId) {
  final rows = _parseCsvRows(text);
  if (rows.isEmpty) {
    return const ImportResult(
      words: [],
      skipped: 0,
      format: ImportFormat.csv,
    );
  }

  final header = rows.first.map((cell) => cell.trim().toLowerCase()).toList();
  int find(List<String> aliases) =>
      header.indexWhere((cell) => aliases.contains(cell));

  final termIdx = find(['term', 'word', '词语', '单词']);
  final posIdx = find(['pos', 'part of speech', 'partofspeech', '词性']);
  final defIdx = find(['definition', 'meaning', '释义', '意思']);
  final def2Idx = find(['definition2', 'definition_2', 'second definition', '补充释义']);
  final exampleIdx = find(['example', 'sentence', '例句']);
  final exampleZhIdx = find([
    'exampletranslation',
    'example_zh',
    'examplezh',
    '例句翻译',
    '例句译文',
  ]);
  final noteIdx = find(['note', 'notes', '备注', '笔记']);
  final statusIdx = find(['status', '状态']);

  // A file with no recognisable term column is treated as header-less: the
  // first column is the term and every row counts. That is what a hand-written
  // two-column CSV usually is.
  final start = termIdx >= 0 ? 1 : 0;

  final words = <NewWordInput>[];
  var skipped = 0;
  for (var r = start; r < rows.length; r += 1) {
    final row = rows[r];
    final term = _cellAt(row, termIdx >= 0 ? termIdx : 0);
    if (term.isEmpty) {
      skipped += 1;
      continue;
    }
    words.add(NewWordInput(
      term: term,
      pos: _optString(_cellAt(row, posIdx)),
      definition: _cellAt(row, defIdx),
      definition2: _cellAt(row, def2Idx),
      example: _cellAt(row, exampleIdx),
      exampleZh: _optString(_cellAt(row, exampleZhIdx)),
      note: _cellAt(row, noteIdx),
      status: _asStatus(_cellAt(row, statusIdx)),
      listId: listId,
    ));
  }
  return ImportResult(words: words, skipped: skipped, format: ImportFormat.csv);
}

/// RFC 4180-ish CSV reader: quoted fields, doubled quotes, CRLF or LF.
///
/// Written as a character loop rather than a regex because a quoted field may
/// contain the delimiters the regex would split on.
List<List<String>> _parseCsvRows(String text) {
  final src = text.replaceFirst(RegExp('^\uFEFF'), '');
  final rows = <List<String>>[];
  var row = <String>[];
  var field = StringBuffer();
  var inQuotes = false;

  for (var i = 0; i < src.length; i += 1) {
    final ch = src[i];
    if (inQuotes) {
      if (ch == '"') {
        if (i + 1 < src.length && src[i + 1] == '"') {
          field.write('"');
          i += 1;
        } else {
          inQuotes = false;
        }
      } else {
        field.write(ch);
      }
    } else if (ch == '"') {
      inQuotes = true;
    } else if (ch == ',') {
      row.add(field.toString());
      field = StringBuffer();
    } else if (ch == '\n' || ch == '\r') {
      if (ch == '\r' && i + 1 < src.length && src[i + 1] == '\n') i += 1;
      row.add(field.toString());
      field = StringBuffer();
      rows.add(row);
      row = <String>[];
    } else {
      field.write(ch);
    }
  }
  // A trailing newline must not produce a phantom empty row, but a final row
  // without one must still be kept.
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows;
}

ImportResult _parseAnkiImport(String text, String listId) {
  final words = <NewWordInput>[];
  var skipped = 0;
  for (final line in text.split(RegExp(r'\r?\n'))) {
    if (line.trim().isEmpty) continue;
    final parts = line.split('\t');
    if (parts.length < 2) {
      skipped += 1;
      continue;
    }
    final term = _stripHtml(parts.first);
    // Everything after the first column is the definition, joined with a space:
    // Anki exports often split one definition across extra columns.
    final definition = _stripHtml(parts.skip(1).join(' '));
    if (term.isEmpty) {
      skipped += 1;
      continue;
    }
    words.add(NewWordInput(
      term: term,
      definition: definition,
      definition2: '',
      example: '',
      note: '',
      listId: listId,
    ));
  }
  return ImportResult(words: words, skipped: skipped, format: ImportFormat.anki);
}

/* ------------------------------------------------------------------ */
/* Small coercion helpers                                              */
/* ------------------------------------------------------------------ */

Map<String, dynamic>? _asRecord(Object? value) =>
    value is Map ? value.cast<String, dynamic>() : null;

String _asString(Object? value) => value is String ? value.trim() : '';

/// Empty string means absent, not "an empty value" — a blank cell must not
/// become a word with `pos: ''`, which would then render as an empty tag.
String? _optString(Object? value) {
  final s = _asString(value);
  return s.isEmpty ? null : s;
}

WordStatus? _asStatus(Object? value) {
  if (value is! String) return null;
  return switch (value) {
    'new' => WordStatus.new_,
    'reviewing' => WordStatus.reviewing,
    'learning' => WordStatus.learning,
    'mastered' => WordStatus.mastered,
    _ => null,
  };
}

String _cellAt(List<String> row, int index) {
  if (index < 0 || index >= row.length) return '';
  return row[index].trim();
}

/// Strip HTML from an Anki field.
///
/// Anki stores rich text, so a definition arrives as
/// `<b>cat</b><br>a small animal`. Left alone it would render as literal markup
/// in the word list.
String _stripHtml(String input) {
  return input
      .replaceAll(RegExp('<[^>]*>'), ' ')
      .replaceAll(RegExp('&nbsp;', caseSensitive: false), ' ')
      .replaceAll(RegExp('&amp;', caseSensitive: false), '&')
      .replaceAll(RegExp('&lt;', caseSensitive: false), '<')
      .replaceAll(RegExp('&gt;', caseSensitive: false), '>')
      .replaceAll(RegExp('&quot;', caseSensitive: false), '"')
      .replaceAll(RegExp('&#39;'), "'")
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}
