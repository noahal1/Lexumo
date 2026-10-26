/**
 * Language catalogue for the word-list language pickers and TTS.
 * A pragmatic subset of the reference app's 105 languages, with
 * BCP-47 tags that Web Speech and Google Translate accept.
 */
export interface LangOption {
  code: string;
  zh: string;
  en: string;
}

export const LANGUAGES: LangOption[] = [
  { code: "en", zh: "英语", en: "English" },
  { code: "zh-CN", zh: "中文（简体）", en: "Chinese (Simplified)" },
  { code: "zh-TW", zh: "中文（繁体）", en: "Chinese (Traditional)" },
  { code: "ja", zh: "日语", en: "Japanese" },
  { code: "ko", zh: "韩语", en: "Korean" },
  { code: "es", zh: "西班牙语", en: "Spanish" },
  { code: "fr", zh: "法语", en: "French" },
  { code: "de", zh: "德语", en: "German" },
  { code: "it", zh: "意大利语", en: "Italian" },
  { code: "pt", zh: "葡萄牙语", en: "Portuguese" },
  { code: "ru", zh: "俄语", en: "Russian" },
  { code: "uk", zh: "乌克兰语", en: "Ukrainian" },
  { code: "pl", zh: "波兰语", en: "Polish" },
  { code: "nl", zh: "荷兰语", en: "Dutch" },
  { code: "sv", zh: "瑞典语", en: "Swedish" },
  { code: "no", zh: "挪威语", en: "Norwegian" },
  { code: "da", zh: "丹麦语", en: "Danish" },
  { code: "fi", zh: "芬兰语", en: "Finnish" },
  { code: "tr", zh: "土耳其语", en: "Turkish" },
  { code: "ar", zh: "阿拉伯语", en: "Arabic" },
  { code: "he", zh: "希伯来语", en: "Hebrew" },
  { code: "fa", zh: "波斯语", en: "Persian" },
  { code: "hi", zh: "印地语", en: "Hindi" },
  { code: "th", zh: "泰语", en: "Thai" },
  { code: "vi", zh: "越南语", en: "Vietnamese" },
  { code: "id", zh: "印尼语", en: "Indonesian" },
  { code: "ms", zh: "马来语", en: "Malay" },
  { code: "cs", zh: "捷克语", en: "Czech" },
  { code: "el", zh: "希腊语", en: "Greek" },
  { code: "hu", zh: "匈牙利语", en: "Hungarian" },
  { code: "ro", zh: "罗马尼亚语", en: "Romanian" },
  { code: "bg", zh: "保加利亚语", en: "Bulgarian" },
  { code: "hr", zh: "克罗地亚语", en: "Croatian" },
  { code: "sr", zh: "塞尔维亚语", en: "Serbian" },
  { code: "sk", zh: "斯洛伐克语", en: "Slovak" },
  { code: "sl", zh: "斯洛文尼亚语", en: "Slovenian" },
  { code: "et", zh: "爱沙尼亚语", en: "Estonian" },
  { code: "lv", zh: "拉脱维亚语", en: "Latvian" },
  { code: "lt", zh: "立陶宛语", en: "Lithuanian" },
  { code: "is", zh: "冰岛语", en: "Icelandic" },
  { code: "ga", zh: "爱尔兰语", en: "Irish" },
  { code: "ca", zh: "加泰罗尼亚语", en: "Catalan" },
  { code: "eu", zh: "巴斯克语", en: "Basque" },
  { code: "gl", zh: "加利西亚语", en: "Galician" },
  { code: "af", zh: "南非荷兰语", en: "Afrikaans" },
  { code: "sw", zh: "斯瓦希里语", en: "Swahili" },
  { code: "tl", zh: "菲律宾语", en: "Filipino" },
  { code: "bn", zh: "孟加拉语", en: "Bengali" },
  { code: "ta", zh: "泰米尔语", en: "Tamil" },
  { code: "te", zh: "泰卢固语", en: "Telugu" },
  { code: "ur", zh: "乌尔都语", en: "Urdu" },
  { code: "mr", zh: "马拉地语", en: "Marathi" },
  { code: "gu", zh: "古吉拉特语", en: "Gujarati" },
  { code: "kn", zh: "卡纳达语", en: "Kannada" },
  { code: "ml", zh: "马拉雅拉姆语", en: "Malayalam" },
  { code: "pa", zh: "旁遮普语", en: "Punjabi" },
  { code: "my", zh: "缅甸语", en: "Burmese" },
  { code: "km", zh: "高棉语", en: "Khmer" },
  { code: "lo", zh: "老挝语", en: "Lao" },
  { code: "mn", zh: "蒙古语", en: "Mongolian" },
  { code: "kk", zh: "哈萨克语", en: "Kazakh" },
  { code: "uz", zh: "乌兹别克语", en: "Uzbek" },
  { code: "az", zh: "阿塞拜疆语", en: "Azerbaijani" },
  { code: "hy", zh: "亚美尼亚语", en: "Armenian" },
  { code: "ka", zh: "格鲁吉亚语", en: "Georgian" },
  { code: "sq", zh: "阿尔巴尼亚语", en: "Albanian" },
  { code: "mk", zh: "马其顿语", en: "Macedonian" },
  { code: "bs", zh: "波斯尼亚语", en: "Bosnian" },
  { code: "la", zh: "拉丁语", en: "Latin" },
  { code: "eo", zh: "世界语", en: "Esperanto" },
];

const BY_CODE = new Map(LANGUAGES.map((l) => [l.code, l]));

export function langName(code: string, uiLang: string): string {
  const lang = BY_CODE.get(code);
  if (!lang) return code;
  return uiLang === "zh-CN" ? lang.zh : lang.en;
}

export function langShort(code: string): string {
  return code.toUpperCase().replace("-CN", "").replace("-TW", "");
}
