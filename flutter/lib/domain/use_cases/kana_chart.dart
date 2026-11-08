import '../models/kana.dart';
import '../models/types.dart';

/// The gojūon as a grid the word library can draw instead of a list of rows.
///
/// A kana deck is an ordinary [WordList] — there is no `kind` field on the
/// model, and adding one would mean touching the wire whitelist in
/// `wire.dart` and every sync merge. So the chart is keyed off the *contents*:
/// a Japanese wordbook whose words are all single kana glyphs of one script.
/// Recognising the data rather than tagging the book keeps the chart working
/// for decks created before this existed and for decks restored from a backup.
///
/// The grid itself comes from the static [kanaFor] table, not from the deck's
/// words: the chart is a reference a learner copies, so a deleted 假名 still
/// has a (dimmed) place on it. That is why [chartScriptOf] tolerates missing
/// glyphs but not foreign ones.

const int kanaChartColumns = 5;

/// How many words must look like kana before a book is treated as a chart.
/// 46 is a full deck; a few deletions should not collapse the layout back to a
/// list, but a handful of stray kana in a normal vocabulary book should not.
const int _kMinChartWords = 40;

final Set<String> _hiraGlyphs = hiraganaKana.map((Kana k) => k.kana).toSet();
final Set<String> _kataGlyphs = katakanaKana.map((Kana k) => k.kana).toSet();

/// Which script's chart [words] describe, or `null` when the book is not one.
///
/// Returns `null` for a non-Japanese book, a short book, a book with any word
/// that is not a chart glyph, a book mixing the two scripts, or a book with a
/// duplicated glyph. In those cases the caller falls back to the normal table
/// so that no word becomes unreachable behind a chart that cannot show it.
KanaScript? chartScriptOf(WordList list, List<Word> words) {
  if (list.sourceLang != 'ja') return null;
  if (words.length < _kMinChartWords) return null;

  bool? katakana; // null = undecided; true = katakana; false = hiragana.
  final Set<String> seen = <String>{};
  for (final Word word in words) {
    final String glyph = word.term.trim();
    if (!seen.add(glyph)) return null;
    final bool isKata = _kataGlyphs.contains(glyph);
    final bool isHira = _hiraGlyphs.contains(glyph);
    if (!isKata && !isHira) return null;
    if (katakana == null) {
      katakana = isKata;
    } else if (katakana != isKata) {
      return null;
    }
  }
  return katakana == true ? KanaScript.katakana : KanaScript.hiragana;
}

/// One row of the chart: its label (あ行, ア行, ん …) and five cells, one per
/// vowel column a/i/u/e/o. A `null` cell is a gap in the gojūon — や行 has no
/// i/e, わ行 has no i/u/e, and ん has no vowel at all.
class KanaChartRow {
  const KanaChartRow(this.label, this.cells);

  final String label;
  final List<Kana?> cells;
}

/// The gojūon for [script], grouped by [Kana.row] into 11 rows of 5 cells.
///
/// Column is decided by the last letter of the Hepburn romaji, which is exactly
/// the vowel the chart is named after: し `shi` → i, つ `tsu` → u, を `wo` → o.
/// ん/ン (`n`) has no vowel and sits alone in the first column of its own row.
List<KanaChartRow> buildKanaChart(KanaScript script) {
  final List<KanaChartRow> rows = <KanaChartRow>[];
  String? currentRow;
  List<Kana?>? cells;
  for (final Kana kana in kanaFor(script)) {
    if (kana.row != currentRow) {
      if (cells != null) rows.add(KanaChartRow(currentRow!, cells));
      currentRow = kana.row;
      cells = List<Kana?>.filled(kanaChartColumns, null);
    }
    cells![_columnOf(kana.romaji)] = kana;
  }
  if (cells != null) rows.add(KanaChartRow(currentRow!, cells));
  return rows;
}

int _columnOf(String romaji) {
  if (romaji.isEmpty) return 0;
  return switch (romaji[romaji.length - 1]) {
    'i' => 1,
    'u' => 2,
    'e' => 3,
    'o' => 4,
    _ => 0, // 'a', and 'n' for ん/ン (no vowel, first column).
  };
}
