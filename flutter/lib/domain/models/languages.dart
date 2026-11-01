/// Language catalogue for the word-list language pickers and TTS.
///
/// A pragmatic subset of the reference app's 105 languages, with BCP-47 tags
/// that Web Speech and Google Translate accept. Ported from
/// `src/lib/languages.ts` — the list order and every label are the app's
/// existing content, not a new choice.
library;

/// One entry in the picker: the BCP-47 [code] and its label in both UI
/// languages.
class LangOption {
  const LangOption({required this.code, required this.zh, required this.en});

  final String code;
  final String zh;
  final String en;
}

const List<LangOption> LANGUAGES = [
  LangOption(code: 'en', zh: '英语', en: 'English'),
  LangOption(code: 'zh-CN', zh: '中文（简体）', en: 'Chinese (Simplified)'),
  LangOption(code: 'zh-TW', zh: '中文（繁体）', en: 'Chinese (Traditional)'),
  LangOption(code: 'ja', zh: '日语', en: 'Japanese'),
  LangOption(code: 'ko', zh: '韩语', en: 'Korean'),
  LangOption(code: 'es', zh: '西班牙语', en: 'Spanish'),
  LangOption(code: 'fr', zh: '法语', en: 'French'),
  LangOption(code: 'de', zh: '德语', en: 'German'),
  LangOption(code: 'it', zh: '意大利语', en: 'Italian'),
  LangOption(code: 'pt', zh: '葡萄牙语', en: 'Portuguese'),
  LangOption(code: 'ru', zh: '俄语', en: 'Russian'),
  LangOption(code: 'uk', zh: '乌克兰语', en: 'Ukrainian'),
  LangOption(code: 'pl', zh: '波兰语', en: 'Polish'),
  LangOption(code: 'nl', zh: '荷兰语', en: 'Dutch'),
  LangOption(code: 'sv', zh: '瑞典语', en: 'Swedish'),
  LangOption(code: 'no', zh: '挪威语', en: 'Norwegian'),
  LangOption(code: 'da', zh: '丹麦语', en: 'Danish'),
  LangOption(code: 'fi', zh: '芬兰语', en: 'Finnish'),
  LangOption(code: 'tr', zh: '土耳其语', en: 'Turkish'),
  LangOption(code: 'ar', zh: '阿拉伯语', en: 'Arabic'),
  LangOption(code: 'he', zh: '希伯来语', en: 'Hebrew'),
  LangOption(code: 'fa', zh: '波斯语', en: 'Persian'),
  LangOption(code: 'hi', zh: '印地语', en: 'Hindi'),
  LangOption(code: 'th', zh: '泰语', en: 'Thai'),
  LangOption(code: 'vi', zh: '越南语', en: 'Vietnamese'),
  LangOption(code: 'id', zh: '印尼语', en: 'Indonesian'),
  LangOption(code: 'ms', zh: '马来语', en: 'Malay'),
  LangOption(code: 'cs', zh: '捷克语', en: 'Czech'),
  LangOption(code: 'el', zh: '希腊语', en: 'Greek'),
  LangOption(code: 'hu', zh: '匈牙利语', en: 'Hungarian'),
  LangOption(code: 'ro', zh: '罗马尼亚语', en: 'Romanian'),
  LangOption(code: 'bg', zh: '保加利亚语', en: 'Bulgarian'),
  LangOption(code: 'hr', zh: '克罗地亚语', en: 'Croatian'),
  LangOption(code: 'sr', zh: '塞尔维亚语', en: 'Serbian'),
  LangOption(code: 'sk', zh: '斯洛伐克语', en: 'Slovak'),
  LangOption(code: 'sl', zh: '斯洛文尼亚语', en: 'Slovenian'),
  LangOption(code: 'et', zh: '爱沙尼亚语', en: 'Estonian'),
  LangOption(code: 'lv', zh: '拉脱维亚语', en: 'Latvian'),
  LangOption(code: 'lt', zh: '立陶宛语', en: 'Lithuanian'),
  LangOption(code: 'is', zh: '冰岛语', en: 'Icelandic'),
  LangOption(code: 'ga', zh: '爱尔兰语', en: 'Irish'),
  LangOption(code: 'ca', zh: '加泰罗尼亚语', en: 'Catalan'),
  LangOption(code: 'eu', zh: '巴斯克语', en: 'Basque'),
  LangOption(code: 'gl', zh: '加利西亚语', en: 'Galician'),
  LangOption(code: 'af', zh: '南非荷兰语', en: 'Afrikaans'),
  LangOption(code: 'sw', zh: '斯瓦希里语', en: 'Swahili'),
  LangOption(code: 'tl', zh: '菲律宾语', en: 'Filipino'),
  LangOption(code: 'bn', zh: '孟加拉语', en: 'Bengali'),
  LangOption(code: 'ta', zh: '泰米尔语', en: 'Tamil'),
  LangOption(code: 'te', zh: '泰卢固语', en: 'Telugu'),
  LangOption(code: 'ur', zh: '乌尔都语', en: 'Urdu'),
  LangOption(code: 'mr', zh: '马拉地语', en: 'Marathi'),
  LangOption(code: 'gu', zh: '古吉拉特语', en: 'Gujarati'),
  LangOption(code: 'kn', zh: '卡纳达语', en: 'Kannada'),
  LangOption(code: 'ml', zh: '马拉雅拉姆语', en: 'Malayalam'),
  LangOption(code: 'pa', zh: '旁遮普语', en: 'Punjabi'),
  LangOption(code: 'my', zh: '缅甸语', en: 'Burmese'),
  LangOption(code: 'km', zh: '高棉语', en: 'Khmer'),
  LangOption(code: 'lo', zh: '老挝语', en: 'Lao'),
  LangOption(code: 'mn', zh: '蒙古语', en: 'Mongolian'),
  LangOption(code: 'kk', zh: '哈萨克语', en: 'Kazakh'),
  LangOption(code: 'uz', zh: '乌兹别克语', en: 'Uzbek'),
  LangOption(code: 'az', zh: '阿塞拜疆语', en: 'Azerbaijani'),
  LangOption(code: 'hy', zh: '亚美尼亚语', en: 'Armenian'),
  LangOption(code: 'ka', zh: '格鲁吉亚语', en: 'Georgian'),
  LangOption(code: 'sq', zh: '阿尔巴尼亚语', en: 'Albanian'),
  LangOption(code: 'mk', zh: '马其顿语', en: 'Macedonian'),
  LangOption(code: 'bs', zh: '波斯尼亚语', en: 'Bosnian'),
  LangOption(code: 'la', zh: '拉丁语', en: 'Latin'),
  LangOption(code: 'eo', zh: '世界语', en: 'Esperanto'),
];

final Map<String, LangOption> _byCode = {
  for (final l in LANGUAGES) l.code: l,
};

/// Label for [code] in [uiLang]; an unknown code falls back to the code itself.
String langName(String code, String uiLang) {
  final lang = _byCode[code];
  if (lang == null) return code;
  return uiLang == 'zh-CN' ? lang.zh : lang.en;
}

/// Compact badge label: upper-cased, with the Chinese-script region dropped
/// (`zh-CN` → `ZH`, `en` → `EN`).
String langShort(String code) =>
    code.toUpperCase().replaceAll('-CN', '').replaceAll('-TW', '');
