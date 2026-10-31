/// The settings sheet.
///
/// Ports `src/pages/settings/SettingsPage.tsx` and its `parts.tsx` helpers. The
/// page is a single card of sections — appearance, study, audio, sync, data —
/// followed by an about card. Every control writes through
/// `Store.updateSettings` the moment it changes; there is no save button,
/// because the web build never had one either.
///
/// One section of the web page described a subsystem this build does not have:
/// the sync client, which is rendered as a static panel that says so (see
/// [_SyncSection]). The dictionary lookup cache is omitted outright rather than
/// faked with dead controls.
///
/// Export and import live under Data. They were absent until the Supabase work
/// started, for the honest reason that nothing could write a file; see
/// `platform/file_dialogs.dart` for what changed.
library;

// `Card` is ours (ui/widgets.dart), not Material's.
import 'package:flutter/material.dart' hide Card;

import '../app/scope.dart';
import '../data/store.dart' show findDuplicate;
import '../data/sync_config.dart' show kDefaultServer;
import '../data/backend_transport.dart';
import '../data/sync_engine.dart';
import '../data/sync_transport.dart';
import '../data/transfer.dart';
import '../design/tokens.dart';
import '../domain/types.dart';
import '../domain/utils.dart';
import '../platform/file_dialogs.dart';
import '../platform/tts.dart';
import '../ui/controls.dart';
import '../ui/density.dart';
import '../ui/keyboard_hints.dart';
import '../ui/lex_icon.dart';
import '../ui/widgets.dart';

/// One row of the shortcut sheet, in the same declaration order as
/// `src/lib/shortcuts.ts`. Mirrored locally instead of importing
/// `app/shell.dart`, which imports this page — a back-import would close the
/// cycle the shell's docs warn about.
const List<({List<String> keys, String labelKey})> _kShortcuts = [
  (keys: ['Ctrl', '1…5'], labelKey: 'shortcuts.pageSwitch'),
  (keys: ['?'], labelKey: 'shortcuts.help'),
  (keys: ['/'], labelKey: 'settings.shortcutSearch'),
  (keys: ['n'], labelKey: 'settings.shortcutAdd'),
  (keys: ['空格'], labelKey: 'settings.shortcutFlip'),
  (keys: ['1', '2', '3'], labelKey: 'shortcuts.grade'),
  (keys: ['Ctrl', 'Z'], labelKey: 'shortcuts.undo'),
  (keys: ['←', '→'], labelKey: 'shortcuts.skip'),
  (keys: ['Esc'], labelKey: 'shortcuts.closeModal'),
];

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  /// Unsubscribe from [appSpeech]'s voice-list changes; see [initState].
  VoidCallback? _offVoices;

  @override
  void initState() {
    super.initState();
    // The voice list arrives asynchronously (Android's engine answers nothing
    // until it has initialised), so the page subscribes instead of reading it
    // once — the same shape `onVoicesChanged` had in the web build.
    _offVoices = appSpeech.onVoicesChanged(() {
      if (mounted) setState(() {});
    });
    // Idempotent; a no-op when another page already warmed the engine.
    appSpeech.warmUp();
  }

  @override
  void dispose() {
    _offVoices?.call();
    super.dispose();
  }

  void _patch(Settings Function(Settings s) fn) => context.store.updateSettings(fn);

  /// Language whose voices the picker should offer: the first list's source
  /// language, exactly as `SettingsPage.tsx:42` derived `studyLang`.
  String _studyLang(AppData data) =>
      data.lists.isNotEmpty ? data.lists.first.sourceLang : 'en';

  /// Says one sample sentence through the currently selected voice, so the
  /// picker has audible feedback before the user meets it on a card.
  Future<void> _testVoice() async {
    final settings = context.data.settings;
    final lang = _studyLang(context.data);
    await appSpeech.speak(
      context.t('settings.voiceSample'),
      lang: lang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI,
    );
  }

  Future<void> _wipe() async {
    // Both are read before the dialog's await: `context` must not be touched
    // across an async gap, and neither of these depends on the outcome.
    final store = context.store;
    final doneMessage = context.t('settings.wipeDone');
    final ok = await confirmLex(
      context,
      title: context.t('settings.wipeConfirm'),
      subtitle: context.t('settings.wipeConfirmBody'),
      confirmLabel: context.t('settings.wipeData'),
      cancelLabel: context.t('common.cancel'),
      danger: true,
    );
    if (!ok) return;
    await store.wipeAll();
    if (!mounted) return;
    context.toast(doneMessage, ToastKind.ok);
  }

  /* ---------------------------------------------------------------- */
  /* Export                                                           */
  /* ---------------------------------------------------------------- */

  /// Writes the whole snapshot out as JSON.
  ///
  /// The toast is only shown once [fileDialogs] reports the bytes landed; a
  /// cancel is silent, because a dialog the user dismissed is not a failure.
  Future<void> _exportJson() async {
    final data = context.data;
    final name = exportJsonFilename();
    final content = exportJson(data);
    final okMessage = context.t('settings.exportJsonDone');
    final failedMessage = context.t('settings.exportFailed');

    final saved = await fileDialogs.saveTextFile(
      suggestedName: name,
      content: content,
      mimeType: 'application/json',
    );
    if (!mounted || !saved) {
      if (mounted && !saved) {
        // A cancel and a write failure both come back false. The dialog layer
        // cannot tell them apart — Android's channel reports only the write —
        // so the message names the one thing the user can act on.
        context.toast(failedMessage, ToastKind.err);
      }
      return;
    }
    context.toast(okMessage, ToastKind.ok);
  }

  /// Writes the words as a CSV a spreadsheet can open.
  Future<void> _exportCsv() async {
    final data = context.data;
    final name = exportCsvFilename();
    final content = exportCsv(data.words);
    final okMessage = context.t('settings.exportCsvDone');
    final failedMessage = context.t('settings.exportFailed');

    final saved = await fileDialogs.saveTextFile(
      suggestedName: name,
      content: content,
      mimeType: 'text/csv',
    );
    if (!mounted || !saved) {
      if (mounted && !saved) {
        context.toast(failedMessage, ToastKind.err);
      }
      return;
    }
    context.toast(okMessage, ToastKind.ok);
  }

  /* ---------------------------------------------------------------- */
  /* Import                                                           */
  /* ---------------------------------------------------------------- */

  /// Picks a file, parses it, and shows what would be added before adding it.
  ///
  /// The preview is not a nicety: importing is the one operation here that can
  /// touch hundreds of words at once, and the parsers are forgiving by design
  /// (a file with no recognisable header is read as term-in-column-one). The
  /// user should see the result of that forgiveness before it is committed.
  Future<void> _pickImport() async {
    final listId =
        context.data.lists.isNotEmpty ? context.data.lists.first.id : DEFAULT_LIST_ID;

    final picked = await fileDialogs.pickTextFile();
    if (!mounted || picked == null) return;

    final result = parseImport(picked.text, listId);
    if (result.format == ImportFormat.unknown || result.words.isEmpty) {
      context.toast(
        context.t('settings.importFailed', {
          'msg': context.t('settings.importUnrecognised'),
        }),
        ToastKind.err,
      );
      return;
    }

    final confirmed = await showLexModal<bool>(
      context: context,
      title: context.t('settings.importPreviewTitle'),
      subtitle: '${picked.name} · ${_formatLabel(context, result.format)}',
      width: 520,
      body: _ImportPreview(result: result),
      footer: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          LexButton(
            label: context.t('common.cancel'),
            kind: BtnKind.ghost,
            onPressed: () => Navigator.of(context).pop(false),
          ),
          const SizedBox(width: Sp.x2),
          LexButton(
            label: '${context.t('common.import')} · ${result.words.length}',
            kind: BtnKind.primary,
            onPressed: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;

    _commitImport(result);
  }

  /// Adds the parsed words, skipping terms already in the library.
  ///
  /// Duplicates are matched with [findDuplicate], the same function the word
  /// editor uses to warn about them — so "duplicate" means the same thing
  /// whether the word arrived from a form or a file.
  void _commitImport(ImportResult result) {
    final store = context.store;
    final data = context.data;
    final listId = data.lists.isNotEmpty ? data.lists.first.id : DEFAULT_LIST_ID;

    var added = 0;
    var duplicated = 0;
    for (final word in result.words) {
      if (findDuplicate(store.data, word.term, listId) != null) {
        duplicated += 1;
        continue;
      }
      store.addWord(word);
      added += 1;
    }

    if (added > 0) {
      context.toast(context.t('settings.importSuccess', {'n': added}), ToastKind.ok);
    }
    if (duplicated > 0) {
      context.toast(
        context.t('settings.importSkippedDuplicates', {'n': duplicated}),
        ToastKind.info,
      );
    }
    if (added == 0 && duplicated == 0) {
      context.toast(
        context.t('settings.importFailed', {'msg': context.t('settings.importNothing')}),
        ToastKind.err,
      );
    }
  }

  /// How a recognised format is named in the preview's subtitle.
  static String _formatLabel(BuildContext context, ImportFormat format) =>
      switch (format) {
        ImportFormat.json => context.t('settings.formatJson'),
        ImportFormat.csv => 'CSV',
        ImportFormat.anki => 'Anki TXT',
        ImportFormat.unknown => context.t('settings.formatUnknown'),
      };


  @override
  Widget build(BuildContext context) {
    final data = context.data;
    final settings = data.settings;
    final p = Palette.of(context);

    return PageShell(
      title: context.t('settings.title'),
      subtitle: context.t('settings.subtitle'),
      controller: widget.controller,
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: Card(
            padding: EdgeInsets.zero,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _Section(
                  icon: Ic.sun,
                  title: context.t('settings.appearance'),
                  children: [
                    _Row(
                      label: context.t('settings.theme'),
                      hint: context.t('settings.themeHint'),
                      control: Segmented<ThemeMode_>(
                        value: settings.theme,
                        options: [
                          SegOption(value: ThemeMode_.light, label: context.t('common.light')),
                          SegOption(value: ThemeMode_.dark, label: context.t('common.dark')),
                          SegOption(value: ThemeMode_.system, label: context.t('common.system')),
                        ],
                        onChanged: (theme) => _patch((s) => s.copyWith(theme: theme)),
                      ),
                    ),
                    _Row(
                      label: context.t('settings.language'),
                      hint: context.t('settings.languageHint'),
                      control: Segmented<UiLang>(
                        value: settings.uiLang,
                        options: const [
                          SegOption(value: UiLang.zhCN, label: '中文'),
                          SegOption(value: UiLang.en, label: 'English'),
                        ],
                        onChanged: (uiLang) => _patch((s) => s.copyWith(uiLang: uiLang)),
                      ),
                    ),
                  ],
                ),
                _Divider(color: p.line),
                _Section(
                  icon: Ic.target,
                  title: context.t('settings.study'),
                  children: [
                    _Row(
                      label: context.t('settings.dailyGoal'),
                      hint: context.t('settings.dailyGoalHint'),
                      control: _NumberField(
                        value: settings.dailyGoal,
                        min: 1,
                        max: 500,
                        onChanged: (n) => _patch((s) => s.copyWith(dailyGoal: n)),
                      ),
                    ),
                    _Row(
                      label: context.t('settings.newCardsPerDay'),
                      hint: context.t('settings.newCardsHint'),
                      control: _NumberField(
                        value: settings.newCardsPerDay,
                        min: 0,
                        max: 200,
                        onChanged: (n) => _patch((s) => s.copyWith(newCardsPerDay: n)),
                      ),
                    ),
                    _Row(
                      label: context.t('settings.reviewOrder'),
                      hint: context.t('settings.orderHint'),
                      control: Segmented<String>(
                        value: settings.reviewOrder,
                        options: [
                          SegOption(value: 'due', label: context.t('settings.orderDue')),
                          SegOption(value: 'random', label: context.t('settings.orderRandom')),
                        ],
                        onChanged: (order) => _patch((s) => s.copyWith(reviewOrder: order)),
                      ),
                    ),
                  ],
                ),
                _Divider(color: p.line),
                _Section(
                  icon: Ic.volume,
                  title: context.t('settings.audio'),
                  // Only note the absence once the engine has actually said no;
                  // before warm-up `supported` answers true on purpose so the
                  // picker does not flash in and out.
                  note: appSpeech.supported ? null : context.t('settings.noVoice'),
                  children: [
                    _Row(
                      label: context.t('settings.ttsVoice'),
                      hint: context.t('settings.voiceHint'),
                      control: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 260 is the desktop width that fits a voice name
                          // without truncating it, not a floor: on a phone the
                          // stacked row is ~297 wide and a fixed 260 plus the
                          // test button overflowed the row by 40px. `Flexible`
                          // lets the select take what is left and ellipsise,
                          // which is what a select is for.
                          Flexible(
                            child: SizedBox(
                              width: 260,
                              child: LexSelect<String>(
                              value: settings.ttsVoiceURI,
                              // '' is the "automatic" entry, so the persisted
                              // value always matches an option even after the
                              // chosen voice was uninstalled.
                              options: [
                                '',
                                for (final v in appSpeech.voicesForLang(_studyLang(data)))
                                  v.uri,
                              ],
                              onChanged: (uri) => _patch((s) => s.copyWith(ttsVoiceURI: uri)),
                              labelOf: (uri) {
                                if (uri.isEmpty) return context.t('settings.ttsVoiceAuto');
                                for (final v in appSpeech.voicesForLang(_studyLang(data))) {
                                  if (v.uri == uri) return '${v.name} · ${v.lang}';
                                }
                                return uri;
                              },
                              ),
                            ),
                          ),
                          const SizedBox(width: Sp.x2),
                          LexButton(
                            label: context.t('settings.testVoice'),
                            kind: BtnKind.quiet,
                            size: BtnSize.sm,
                            icon: Ic.volume,
                            onPressed: appSpeech.supported ? _testVoice : null,
                          ),
                        ],
                      ),
                    ),
                    _Row(
                      label: context.t('settings.ttsRate'),
                      hint: context.t('settings.rateHint'),
                      control: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Same reason as the voice row: 200 is the desktop
                          // track length, not a minimum. A slider that cannot
                          // shrink is a slider whose row overflows.
                          Flexible(
                            child: SizedBox(
                              width: 200,
                              child: _RateSlider(
                                value: settings.ttsRate.clamp(0.5, 1.5),
                                min: 0.5,
                                max: 1.5,
                                onChanged: (rate) => _patch((s) => s.copyWith(ttsRate: rate)),
                              ),
                            ),
                          ),
                          const SizedBox(width: Sp.x2),
                          SizedBox(
                            width: 52,
                            child: Text(
                              '${settings.ttsRate.toStringAsFixed(2)}×',
                              textAlign: TextAlign.right,
                              style: TextStyle(
                                fontFamily: Fonts.mono,
                                fontSize: Fs.sm,
                                height: Lh.snug,
                                color: p.ink2,
                                fontFeatures: const [FontFeature.tabularFigures()],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    _Row(
                      label: context.t('settings.autoPlay'),
                      hint: context.t('settings.autoPlayHint'),
                      control: _LexSwitch(
                        checked: settings.autoPlayAudio,
                        label: context.t('settings.autoPlay'),
                        onChanged: (v) => _patch((s) => s.copyWith(autoPlayAudio: v)),
                      ),
                    ),
                    _Row(
                      label: context.t('settings.audioFirst'),
                      hint: context.t('settings.audioFirstHint'),
                      control: _LexSwitch(
                        checked: settings.audioFirst,
                        label: context.t('settings.audioFirst'),
                        onChanged: (v) => _patch((s) => s.copyWith(audioFirst: v)),
                      ),
                    ),
                  ],
                ),
                _Divider(color: p.line),
                // The web page's dictionary section managed a lookup cache that
                // lived in `src/lib/translate.ts`. That client did not come
                // across, so there is no cache to size or clear and the section
                // is omitted rather than shown empty.
                _SyncSection(autoSync: settings.autoSync, onAutoSync: (v) => _patch((s) => s.copyWith(autoSync: v))),
                _Divider(color: p.line),
                _Section(
                  icon: Ic.layers,
                  title: context.t('settings.data'),
                  note: context.t('settings.dataNote', {
                    'words': data.words.length,
                    'logs': data.logs.length,
                  }),
                  children: [
                    _Row(
                      label: context.t('settings.syncPending'),
                      hint: context.t('settings.syncPendingHint', {'n': data.pending.total()}),
                      control: const SizedBox.shrink(),
                    ),
                    // Export and import are two rows, matching the web build's
                    // four buttons collapsed into the pair that is actually
                    // useful: a full snapshot out, and any supported file in.
                    // Anki export is gone — the web build never had it either,
                    // only Anki *import*.
                    _Row(
                      label: context.t('settings.exportJson'),
                      hint: context.t('settings.exportJsonHint'),
                      control: LexButton(
                        label: context.t('common.export'),
                        kind: BtnKind.normal,
                        size: BtnSize.sm,
                        icon: Ic.download,
                        onPressed: _exportJson,
                      ),
                    ),
                    _Row(
                      label: context.t('settings.exportCsv'),
                      hint: context.t('settings.exportCsvHint'),
                      control: LexButton(
                        label: context.t('common.export'),
                        kind: BtnKind.normal,
                        size: BtnSize.sm,
                        icon: Ic.download,
                        onPressed: _exportCsv,
                      ),
                    ),
                    _Row(
                      label: context.t('settings.importData'),
                      hint: context.t('settings.importHint'),
                      control: LexButton(
                        label: context.t('common.import'),
                        kind: BtnKind.normal,
                        size: BtnSize.sm,
                        icon: Ic.upload,
                        onPressed: _pickImport,
                      ),
                    ),
                    _Notice(
                      icon: Ic.alert,
                      title: context.t('settings.wipeData'),
                      body: context.t('settings.wipeConfirmBody'),
                      action: LexButton(
                        label: context.t('settings.wipeData'),
                        kind: BtnKind.danger,
                        size: BtnSize.sm,
                        onPressed: _wipe,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Sp.x5),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 880),
          child: _AboutCard(),
        ),
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* Section / row / divider — the web build's parts.tsx                  */
/* ------------------------------------------------------------------ */

class _Section extends StatelessWidget {
  const _Section({required this.icon, required this.title, this.note, required this.children});

  final String icon;
  final String title;
  final String? note;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Padding(
      padding: const EdgeInsets.all(Sp.x5),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x2),
            child: Row(
              children: [
                LexIcon(icon, size: 14, color: p.ink3),
                const SizedBox(width: Sp.x2),
                Flexible(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: Fs.sm,
                      height: Lh.tight,
                      fontWeight: FontWeight.w500,
                      color: p.ink2,
                    ),
                  ),
                ),
                if (note != null) ...[
                  const SizedBox(width: Sp.x2),
                  Flexible(
                    child: Text(
                      note!,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontFamily: Fonts.mono,
                        fontSize: Fs.xs,
                        height: Lh.tight,
                        color: p.ink3,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          /* Rows sit 2px apart and bleed horizontally so their hover tint
             reaches the card's padding edge, exactly like `.set-rows`. */
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 2),
                children[i],
              ],
            ],
          ),
        ],
      ),
    );
  }
}

/// `label + hint` on the left, a control on the right.
class _Row extends StatefulWidget {
  const _Row({required this.label, this.hint, required this.control});

  final String label;
  final String? hint;
  final Widget control;

  @override
  State<_Row> createState() => _RowState();
}

class _RowState extends State<_Row> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: Motion.dur1,
        curve: Motion.ease,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
        decoration: BoxDecoration(
          // `null` rather than a literal transparent: the row has no fill at
          // rest, and the only colour this decoration ever carries comes from
          // the palette.
          color: _hover ? p.surface2 : null,
          borderRadius: R.borderSm,
        ),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final stacked = constraints.maxWidth < 520;
            final text = Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                    fontSize: Fs.base,
                    height: Lh.tight,
                    fontWeight: FontWeight.w500,
                    color: p.ink,
                  ),
                ),
                if (widget.hint != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.hint!,
                    style: TextStyle(fontSize: Fs.xs, height: Lh.body, color: p.ink3),
                  ),
                ],
              ],
            );
            if (stacked) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  text,
                  const SizedBox(height: Sp.x2),
                  widget.control,
                ],
              );
            }
            return Row(
              children: [
                Expanded(child: text),
                const SizedBox(width: Sp.x4),
                widget.control,
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => Container(height: 1, color: color);
}

/// A left-aligned integer field. [value] is the store's number; the field keeps
/// its own controller so a clamped write cannot yank the caret mid-edit.
class _NumberField extends StatefulWidget {
  const _NumberField({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  @override
  State<_NumberField> createState() => _NumberFieldState();
}

class _NumberFieldState extends State<_NumberField> {
  late final TextEditingController _controller = TextEditingController(text: '${widget.value}');
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _focus.addListener(() {
      // Leaving an empty field must not strand the setting on nothing: put the
      // stored value back before the blur is visible.
      if (!_focus.hasFocus) _controller.text = '${widget.value}';
    });
  }

  @override
  void didUpdateWidget(_NumberField old) {
    super.didUpdateWidget(old);
    if (widget.value != old.value && int.tryParse(_controller.text) != widget.value) {
      _controller.text = '${widget.value}';
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 92,
      child: LexInput(
        controller: _controller,
        focusNode: _focus,
        numeric: true,
        onChanged: (raw) {
          final n = int.tryParse(raw);
          if (n == null) return;
          final clamped = clamp(n, widget.min, widget.max).toInt();
          if (clamped != n) {
            _controller.text = '$clamped';
            _controller.selection = TextSelection.collapsed(offset: '$clamped'.length);
          }
          widget.onChanged(clamped);
        },
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Notices                                                             */
/* ------------------------------------------------------------------ */

/// The web build's `.notice`: an icon column and a tinted body.
///
/// Only the danger tone survives: the accent tone said "this feature is
/// missing", and nothing is missing any more. One tone means no enum.
class _Notice extends StatelessWidget {
  const _Notice({
    required this.icon,
    required this.title,
    required this.body,
    this.action,
  });

  final String icon;
  final String title;
  final String body;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      margin: const EdgeInsets.only(top: Sp.x4),
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        color: p.dangerSoft,
        borderRadius: R.borderSm,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: LexIcon(icon, size: 16, color: p.danger),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: Fs.sm,
                    height: Lh.body,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink2),
                ),
                if (action != null) ...[
                  const SizedBox(height: Sp.x3),
                  action!,
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Controls the design system does not ship                            */
/* ------------------------------------------------------------------ */

/// The web build's `.switch`.
///
/// Material's [Switch] is not an option here: it ships a 48px touch target, a
/// ripple, its own thumb shadow and a colour-scheme mapping, so it reads as a
/// foreign object on this page. This is 42×24 with a 2px inset knob and a
/// 120ms border tint on hover, matching `.switch` exactly.
class _LexSwitch extends StatefulWidget {
  const _LexSwitch({required this.checked, required this.label, required this.onChanged});

  final bool checked;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  State<_LexSwitch> createState() => _LexSwitchState();
}

class _LexSwitchState extends State<_LexSwitch> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final on = widget.checked;
    return Semantics(
      toggled: on,
      label: widget.label,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => setState(() => _down = true),
          onTapCancel: () => setState(() => _down = false),
          onTap: () {
            setState(() => _down = false);
            widget.onChanged(!on);
          },
          child: TapTarget(
            child: AnimatedScale(
              scale: _down ? 0.96 : 1,
              duration: Motion.dur1,
              curve: Motion.ease,
              child: AnimatedContainer(
                duration: Motion.dur2,
                curve: Motion.ease,
                width: 42,
                height: 24,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: on ? p.accent : p.surface2,
                  borderRadius: BorderRadius.circular(R.full),
                  border: Border.all(color: on ? p.accent : (_hover ? p.accent : p.lineStrong)),
                ),
                child: AnimatedAlign(
                  alignment: on ? Alignment.centerRight : Alignment.centerLeft,
                  duration: Motion.dur2,
                  curve: Motion.easeOut,
                  child: Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: on ? p.onAccent : p.surface,
                      shape: BoxShape.circle,
                      // `.switch-knob` carries `--shadow-xs`, which tokens.css
                      // sets to `none` — the knob's separation comes from the
                      // track colour, so no shadow is drawn here either.
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The web build's `.range` slider: a 6px track, a 16px accent thumb ringed in
/// the surface colour, no Material overlay.
class _RateSlider extends StatefulWidget {
  const _RateSlider({
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
  });

  final double value;
  final double min;
  final double max;
  final ValueChanged<double> onChanged;

  @override
  State<_RateSlider> createState() => _RateSliderState();
}

class _RateSliderState extends State<_RateSlider> {
  bool _hover = false;

  /// 0.5→1.5 in 0.05 steps is the web build's `step`; snapping in the painter
  /// keeps the thumb on the same 21 positions the browser gave it.
  double _snap(double raw) {
    final steps = ((widget.max - widget.min) / 0.05).round();
    final t = ((raw - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0);
    return widget.min + (t * steps).round() * 0.05;
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Semantics(
      slider: true,
      value: widget.value.toStringAsFixed(2),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: SizedBox(
          // A slider is dragged, not tapped, so growing only a ring around a
          // 20dp band would leave the drag surface unchanged. The band itself
          // grows on touch; `_TrackPainter` draws at `size.height / 2`, so the
          // 6px track and 16px thumb stay exactly where they were, centred in
          // the taller box, and nothing new becomes visible.
          height: context.isTouch ? Layout.tap : 20,
          child: LayoutBuilder(
            builder: (context, constraints) {
              void emit(double dx) {
                if (constraints.maxWidth <= 0) return;
                final t = (dx / constraints.maxWidth).clamp(0.0, 1.0);
                widget.onChanged(_snap(widget.min + t * (widget.max - widget.min)));
              }

              return GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTapDown: (d) => emit(d.localPosition.dx),
                onHorizontalDragStart: (d) => emit(d.localPosition.dx),
                onHorizontalDragUpdate: (d) => emit(d.localPosition.dx),
                child: CustomPaint(
                  painter: _TrackPainter(
                    t: ((widget.value - widget.min) / (widget.max - widget.min)).clamp(0.0, 1.0),
                    track: p.line,
                    thumb: p.accent,
                    ring: p.surface,
                    grow: _hover ? 1.08 : 1.0,
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

class _TrackPainter extends CustomPainter {
  const _TrackPainter({
    required this.t,
    required this.track,
    required this.thumb,
    required this.ring,
    required this.grow,
  });

  final double t;
  final Color track;
  final Color thumb;
  final Color ring;
  final double grow;

  @override
  void paint(Canvas canvas, Size size) {
    // `.range`: a 6px track, a 16px thumb with a 2px surface-coloured border.
    // The border is drawn as a stroked ring rather than a filled circle with a
    // shadow, because `--shadow-xs` is `none` in this design system — the ring
    // is the whole separation device.
    const trackH = 6.0;
    final cy = size.height / 2;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(0, cy - trackH / 2, size.width, trackH),
        const Radius.circular(R.full),
      ),
      Paint()..color = track,
    );
    final r = 8 * grow;
    final cx = r + (size.width - r * 2) * t;
    final center = Offset(cx, cy);
    canvas.drawCircle(center, r - 2, Paint()..color = thumb);
    canvas.drawCircle(
      center,
      r - 1,
      Paint()
        ..color = ring
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_TrackPainter old) =>
      old.t != t || old.track != track || old.thumb != thumb || old.ring != ring || old.grow != grow;
}

/* ------------------------------------------------------------------ */
/* Account & sync                                                       */
/* ------------------------------------------------------------------ */

/// The signed-out form: server, email, password, and three buttons.
///
/// These controllers exist only while signed out, so a password never sits in
/// memory past the request that used it — the token is the thing worth keeping.
class _SignInForm extends StatefulWidget {
  const _SignInForm({
    required this.busy,
    required this.server,
    required this.initialKey,
    required this.onServerChanged,
    required this.onSignIn,
    required this.onSignUp,
    required this.onTest,
  });

  final bool busy;

  /// Owned by the parent so the value survives the form being rebuilt after a
  /// failed attempt (the failure does not tear the field down).
  final TextEditingController server;

  /// The project key of the session that was just signed out of, if any.
  ///
  /// Passed in rather than read from the engine because signing out clears
  /// the session — including its key — before this form is built. Without the
  /// seed the user would have to paste the key again on every sign-in, which
  /// for a 200-character opaque string is enough friction to abandon sync.
  final String initialKey;
  final ValueChanged<String> onServerChanged;
  final void Function(String server, String email, String password, String anonKey)
      onSignIn;
  final void Function(String server, String email, String password, String anonKey)
      onSignUp;
  final void Function(String server) onTest;

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<_SignInForm> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();

  /// The Supabase project key. Seeded from the saved session so a user who
  /// signed out does not have to paste it again.
  late final TextEditingController _key;

  @override
  void initState() {
    super.initState();
    _key = TextEditingController(text: widget.initialKey);
    // The key field only exists while the server is a Supabase one, so the
    // visibility has to update as the user types the address.
    widget.server.addListener(_onServerTyped);
  }

  @override
  void dispose() {
    widget.server.removeListener(_onServerTyped);
    _email.dispose();
    _password.dispose();
    _key.dispose();
    super.dispose();
  }

  void _onServerTyped() => setState(() {});

  String get _server => widget.server.text.trim();
  String get _emailText => _email.text.trim();
  String get _keyText => _key.text.trim();

  /// Whether the address the user typed points at a Supabase project.
  ///
  /// Recomputed from the field on every build rather than stored: the field
  /// is the single source of truth, and a stale flag would show or hide the
  /// key at the wrong moment.
  bool get _isSupabase => detectBackend(_server) == SyncBackend.supabase;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: Sp.x4, bottom: Sp.x2),
          child: Text(
            context.t('settings.syncIntro'),
            style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink2),
          ),
        ),
        LexField(
          label: context.t('settings.syncServer'),
          hint: context.t('settings.syncServerHint'),
          child: LexInput(
            controller: widget.server,
            placeholder: kDefaultServer,
            onChanged: widget.onServerChanged,
          ),
        ),
        if (_isSupabase) ...[
          const SizedBox(height: Sp.x3),
          LexField(
            label: context.t('settings.syncKey'),
            hint: context.t('settings.syncKeyHint'),
            child: LexInput(
              controller: _key,
              placeholder: 'eyJhbGciOi…',
              onSubmitted: (_) =>
                  widget.onSignIn(_server, _emailText, _password.text, _keyText),
            ),
          ),
        ],
        const SizedBox(height: Sp.x3),
        LexField(
          label: context.t('settings.syncEmail'),
          child: LexInput(
            controller: _email,
            placeholder: 'you@example.com',
            onSubmitted: (_) =>
                widget.onSignIn(_server, _emailText, _password.text, _keyText),
          ),
        ),
        const SizedBox(height: Sp.x3),
        LexField(
          label: context.t('settings.syncPassword'),
          hint: context.t('settings.syncPasswordHint'),
          child: LexInput(
            controller: _password,
            obscure: true,
            onSubmitted: (_) =>
                widget.onSignIn(_server, _emailText, _password.text, _keyText),
          ),
        ),
        const SizedBox(height: Sp.x4),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            LexButton(
              label: context.t('settings.syncSignIn'),
              kind: BtnKind.primary,
              onPressed: widget.busy
                ? null
                : () => widget.onSignIn(_server, _emailText, _password.text, _keyText),
            ),
            LexButton(
              label: context.t('settings.syncSignUp'),
              onPressed: widget.busy
                ? null
                : () => widget.onSignUp(_server, _emailText, _password.text, _keyText),
            ),
            LexButton(
              label: context.t('settings.syncTest'),
              kind: BtnKind.ghost,
              onPressed: widget.busy ? null : () => widget.onTest(_server),
            ),
          ],
        ),
      ],
    );
  }
}

/// Account and sync. Ports `SyncSection.tsx`.
///
/// Two shapes: signed out shows the form, signed in shows who you are, what the
/// last round did, and the two actions. The state comes from [SyncScope], which
/// republishes whenever the engine changes, so this widget holds almost no state
/// of its own — only "a form submit is in flight" and the last form error.
class _SyncSection extends StatefulWidget {
  const _SyncSection({required this.autoSync, required this.onAutoSync});

  final bool autoSync;
  final ValueChanged<bool> onAutoSync;

  @override
  State<_SyncSection> createState() => _SyncSectionState();
}

class _SyncSectionState extends State<_SyncSection> {
  /// A login/register round is in flight. Separate from [SyncState.syncing],
  /// which is about data rounds, not auth.
  bool _busy = false;

  /// Kept on screen instead of a toast: an auth failure is the kind of message
  /// the user needs while fixing the field it refers to.
  SyncError? _formError;

  /// The server field outlives a failed submit.
  ///
  /// Created in [initState] rather than lazily: a `late final` initialiser runs
  /// on first *read*, and when the user is already signed in the field is never
  /// built — so the first read would be [dispose]'s, from a deactivated element,
  /// where `context` is no longer safe to touch. Signing out of a live app would
  /// then throw.
  late final TextEditingController _server;

  /// The project key of the session this page was opened with.
  ///
  /// Captured in [initState], while the session still exists: signing out
  /// wipes it, and the sign-in form that comes back afterwards would
  /// otherwise start with an empty key field every time.
  late final String _savedKey;

  @override
  void initState() {
    super.initState();
    // The dependency-free read: `syncStatus` would subscribe, and subscribing
    // in initState is what `dependOnInheritedWidgetOfExactType` forbids.
    final status = context.syncEngine?.status;
    _server = TextEditingController(text: status?.server ?? kDefaultServer);
    _savedKey = status?.anonKey ?? '';
  }

  @override
  void dispose() {
    _server.dispose();
    super.dispose();
  }

  Future<void> _formAction(Future<void> Function(SyncEngine engine) action) async {
    final engine = context.syncEngine;
    if (engine == null || _busy) return;
    setState(() {
      _busy = true;
      _formError = null;
    });
    try {
      await action(engine);
      if (!mounted) return;
      context.toast(context.t('settings.syncDone'), ToastKind.ok);
    } on SyncHttpError catch (err) {
      if (!mounted) return;
      setState(() => _formError = err.kind);
    } catch (_) {
      if (!mounted) return;
      setState(() => _formError = SyncError.offline);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _test(String server) async {
    final engine = context.syncEngine;
    if (engine == null || _busy) return;
    setState(() => _busy = true);
    final ok = await engine.testConnection(server);
    if (!mounted) return;
    setState(() => _busy = false);
    context.toast(
      context.t(ok ? 'settings.syncTestOk' : 'settings.syncTestFail'),
      ok ? ToastKind.ok : ToastKind.err,
    );
  }

  Future<void> _syncNow() async {
    final engine = context.syncEngine;
    if (engine == null) return;
    final ok = await engine.syncNow();
    if (!mounted) return;
    final error = engine.status.error;
    if (ok) {
      context.toast(context.t('settings.syncDone'), ToastKind.ok);
    } else {
      context.toast(_errorLabel(context, error ?? SyncError.offline), ToastKind.err);
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final status = context.syncStatus;
    final signedIn = status?.isSignedIn ?? false;
    final state = status?.state ?? SyncState.signedOut;

    return _Section(
      icon: Ic.cloud,
      title: context.t('settings.sync'),
      children: [
        if (!signedIn)
          _SignInForm(
            busy: _busy,
            server: _server,
            initialKey: _savedKey,
            onServerChanged: (_) {},
            onSignIn: (server, email, password, anonKey) => _formAction(
                  (engine) => engine.login(server, email, password, anonKey: anonKey),
                ),
            onSignUp: (server, email, password, anonKey) => _formAction(
                  (engine) => engine.register(server, email, password, anonKey: anonKey),
                ),
            onTest: _test,
          )
        else ...[
          _Row(
            label: context.t('settings.syncStatus'),
            hint: _signedInAs(context, status!),
            control: _StatusPill(state: state),
          ),
          _Row(
            label: context.t('settings.syncPending'),
            hint: context.t('settings.syncPendingHint', {'n': status.pending}),
            control: const SizedBox.shrink(),
          ),
          _Row(
            label: context.t('settings.syncLastSync'),
            hint: _lastSyncLabel(context, status.lastSyncAt),
            control: const SizedBox.shrink(),
          ),
          if (state == SyncState.error && status.error != null)
            _Notice(
              icon: Ic.alert,
              title: context.t('settings.syncStatusError'),
              body: _errorLabel(context, status.error!),
            ),
          Padding(
            padding: const EdgeInsets.only(top: Sp.x4),
            child: Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                LexButton(
                  label: context.t('settings.syncNow'),
                  kind: BtnKind.primary,
                  onPressed: state == SyncState.syncing ? null : _syncNow,
                ),
                LexButton(
                  label: context.t('settings.syncSignOut'),
                  kind: BtnKind.ghost,
                  onPressed: () => _formAction((engine) => engine.signOut()),
                ),
              ],
            ),
          ),
        ],
        if (_formError != null)
          _Notice(
            icon: Ic.alert,
            title: context.t('settings.syncStatusError'),
            body: _errorLabel(context, _formError!),
          ),
        _Row(
          label: context.t('settings.syncAuto'),
          hint: context.t('settings.syncAutoHint'),
          control: _LexSwitch(
            checked: widget.autoSync,
            label: context.t('settings.syncAuto'),
            onChanged: widget.onAutoSync,
          ),
        ),
        Padding(
          padding: EdgeInsets.only(top: Sp.x3),
          child: Text(
            context.t('settings.syncTokenNote'),
            style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink3),
          ),
        ),
      ],
    );
  }

  static String _signedInAs(BuildContext context, SyncStatus status) => status.email.isEmpty
      ? context.t('settings.syncStatusSignedOut')
      : context.t('settings.syncSignedInAs', {'email': status.email});

  static String _lastSyncLabel(BuildContext context, int at) {
    if (at == 0) return context.t('settings.syncNever');
    final when = DateTime.fromMillisecondsSinceEpoch(at);
    String two(int n) => n.toString().padLeft(2, '0');
    return '${when.year}-${two(when.month)}-${two(when.day)} ${two(when.hour)}:${two(when.minute)}';
  }
}

/// Translate a [SyncError] into the sentence the user needs.
String _errorLabel(BuildContext context, SyncError error) => switch (error) {
      SyncError.offline => context.t('settings.syncErrorOffline'),
      SyncError.unauthorized => context.t('settings.syncErrorUnauthorized'),
      SyncError.server => context.t('settings.syncErrorServer'),
      SyncError.badCredentials => context.t('settings.syncErrorBadCredentials'),
      SyncError.emailTaken => context.t('settings.syncErrorEmailTaken'),
      SyncError.weakPassword => context.t('settings.syncErrorWeakPassword'),
      SyncError.invalidEmail => context.t('settings.syncErrorInvalidEmail'),
    };

/// A dot plus a word, so the state is readable without parsing a sentence.
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.state});

  final SyncState state;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final (Color tint, Color dot, String key) = switch (state) {
      SyncState.signedOut => (p.surface2, p.ink3, 'settings.syncStatusSignedOut'),
      SyncState.idle => (p.okSoft, p.ok, 'settings.syncStatusIdle'),
      SyncState.syncing => (p.accentSoft, p.accent, 'settings.syncStatusSyncing'),
      SyncState.error => (p.dangerSoft, p.danger, 'settings.syncStatusError'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 3),
      decoration: BoxDecoration(color: tint, borderRadius: R.borderSm),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
          ),
          const SizedBox(width: Sp.x2),
          Text(
            context.t(key),
            style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink2),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* About                                                               */
/* ------------------------------------------------------------------ */

class _AboutCard extends StatelessWidget {
  const _AboutCard();

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: R.borderLg,
        border: Border.all(color: p.line),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, Sp.x4),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  context.t('settings.about'),
                  style: TextStyle(
                    fontSize: Fs.md,
                    height: Lh.tight,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.005,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${context.t('common.appName')} · \u8bcd\u781a',
                  style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink3),
                ),
              ],
            ),
          ),
          Container(height: 1, color: p.line),
          Padding(
            padding: const EdgeInsets.all(Sp.x5),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Wrap(
                  spacing: Sp.x2,
                  runSpacing: Sp.x2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _Chip(text: '${context.t('settings.version')} 0.1.0'),
                    // The web build hardcoded its own stack names here rather
                    // than routing them through `t()` — they are proper nouns
                    // and read the same in both locales. The port states its
                    // own stack for the same reason.
                    Text(
                      'Flutter · Dart',
                      style: TextStyle(fontFamily: Fonts.mono, fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
                    ),
                  ],
                ),
                const SizedBox(height: Sp.x4),
                Text(
                  context.t('settings.madeWith'),
                  style: TextStyle(fontSize: Fs.sm, height: Lh.loose, color: p.ink2),
                ),
                const SizedBox(height: Sp.x4),
                /* AGPL-3.0 §7(b) additional term: this attribution must stay
                   visible. It is not decoration — do not remove or collapse it. */
                Container(
                  padding: const EdgeInsets.all(Sp.x3),
                  decoration: BoxDecoration(
                    color: p.surface2,
                    borderRadius: R.borderSm,
                    border: Border.all(color: p.line),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        'Lingueez, created by Yurii Lysak',
                        style: TextStyle(
                          fontSize: Fs.sm,
                          height: Lh.snug,
                          fontWeight: FontWeight.w500,
                          color: p.ink,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.t('settings.licenseNote'),
                        style: TextStyle(fontSize: Fs.sm, height: Lh.body, color: p.ink2),
                      ),
                    ],
                  ),
                ),
                // No keyboard, no legend: the whole section is a keycap
                // reference and would be unactionable on a phone.
                if (context.showsKeyHints) ...[
                  const SizedBox(height: Sp.x4),
                  Container(height: 1, color: p.line),
                  const SizedBox(height: Sp.x4),
                  Padding(
                    padding: const EdgeInsets.only(bottom: Sp.x2),
                    child: Text(
                      context.t('settings.shortcuts'),
                      style: TextStyle(
                        fontSize: Fs.sm,
                        height: Lh.tight,
                        fontWeight: FontWeight.w500,
                        color: p.ink2,
                      ),
                    ),
                  ),
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.maxWidth >= 700 ? 2 : 1;
                      if (columns == 1) {
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final row in _kShortcuts)
                              ShortcutRow(keys: row.keys, label: context.t(row.labelKey)),
                          ],
                        );
                      }
                      final rows = <Widget>[];
                      for (var i = 0; i < _kShortcuts.length; i += columns) {
                        rows.add(
                          Row(
                            children: [
                              Expanded(
                                child: ShortcutRow(
                                  keys: _kShortcuts[i].keys,
                                  label: context.t(_kShortcuts[i].labelKey),
                                ),
                              ),
                              const SizedBox(width: Sp.x6),
                              Expanded(
                                child: i + 1 < _kShortcuts.length
                                    ? ShortcutRow(
                                        keys: _kShortcuts[i + 1].keys,
                                        label: context.t(_kShortcuts[i + 1].labelKey),
                                      )
                                    : const SizedBox.shrink(),
                              ),
                            ],
                          ),
                        );
                      }
                      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
                    },
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The web build's `.chip.chip-meta`.
class _Chip extends StatelessWidget {
  const _Chip({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
      decoration: BoxDecoration(
        color: p.surface2,
        borderRadius: R.borderXs,
        border: Border.all(color: p.line),
      ),
      child: ContentCenter(
        child: Text(
          text,
          style: TextStyle(fontFamily: Fonts.mono, fontSize: Fs.xs, height: Lh.tight, color: p.ink2),
        ),
      ),
    );
  }
}

/// What an import would add, shown before it is committed.
///
/// Caps the visible rows at [_previewRows] and counts the rest: a file with
/// nine hundred words should not push the confirm button off the screen, and
/// the exact number matters more than the tail of the list.
class _ImportPreview extends StatelessWidget {
  const _ImportPreview({required this.result});

  final ImportResult result;

  static const int _previewRows = 8;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final shown = result.words.take(_previewRows).toList();
    final remaining = result.words.length - shown.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // The chips say what was recognised, which is the thing the user
        // cannot otherwise check: a CSV parsed as Anki looks identical in the
        // word list.
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            StatusChip(
              label: context.t('settings.importWordsCount', {'n': result.words.length}),
              tone: 'accent',
            ),
            if (result.skipped > 0)
              StatusChip(
                label: context.t('settings.importRowsSkipped', {'n': result.skipped}),
                tone: 'warn',
              ),
          ],
        ),
        const SizedBox(height: Sp.x4),
        for (final word in shown)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x2),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 180,
                  child: Text(
                    word.term,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: Fs.base,
                      height: Lh.snug,
                      fontWeight: FontWeight.w500,
                      color: p.ink,
                    ),
                  ),
                ),
                const SizedBox(width: Sp.x3),
                Expanded(
                  child: Text(
                    (word.definition ?? '').isEmpty ? '—' : word.definition!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: Fonts.ui,
                      fontSize: Fs.sm,
                      height: Lh.snug,
                      color: p.ink3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        if (remaining > 0)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x1),
            child: Text(
              context.t('settings.importMore', {'n': remaining}),
              style: TextStyle(
                fontFamily: Fonts.ui,
                fontSize: Fs.xs,
                height: Lh.snug,
                color: p.ink4,
              ),
            ),
          ),
      ],
    );
  }
}
