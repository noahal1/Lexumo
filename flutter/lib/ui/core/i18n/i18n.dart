/// Minimal i18n: dot-path lookup, `{var}` interpolation.
///
/// Ported from `src/i18n/index.tsx`. The web build kept the dictionaries as
/// nested objects and walked them per lookup; the Dart port pre-flattens them
/// to `Map<String, String>` (see `zh_cn.dart` / `en.dart`) so a lookup is one
/// hash probe instead of a path split. The observed behaviour is identical:
///
///   * look the key up in the active language,
///   * fall back to `zh-CN` when it is missing there,
///   * return the key itself when it is missing everywhere,
///   * replace `{name}` with `vars[name]`, leaving unknown names visible on
///     purpose so a missing variable shows up in the UI instead of vanishing.
library;

import '../../../domain/models/types.dart';
import 'en.dart';
import 'zh_cn.dart';

/// Placeholder pattern, identical to the web build's `/\{(\w+)\}/g`.
final RegExp _placeholder = RegExp(r'\{(\w+)\}');

/// Interpolate `{name}` placeholders in [raw].
///
/// A `null` [vars] returns [raw] untouched — the web build's early
/// `if (!vars) return raw` guard, so strings without variables never pay for
/// a regex pass. Unknown names stay as `{name}` rather than disappearing.
String _interpolate(String raw, Map<String, Object>? vars) {
  if (vars == null) return raw;
  return raw.replaceAllMapped(_placeholder, (Match m) {
    final String name = m.group(1)!;
    return vars.containsKey(name) ? '${vars[name]}' : m.group(0)!;
  });
}

/// The dictionary for a language, keyed by dot path.
const Map<UiLang, Map<String, String>> _dicts = <UiLang, Map<String, String>>{
  UiLang.zhCN: zhCnRaw,
  UiLang.en: enRaw,
};

/// Translations for one UI language.
///
/// ```dart
/// final i18n = I18n(lang);
/// i18n.t('nav.words');                       // 词库
/// i18n.t('words.pageSubtitle', {'words': 12, 'due': 3});
/// ```
///
/// Keys are the raw dot paths from the TS dictionaries rather than generated
/// constants: the dictionaries are the source of truth and a regenerated
/// constant class would silently drift from them.
class I18n {
  const I18n(this.lang);

  /// Active UI language. `UiLang.zhCN` is the reference dictionary.
  final UiLang lang;

  /// The active dictionary, exposed for callers that need to enumerate keys.
  Map<String, String> get dict => _dicts[lang] ?? zhCnRaw;

  /// The reference dictionary; also the fallback for missing keys.
  static Map<String, String> get fallback => zhCnRaw;

  /// Resolve [key] and interpolate [vars].
  ///
  /// Returns [key] unchanged when neither dictionary has it — surfacing the
  /// miss in the UI is what caught the typos the web build shipped.
  String t(String key, [Map<String, Object>? vars]) {
    final String? raw = dict[key] ?? zhCnRaw[key];
    if (raw == null) return key;
    return _interpolate(raw, vars);
  }

  /// Whether [key] exists in the active dictionary (fallback included).
  bool has(String key) => dict.containsKey(key) || zhCnRaw.containsKey(key);

  /// Resolve [key] without an [I18n] instance, mirroring `translate()`.
  static String translate(
    UiLang lang,
    String key, [
    Map<String, Object>? vars,
  ]) {
    final String? raw = _dicts[lang]?[key] ?? zhCnRaw[key];
    if (raw == null) return key;
    return _interpolate(raw, vars);
  }
}
