/// The gojūon — the kana chart every Japanese course starts from.
///
/// 46 sounds per script: five vowels across ten consonant rows, plus ん/ン.
///
/// This is a table rather than a generator on purpose. A generator would need a
/// rule per row anyway, because the exceptions *are* the chart: し is `shi` and
/// not `si`, ち is `chi`, つ is `tsu`, ふ is `fu`, and を carries no consonant
/// at all. Spelling those out once, as data, is shorter than the code that
/// would derive them and is also the form a learner recognises.
///
/// Katakana is not a transliteration of hiragana. The two scripts cover the
/// same sounds, but the words you learn them with are different — hiragana
/// carries native vocabulary, katakana carries loanwords — so each row stores
/// its own example instead of sharing one.
///
/// 濁音 and 半濁音 (が/ざ/だ/ば/ぱ and friends) are deliberately absent: they
/// are a second chart that doubles the deck, and a learner who has not yet
/// finished the first one is not served by having 142 cards waiting.
library;

/// Which script a kana belongs to.
enum KanaScript {
  hiragana('hiragana'),
  katakana('katakana');

  const KanaScript(this.wire);

  /// Stable identifier; used for the generated list name and by tests.
  final String wire;
}

/// One entry of the chart: the glyph, how it is read, where it sits, and one
/// word that starts with it.
class Kana {
  const Kana({
    required this.kana,
    required this.romaji,
    required this.row,
    required this.word,
    required this.wordZh,
  });

  /// The glyph itself — あ, ア.
  final String kana;

  /// Hepburn romanisation — `a`, `shi`, `tsu`.
  final String romaji;

  /// The row this kana sits in — あ行, か行. Doubles as the card's overline,
  /// so a learner always sees which family they are being asked about.
  final String row;

  /// An example word in the same script — あめ, アイス.
  final String word;

  /// What [word] means.
  final String wordZh;
}

/// あ行 … わ行 plus ん — 46 entries, in chart order.
const List<Kana> hiraganaKana = <Kana>[
  // あ行
  Kana(kana: 'あ', romaji: 'a', row: 'あ行', word: 'あめ', wordZh: '雨'),
  Kana(kana: 'い', romaji: 'i', row: 'あ行', word: 'いぬ', wordZh: '狗'),
  Kana(kana: 'う', romaji: 'u', row: 'あ行', word: 'うみ', wordZh: '海'),
  Kana(kana: 'え', romaji: 'e', row: 'あ行', word: 'えき', wordZh: '车站'),
  Kana(kana: 'お', romaji: 'o', row: 'あ行', word: 'おかね', wordZh: '钱'),
  // か行
  Kana(kana: 'か', romaji: 'ka', row: 'か行', word: 'かさ', wordZh: '伞'),
  Kana(kana: 'き', romaji: 'ki', row: 'か行', word: 'き', wordZh: '树'),
  Kana(kana: 'く', romaji: 'ku', row: 'か行', word: 'くつ', wordZh: '鞋'),
  Kana(kana: 'け', romaji: 'ke', row: 'か行', word: 'けむり', wordZh: '烟'),
  Kana(kana: 'こ', romaji: 'ko', row: 'か行', word: 'こえ', wordZh: '声音'),
  // さ行
  Kana(kana: 'さ', romaji: 'sa', row: 'さ行', word: 'さかな', wordZh: '鱼'),
  Kana(kana: 'し', romaji: 'shi', row: 'さ行', word: 'しごと', wordZh: '工作'),
  Kana(kana: 'す', romaji: 'su', row: 'さ行', word: 'すし', wordZh: '寿司'),
  Kana(kana: 'せ', romaji: 'se', row: 'さ行', word: 'せかい', wordZh: '世界'),
  Kana(kana: 'そ', romaji: 'so', row: 'さ行', word: 'そら', wordZh: '天空'),
  // た行
  Kana(kana: 'た', romaji: 'ta', row: 'た行', word: 'たまご', wordZh: '鸡蛋'),
  Kana(kana: 'ち', romaji: 'chi', row: 'た行', word: 'ちず', wordZh: '地图'),
  Kana(kana: 'つ', romaji: 'tsu', row: 'た行', word: 'つき', wordZh: '月亮'),
  Kana(kana: 'て', romaji: 'te', row: 'た行', word: 'て', wordZh: '手'),
  Kana(kana: 'と', romaji: 'to', row: 'た行', word: 'とり', wordZh: '鸟'),
  // な行
  Kana(kana: 'な', romaji: 'na', row: 'な行', word: 'なつ', wordZh: '夏天'),
  Kana(kana: 'に', romaji: 'ni', row: 'な行', word: 'にく', wordZh: '肉'),
  Kana(kana: 'ぬ', romaji: 'nu', row: 'な行', word: 'ぬの', wordZh: '布'),
  Kana(kana: 'ね', romaji: 'ne', row: 'な行', word: 'ねこ', wordZh: '猫'),
  Kana(kana: 'の', romaji: 'no', row: 'な行', word: 'のり', wordZh: '海苔'),
  // は行
  Kana(kana: 'は', romaji: 'ha', row: 'は行', word: 'はな', wordZh: '花'),
  Kana(kana: 'ひ', romaji: 'hi', row: 'は行', word: 'ひと', wordZh: '人'),
  Kana(kana: 'ふ', romaji: 'fu', row: 'は行', word: 'ふゆ', wordZh: '冬天'),
  Kana(kana: 'へ', romaji: 'he', row: 'は行', word: 'へや', wordZh: '房间'),
  Kana(kana: 'ほ', romaji: 'ho', row: 'は行', word: 'ほし', wordZh: '星星'),
  // ま行
  Kana(kana: 'ま', romaji: 'ma', row: 'ま行', word: 'まど', wordZh: '窗户'),
  Kana(kana: 'み', romaji: 'mi', row: 'ま行', word: 'みず', wordZh: '水'),
  Kana(kana: 'む', romaji: 'mu', row: 'ま行', word: 'むし', wordZh: '虫子'),
  Kana(kana: 'め', romaji: 'me', row: 'ま行', word: 'め', wordZh: '眼睛'),
  Kana(kana: 'も', romaji: 'mo', row: 'ま行', word: 'もり', wordZh: '森林'),
  // や行
  Kana(kana: 'や', romaji: 'ya', row: 'や行', word: 'やま', wordZh: '山'),
  Kana(kana: 'ゆ', romaji: 'yu', row: 'や行', word: 'ゆき', wordZh: '雪'),
  Kana(kana: 'よ', romaji: 'yo', row: 'や行', word: 'よる', wordZh: '夜晚'),
  // ら行
  Kana(kana: 'ら', romaji: 'ra', row: 'ら行', word: 'らく', wordZh: '轻松'),
  Kana(kana: 'り', romaji: 'ri', row: 'ら行', word: 'りんご', wordZh: '苹果'),
  Kana(kana: 'る', romaji: 'ru', row: 'ら行', word: 'るす', wordZh: '不在家'),
  Kana(kana: 'れ', romaji: 're', row: 'ら行', word: 'れきし', wordZh: '历史'),
  Kana(kana: 'ろ', romaji: 'ro', row: 'ら行', word: 'ろく', wordZh: '六'),
  // わ行
  Kana(kana: 'わ', romaji: 'wa', row: 'わ行', word: 'わたし', wordZh: '我'),
  Kana(kana: 'を', romaji: 'wo', row: 'わ行', word: 'を', wordZh: '宾格助词'),
  // ん
  Kana(kana: 'ん', romaji: 'n', row: 'ん', word: 'ほん', wordZh: '书'),
];

/// ア行 … ワ行 plus ン — the same 46 sounds in katakana.
///
/// The example words are loanwords, because that is what katakana is for: a
/// learner who meets カメラ in the deck has met a word they can use, whereas
/// the hiragana deck's かさ teaches the native vocabulary the other script
/// carries.
const List<Kana> katakanaKana = <Kana>[
  // ア行
  Kana(kana: 'ア', romaji: 'a', row: 'ア行', word: 'アイス', wordZh: '冰淇淋'),
  Kana(kana: 'イ', romaji: 'i', row: 'ア行', word: 'イス', wordZh: '椅子'),
  Kana(kana: 'ウ', romaji: 'u', row: 'ア行', word: 'ウール', wordZh: '羊毛'),
  Kana(kana: 'エ', romaji: 'e', row: 'ア行', word: 'エアコン', wordZh: '空调'),
  Kana(kana: 'オ', romaji: 'o', row: 'ア行', word: 'オレンジ', wordZh: '橙子'),
  // カ行
  Kana(kana: 'カ', romaji: 'ka', row: 'カ行', word: 'カメラ', wordZh: '相机'),
  Kana(kana: 'キ', romaji: 'ki', row: 'カ行', word: 'キロ', wordZh: '公斤'),
  Kana(kana: 'ク', romaji: 'ku', row: 'カ行', word: 'クラス', wordZh: '班级'),
  Kana(kana: 'ケ', romaji: 'ke', row: 'カ行', word: 'ケーキ', wordZh: '蛋糕'),
  Kana(kana: 'コ', romaji: 'ko', row: 'カ行', word: 'コーヒー', wordZh: '咖啡'),
  // サ行
  Kana(kana: 'サ', romaji: 'sa', row: 'サ行', word: 'サラダ', wordZh: '沙拉'),
  Kana(kana: 'シ', romaji: 'shi', row: 'サ行', word: 'シャツ', wordZh: '衬衫'),
  Kana(kana: 'ス', romaji: 'su', row: 'サ行', word: 'スープ', wordZh: '汤'),
  Kana(kana: 'セ', romaji: 'se', row: 'サ行', word: 'セーター', wordZh: '毛衣'),
  Kana(kana: 'ソ', romaji: 'so', row: 'サ行', word: 'ソファ', wordZh: '沙发'),
  // タ行
  Kana(kana: 'タ', romaji: 'ta', row: 'タ行', word: 'タクシー', wordZh: '出租车'),
  Kana(kana: 'チ', romaji: 'chi', row: 'タ行', word: 'チーズ', wordZh: '奶酪'),
  Kana(kana: 'ツ', romaji: 'tsu', row: 'タ行', word: 'ツアー', wordZh: '旅行团'),
  Kana(kana: 'テ', romaji: 'te', row: 'タ行', word: 'テレビ', wordZh: '电视'),
  Kana(kana: 'ト', romaji: 'to', row: 'タ行', word: 'トマト', wordZh: '西红柿'),
  // ナ行
  Kana(kana: 'ナ', romaji: 'na', row: 'ナ行', word: 'ナイフ', wordZh: '刀'),
  Kana(kana: 'ニ', romaji: 'ni', row: 'ナ行', word: 'ニュース', wordZh: '新闻'),
  Kana(kana: 'ヌ', romaji: 'nu', row: 'ナ行', word: 'ヌードル', wordZh: '面条'),
  Kana(kana: 'ネ', romaji: 'ne', row: 'ナ行', word: 'ネクタイ', wordZh: '领带'),
  Kana(kana: 'ノ', romaji: 'no', row: 'ナ行', word: 'ノート', wordZh: '笔记本'),
  // ハ行
  Kana(kana: 'ハ', romaji: 'ha', row: 'ハ行', word: 'ハンバーガー', wordZh: '汉堡'),
  Kana(kana: 'ヒ', romaji: 'hi', row: 'ハ行', word: 'ヒーター', wordZh: '加热器'),
  Kana(kana: 'フ', romaji: 'fu', row: 'ハ行', word: 'フォーク', wordZh: '叉子'),
  Kana(kana: 'ヘ', romaji: 'he', row: 'ハ行', word: 'ヘリコプター', wordZh: '直升机'),
  Kana(kana: 'ホ', romaji: 'ho', row: 'ハ行', word: 'ホテル', wordZh: '酒店'),
  // マ行
  Kana(kana: 'マ', romaji: 'ma', row: 'マ行', word: 'マンション', wordZh: '公寓'),
  Kana(kana: 'ミ', romaji: 'mi', row: 'マ行', word: 'ミルク', wordZh: '牛奶'),
  Kana(kana: 'ム', romaji: 'mu', row: 'マ行', word: 'ムード', wordZh: '氛围'),
  Kana(kana: 'メ', romaji: 'me', row: 'マ行', word: 'メニュー', wordZh: '菜单'),
  Kana(kana: 'モ', romaji: 'mo', row: 'マ行', word: 'モデル', wordZh: '模特'),
  // ヤ行
  Kana(kana: 'ヤ', romaji: 'ya', row: 'ヤ行', word: 'ヤクルト', wordZh: '养乐多'),
  Kana(kana: 'ユ', romaji: 'yu', row: 'ヤ行', word: 'ユーモア', wordZh: '幽默'),
  Kana(kana: 'ヨ', romaji: 'yo', row: 'ヤ行', word: 'ヨーグルト', wordZh: '酸奶'),
  // ラ行
  Kana(kana: 'ラ', romaji: 'ra', row: 'ラ行', word: 'ラジオ', wordZh: '收音机'),
  Kana(kana: 'リ', romaji: 'ri', row: 'ラ行', word: 'リンゴ', wordZh: '苹果'),
  Kana(kana: 'ル', romaji: 'ru', row: 'ラ行', word: 'ルール', wordZh: '规则'),
  Kana(kana: 'レ', romaji: 're', row: 'ラ行', word: 'レモン', wordZh: '柠檬'),
  Kana(kana: 'ロ', romaji: 'ro', row: 'ラ行', word: 'ロボット', wordZh: '机器人'),
  // ワ行
  Kana(kana: 'ワ', romaji: 'wa', row: 'ワ行', word: 'ワイン', wordZh: '葡萄酒'),
  // ヲ is in the chart but has fallen out of modern use; it is kept so the
  // deck matches the chart a learner is copying from, and the note says why.
  Kana(kana: 'ヲ', romaji: 'wo', row: 'ワ行', word: 'ヲ', wordZh: '宾格助词（现已不用）'),
  // ン
  Kana(kana: 'ン', romaji: 'n', row: 'ン', word: 'パン', wordZh: '面包'),
];

/// The chart for [script].
List<Kana> kanaFor(KanaScript script) =>
    script == KanaScript.hiragana ? hiraganaKana : katakanaKana;
