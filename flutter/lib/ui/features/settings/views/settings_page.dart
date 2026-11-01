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
/// [_SyncSection]). The dictionary lookup cache is real now — `platform/
/// translate.dart` keeps it on disk — so its section reports the entry count
/// and offers to clear it.
///
/// Export and import live under Data. They were absent until the Supabase work
/// started, for the honest reason that nothing could write a file; see
/// `platform/file_dialogs.dart` for what changed.
///
/// **Where the state went.** The draft values, the in-flight flags, the error
/// the form shows, the cache count and every async action now live in
/// [SettingsViewModel]; this file is the layout that reads them, plus the three
/// ports that connect the model to the process-wide speech engine, the lookup
/// cache and the import preview dialog. What is left here is the widget-layer
/// half of the screen: the `TextEditingController`s, the dialog body, and the
/// lifecycle wiring that builds the model and disposes it with the element.
library;

// `Card` is ours (ui/widgets.dart), not Material's.
import 'package:flutter/material.dart' hide Card;

import '../../../../app/scope.dart';
import '../../../../app/update_scope.dart';
import '../../../../data/models/sync_config.dart' show kDefaultServer;
import '../../../../data/repositories/sync_engine.dart';
import '../../../../data/repositories/update_service.dart';
import '../../../../data/services/transfer.dart' show ImportResult;
import '../../../../data/services/translate.dart' show defaultLookup;
import '../../../../data/services/tts.dart';
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../../domain/models/types.dart';
import '../../../../domain/models/utils.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/density.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../../update/views/update_sheet.dart';
import '../view_models/settings_view_model.dart';

/// One row of the shortcut sheet, in the same declaration order as
/// `src/lib/shortcuts.ts`. Mirrored locally instead of importing
/// `app/shell.dart`, which imports this page — a back-import would close the
/// cycle the shell's docs warn about.
const List<({List<String> keys, String labelKey})> _kShortcuts = [
  (keys: ['Ctrl', '1…6'], labelKey: 'shortcuts.pageSwitch'),
  (keys: ['?'], labelKey: 'shortcuts.help'),
  (keys: ['/'], labelKey: 'settings.shortcutSearch'),
  (keys: ['n'], labelKey: 'settings.shortcutAdd'),
  (keys: ['空格'], labelKey: 'settings.shortcutFlip'),
  (keys: ['1', '2', '3'], labelKey: 'shortcuts.grade'),
  (keys: ['Ctrl', 'Z'], labelKey: 'shortcuts.undo'),
  (keys: ['←', '→'], labelKey: 'shortcuts.skip'),
  (keys: ['Esc'], labelKey: 'shortcuts.closeModal'),
];

/* ------------------------------------------------------------------ */
/* Ports: the process-wide singletons, read at call time               */
/* ------------------------------------------------------------------ */

/// [SpeechPort] over the app's one `Speech` instance.
///
/// The port exists so [SettingsViewModel] can be tested without a platform
/// channel; this is the thin adapter the running app hands it. Every read goes
/// through [appSpeech] rather than a captured reference because
/// `debugSetSpeech` swaps that global in tests — a field assigned in the
/// constructor would freeze whichever engine was installed at page build.
class _AppSpeech implements SpeechPort {
  const _AppSpeech();

  @override
  bool get supported => appSpeech.supported;

  @override
  List<VoiceOption> voicesForLang(String lang) => [
        for (final voice in appSpeech.voicesForLang(lang))
          (uri: voice.uri, name: voice.name, lang: voice.lang),
      ];

  @override
  Future<void> warmUp() => appSpeech.warmUp();

  @override
  Future<void> speak(
    String text, {
    String? lang,
    double? rate,
    String? voiceURI,
  }) =>
      appSpeech.speak(text, lang: lang, rate: rate, voiceURI: voiceURI);

  @override
  VoidCallback onVoicesChanged(VoidCallback listener) =>
      appSpeech.onVoicesChanged(listener);
}

/// [LookupCachePort] over the app's one `Lookup`.
///
/// Same argument as [_AppSpeech]: `defaultLookup` is a global that
/// `debugSetLookup` replaces, so it is dereferenced per call rather than
/// captured.
class _DefaultLookupCache implements LookupCachePort {
  const _DefaultLookupCache();

  @override
  int cacheSize() => defaultLookup.cacheSize();

  @override
  void clearCache() => defaultLookup.clearCache();
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

/// Builds the model, hands it the three ports, and renders it.
///
/// Nothing here decides anything: the draft, the busy flags, the error, the
/// cache count and every action live in [SettingsViewModel]. What stays is the
/// widget-layer half — controllers, the dialog body, and the lifecycle wiring
/// that keeps the model's subscriptions exactly as long as the element's.
class _SettingsPageState extends State<SettingsPage> {
  /// The model. Built in [initState] so the subscriptions start with the page,
  /// and rebuilt by [didChangeDependencies] if the scopes hand it a different
  /// engine — a page re-pumped against a new `SyncScope` must talk to the new
  /// engine, exactly as the previous version did by reading the scope on every
  /// action.
  late SettingsViewModel _vm;

  /// The services [_vm] was built with, for the identity check below.
  SyncEngine? _engine;
  UpdateService? _update;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Register the dependencies explicitly. The identity reads below are the
    // non-subscribing ones, so without this the element would never be told
    // that a scope swapped its service — the page would keep driving the
    // engine it was first built against, which is exactly the bug the previous
    // version avoided by re-reading the scope on every action.
    SyncScope.statusOf(context);
    UpdateScope.stateOf(context);
    final engine = context.syncEngine;
    final update = context.update;
    if (identical(engine, _engine) && identical(update, _update)) return;
    final previous = _vm;
    _bind();
    previous.dispose();
  }

  /// Builds a model against whatever the scopes hold right now.
  ///
  /// The reads are the dependency-free ones: `context.syncStatus` would
  /// subscribe, and subscribing in [initState] is what
  /// `dependOnInheritedWidgetOfExactType` forbids. Both services are optional —
  /// a page pumped without a SyncScope or an UpdateScope renders the
  /// signed-out, version-less shape instead of throwing, which is what the
  /// widget tests rely on.
  void _bind() {
    _engine = context.syncEngine;
    _update = context.update;
    _vm = SettingsViewModel(
      store: context.store,
      feedback: ContextFeedback(context),
      speech: const _AppSpeech(),
      lookupCache: const _DefaultLookupCache(),
      previewImport: _previewImport,
      engine: _engine,
      update: _update,
    );
  }

  @override
  void dispose() {
    _vm.dispose();
    super.dispose();
  }

  /// The import preview dialog.
  ///
  /// Handed to the model as a callback because the dialog is a widget tree and
  /// the decision to show one is not: the model parses the file and asks, this
  /// draws the sheet and reports the answer. The body and footer are unchanged
  /// from the version that lived in this file.
  Future<bool> _previewImport(ImportPreviewRequest request) async {
    final result = request.result;
    final confirmed = await showLexModal<bool>(
      context: context,
      title: context.t('settings.importPreviewTitle'),
      subtitle: '${request.fileName} · ${request.formatLabel}',
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
    return confirmed == true;
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _vm,
      builder: (context, _) {
        final vm = _vm;
        final data = vm.data;
        final settings = vm.settings;
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
                            onChanged: (theme) => vm.patch((s) => s.copyWith(theme: theme)),
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
                            onChanged: (uiLang) => vm.patch((s) => s.copyWith(uiLang: uiLang)),
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
                            onChanged: (n) => vm.patch((s) => s.copyWith(dailyGoal: n)),
                          ),
                        ),
                        _Row(
                          label: context.t('settings.newCardsPerDay'),
                          hint: context.t('settings.newCardsHint'),
                          control: _NumberField(
                            value: settings.newCardsPerDay,
                            min: 0,
                            max: 200,
                            onChanged: (n) => vm.patch((s) => s.copyWith(newCardsPerDay: n)),
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
                            onChanged: (order) => vm.patch((s) => s.copyWith(reviewOrder: order)),
                          ),
                        ),
                      ],
                    ),
                    _Divider(color: p.line),
                    _Section(
                      icon: Ic.volume,
                      title: context.t('settings.audio'),
                      // Only note the absence once the engine has actually said
                      // no; before warm-up `supported` answers true on purpose so
                      // the picker does not flash in and out.
                      note: vm.speechSupported ? null : context.t('settings.noVoice'),
                      children: [
                        _Row(
                          label: context.t('settings.ttsVoice'),
                          hint: context.t('settings.voiceHint'),
                          control: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 260 is the desktop width that fits a voice name
                              // without truncating it, not a floor: on a phone
                              // the stacked row is ~297 wide and a fixed 260 plus
                              // the test button overflowed the row by 40px.
                              // `Flexible` lets the select take what is left and
                              // ellipsise, which is what a select is for.
                              Flexible(
                                child: SizedBox(
                                  width: 260,
                                  child: LexSelect<String>(
                                    value: settings.ttsVoiceURI,
                                    // '' is the "automatic" entry, so the
                                    // persisted value always matches an option
                                    // even after the chosen voice was
                                    // uninstalled.
                                    options: [
                                      '',
                                      for (final v in vm.voices) v.uri,
                                    ],
                                    onChanged: (uri) =>
                                        vm.patch((s) => s.copyWith(ttsVoiceURI: uri)),
                                    labelOf: vm.voiceLabel,
                                  ),
                                ),
                              ),
                              const SizedBox(width: Sp.x2),
                              LexButton(
                                label: context.t('settings.testVoice'),
                                kind: BtnKind.quiet,
                                size: BtnSize.sm,
                                icon: Ic.volume,
                                onPressed: vm.speechSupported ? vm.testVoice : null,
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
                              // Same reason as the voice row: 200 is the
                              // desktop track length, not a minimum. A slider
                              // that cannot shrink is a slider whose row
                              // overflows.
                              Flexible(
                                child: SizedBox(
                                  width: 200,
                                  child: _RateSlider(
                                    value: settings.ttsRate.clamp(0.5, 1.5),
                                    min: 0.5,
                                    max: 1.5,
                                    onChanged: (rate) =>
                                        vm.patch((s) => s.copyWith(ttsRate: rate)),
                                  ),
                                ),
                              ),
                              const SizedBox(width: Sp.x2),
                              // 52 was the width of "0.95×" at the old 12dp
                              // size; at the scale's `Fs.sm` it needs 66dp and
                              // wrapped, leaving the `×` alone on a second
                              // line, which reads as a stray bullet rather than
                              // a multiplier. Every value in 0.50–1.50 is five
                              // characters in tabular figures, so the natural
                              // width is constant and the box was buying
                              // nothing.
                              Text(
                                '${settings.ttsRate.toStringAsFixed(2)}×',
                                textAlign: TextAlign.right,
                                maxLines: 1,
                                softWrap: false,
                                style: TextStyle(
                                  fontFamily: Fonts.mono,
                                  fontSize: Fs.sm,
                                  height: Lh.snug,
                                  color: p.ink2,
                                  fontFeatures: const [FontFeature.tabularFigures()],
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
                            onChanged: (v) => vm.patch((s) => s.copyWith(autoPlayAudio: v)),
                          ),
                        ),
                        _Row(
                          label: context.t('settings.audioFirst'),
                          hint: context.t('settings.audioFirstHint'),
                          control: _LexSwitch(
                            checked: settings.audioFirst,
                            label: context.t('settings.audioFirst'),
                            onChanged: (v) => vm.patch((s) => s.copyWith(audioFirst: v)),
                          ),
                        ),
                      ],
                    ),
                    _Divider(color: p.line),
                    _Section(
                      icon: Ic.book,
                      title: context.t('settings.dictionary'),
                      // No `note` here. It carried the cache count, which the
                      // row below already says — on a phone the two sat 60dp
                      // apart and read as the same sentence printed twice, and
                      // the header copy had only 145dp to work with, so it
                      // wrapped while the row's copy did not.
                      children: [
                        _Row(
                          label: context.t('settings.translateCache'),
                          hint: context.t(
                            'settings.translateCacheHint',
                            {'n': vm.cacheSize},
                          ),
                          control: LexButton(
                            label: context.t('settings.clearCache'),
                            kind: BtnKind.normal,
                            size: BtnSize.sm,
                            // Nothing to clear is a real state on a fresh
                            // install, and a button that looks pressable but
                            // does nothing is worse than one that looks
                            // unavailable.
                            onPressed: vm.cacheSize == 0 ? null : vm.clearLookupCache,
                          ),
                        ),
                      ],
                    ),
                    _Divider(color: p.line),
                    _SyncSection(
                      vm: vm,
                      autoSync: settings.autoSync,
                      onAutoSync: (v) => vm.patch((s) => s.copyWith(autoSync: v)),
                    ),
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
                          hint: context.t(
                            'settings.syncPendingHint',
                            {'n': data.pending.total()},
                          ),
                          control: const SizedBox.shrink(),
                        ),
                        // Export and import are two rows, matching the web
                        // build's four buttons collapsed into the pair that is
                        // actually useful: a full snapshot out, and any
                        // supported file in. Anki export is gone — the web
                        // build never had it either, only Anki *import*.
                        _Row(
                          label: context.t('settings.exportJson'),
                          hint: context.t('settings.exportJsonHint'),
                          control: LexButton(
                            label: context.t('common.export'),
                            kind: BtnKind.normal,
                            size: BtnSize.sm,
                            icon: Ic.download,
                            onPressed: vm.exportJson,
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
                            onPressed: vm.exportCsv,
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
                            onPressed: vm.pickImport,
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
                            onPressed: vm.wipe,
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
              child: Card(
                // A stable handle for the widget tests: the card's own identity
                // is private to this file, and matching on its button label
                // would tie the tests to copy that is expected to change.
                key: const ValueKey('update-card'),
                padding: EdgeInsets.zero,
                child: _UpdateSection(
                  service: vm.updateService,
                  state: vm.updateState,
                ),
              ),
            ),
            const SizedBox(height: Sp.x5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: _AboutCard(
                version: vm.updateState?.current?.name.toString() ?? '—',
              ),
            ),
          ],
        );
      },
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
/// The *values* they hold are the view model's draft; the controllers are the
/// widget-layer half of it, which is why they live here.
class _SignInForm extends StatefulWidget {
  const _SignInForm({
    required this.vm,
    required this.busy,
  });

  final SettingsViewModel vm;
  final bool busy;

  @override
  State<_SignInForm> createState() => _SignInFormState();
}

class _SignInFormState extends State<_SignInForm> {
  /// Seeded from the view model's draft, which was itself seeded from the
  /// session this page was opened with. The field outlives a failed submit, so
  /// a mistyped password does not clear the address beside it.
  late final TextEditingController _server;
  late final TextEditingController _email;
  late final TextEditingController _password;

  /// The Supabase project key. Seeded from the saved session so a user who
  /// signed out does not have to paste it again.
  late final TextEditingController _key;

  @override
  void initState() {
    super.initState();
    final vm = widget.vm;
    _server = TextEditingController(text: vm.syncServer);
    _email = TextEditingController(text: vm.syncEmail);
    _password = TextEditingController(text: vm.syncPassword);
    _key = TextEditingController(text: vm.syncAnonKey);
  }

  @override
  void dispose() {
    _server.dispose();
    _email.dispose();
    _password.dispose();
    _key.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final vm = widget.vm;
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
            controller: _server,
            placeholder: kDefaultServer,
            onChanged: vm.setSyncServer,
          ),
        ),
        // The key field only exists while the server is a Supabase one, so the
        // visibility follows the draft as the user types the address.
        if (vm.syncIsSupabase) ...[
          const SizedBox(height: Sp.x3),
          LexField(
            label: context.t('settings.syncKey'),
            hint: context.t('settings.syncKeyHint'),
            child: LexInput(
              controller: _key,
              placeholder: 'eyJhbGciOi…',
              onChanged: vm.setSyncAnonKey,
              onSubmitted: (_) => vm.signIn(),
            ),
          ),
        ],
        const SizedBox(height: Sp.x3),
        LexField(
          label: context.t('settings.syncEmail'),
          child: LexInput(
            controller: _email,
            placeholder: 'you@example.com',
            onChanged: vm.setSyncEmail,
            onSubmitted: (_) => vm.signIn(),
          ),
        ),
        const SizedBox(height: Sp.x3),
        LexField(
          label: context.t('settings.syncPassword'),
          hint: context.t('settings.syncPasswordHint'),
          child: LexInput(
            controller: _password,
            obscure: true,
            onChanged: vm.setSyncPassword,
            onSubmitted: (_) => vm.signIn(),
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
              onPressed: widget.busy ? null : vm.signIn,
            ),
            LexButton(
              label: context.t('settings.syncSignUp'),
              onPressed: widget.busy ? null : vm.signUp,
            ),
            LexButton(
              label: context.t('settings.syncTest'),
              kind: BtnKind.ghost,
              onPressed: widget.busy ? null : vm.testConnection,
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
/// last round did, and the two actions. The state — the draft, the in-flight
/// latch, the last form error, the status itself — comes from
/// [SettingsViewModel], which republishes when the engine or the store changes,
/// so this widget is layout and nothing else.
class _SyncSection extends StatelessWidget {
  const _SyncSection({
    required this.vm,
    required this.autoSync,
    required this.onAutoSync,
  });

  final SettingsViewModel vm;
  final bool autoSync;
  final ValueChanged<bool> onAutoSync;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final status = vm.syncStatus;
    final signedIn = status?.isSignedIn ?? false;
    final state = status?.state ?? SyncState.signedOut;
    final formError = vm.syncFormError;

    return _Section(
      icon: Ic.cloud,
      title: context.t('settings.sync'),
      children: [
        if (!signedIn)
          _SignInForm(vm: vm, busy: vm.syncBusy)
        else ...[
          _Row(
            label: context.t('settings.syncStatus'),
            hint: vm.syncSignedInAs,
            control: _StatusPill(state: state),
          ),
          _Row(
            label: context.t('settings.syncPending'),
            hint: context.t('settings.syncPendingHint', {'n': status!.pending}),
            control: const SizedBox.shrink(),
          ),
          _Row(
            label: context.t('settings.syncLastSync'),
            hint: vm.syncLastSyncLabel,
            control: const SizedBox.shrink(),
          ),
          if (state == SyncState.error && status.error != null)
            _Notice(
              icon: Ic.alert,
              title: context.t('settings.syncStatusError'),
              body: vm.errorLabel(status.error!),
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
                  onPressed: state == SyncState.syncing ? null : vm.syncNow,
                ),
                LexButton(
                  label: context.t('settings.syncSignOut'),
                  kind: BtnKind.ghost,
                  onPressed: vm.signOut,
                ),
              ],
            ),
          ),
        ],
        if (formError != null)
          _Notice(
            icon: Ic.alert,
            title: context.t('settings.syncStatusError'),
            body: vm.errorLabel(formError),
          ),
        _Row(
          label: context.t('settings.syncAuto'),
          hint: context.t('settings.syncAutoHint'),
          control: _LexSwitch(
            checked: autoSync,
            label: context.t('settings.syncAuto'),
            onChanged: onAutoSync,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: Sp.x3),
          child: Text(
            context.t('settings.syncTokenNote'),
            style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink3),
          ),
        ),
      ],
    );
  }
}

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
/* Updates                                                             */
/* ------------------------------------------------------------------ */

/// The updates card: one row that names the running build and one button that
/// opens [showUpdateSheet].
///
/// It is a separate card rather than a section of the settings card because an
/// update is not a preference — nothing here writes to the snapshot, and the
/// row is the only place in the app that talks to the network on purpose. It
/// also keeps the settings card's five sections about what the *app* does and
/// this one about what *the app's copy* is.
///
/// When no [UpdateService] is mounted (a widget test, or a stripped build) the
/// card still renders: it states the version it was compiled with and offers
/// nothing else, which is honest and keeps the page's shape stable.
///
/// [state] arrives from [SettingsViewModel], which subscribes to the service's
/// own notifier — so the phase-switch below is a plain read and this widget
/// holds no subscription of its own.
class _UpdateSection extends StatelessWidget {
  const _UpdateSection({required this.service, required this.state});

  final UpdateService? service;
  final UpdateState? state;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);

    final current = state?.current;
    final versionText = current == null
        ? context.t('settings.version')
        : context.t('settings.updateHint', {
            'version': current.name.toString(),
            'build': '${current.build}',
          });

    final phase = state?.phase;
    final busy = state?.isBusy ?? false;
    final available = state?.available;

    // The second line reports, it does not invite. "Up to date" after a check
    // is worth saying once; a permanent "check for updates" hint would be a nag
    // on a page the user opened to change the theme.
    //
    // The idle case is not the version again: the header above already names the
    // build, and repeating it here would waste the one line that can carry a
    // fact the header cannot — when the check runs by itself.
    final hint = switch (phase) {
      UpdatePhase.available => context.t('settings.updateAvailable', {
          'version': available!.manifest.version.name.toString(),
        }),
      UpdatePhase.downloading => context.t('settings.updateDownloading', {
          'percent': '${(state!.progress * 100).clamp(0, 100).round()}',
        }),
      UpdatePhase.verifying => context.t('settings.updateVerifying'),
      UpdatePhase.ready => context.t('settings.updateReady'),
      UpdatePhase.upToDate => context.t('settings.updateUpToDate'),
      // The reason comes from the service, so it must be the service's reason.
      // A fixed string here would report "no connection" for a bad digest and
      // send the user to check their Wi-Fi for nothing.
      UpdatePhase.failed => updateReasonText(context, state?.reason),
      _ => context.t('settings.updateAutoHint'),
    };

    // `ready` still says Install, but the button opens the sheet rather than
    // installing: the sheet is where the size, the notes and the permission
    // warning live, and an install that starts from a list row with no
    // confirmation is how someone installs a build they did not mean to. The
    // label matches what the user gets, not what the click does.
    final buttonLabel = switch (phase) {
      UpdatePhase.available || UpdatePhase.ready => context.t('settings.updateInstall'),
      UpdatePhase.downloading || UpdatePhase.verifying =>
        context.t('settings.updateDownloading', {
          'percent': '${(state!.progress * 100).clamp(0, 100).round()}',
        }),
      _ => context.t('settings.update'),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x5, Sp.x4, Sp.x5, Sp.x3),
          child: Row(
            children: [
              LexIcon(Ic.refresh, size: 14, color: p.ink3),
              const SizedBox(width: Sp.x2),
              Expanded(
                child: Text(
                  context.t('settings.update'),
                  style: TextStyle(
                    fontSize: Fs.sm,
                    height: Lh.tight,
                    fontWeight: FontWeight.w500,
                    color: p.ink2,
                  ),
                ),
              ),
              Text(
                versionText,
                style: TextStyle(
                  fontFamily: Fonts.mono,
                  fontSize: Fs.xs,
                  height: Lh.tight,
                  color: p.ink3,
                ),
              ),
            ],
          ),
        ),
        Container(height: 1, color: p.line),
        _Row(
          // The header already names the build, so this line is where the
          // *state* goes: the newest release, the download, the answer.
          label: hint,
          control: service == null
              ? const SizedBox.shrink()
              : LexButton(
                  label: buttonLabel,
                  kind: available != null || phase == UpdatePhase.ready
                      ? BtnKind.primary
                      : BtnKind.normal,
                  size: BtnSize.sm,
                  icon: available != null || phase == UpdatePhase.ready
                      ? Ic.download
                      : Ic.refresh,
                  // Disabled while a check or download runs: the service guards
                  // against re-entry, and a button that looks live but does
                  // nothing is the worse lie.
                  onPressed: busy ? null : () => showUpdateSheet(context),
                ),
        ),
        if (busy) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x5, 0, Sp.x5, Sp.x4),
            child: ProgressBar(value: state?.progress ?? 0, thick: true),
          ),
        ],
      ],
    );
  }
}

/* ------------------------------------------------------------------ */
/* About                                                               */
/* ------------------------------------------------------------------ */

class _AboutCard extends StatelessWidget {
  const _AboutCard({required this.version});

  /// The running build's display name, or `—` when no service is mounted.
  ///
  /// Passed in rather than read from the scope here so the card and the update
  /// row cannot disagree about which build is running.
  final String version;

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
                    // The running build, read from the platform rather than
                    // typed here. `pubspec.yaml` is the one place a version is
                    // written; a literal in this file was a second one that
                    // would silently disagree with the manifest the updater
                    // compares against.
                    _Chip(text: '${context.t('settings.version')} $version'),
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
