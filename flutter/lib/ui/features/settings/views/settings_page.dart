/// The settings sheet.
///
/// Ports the web build's `SettingsPage.tsx` and its `parts.tsx` helpers. The
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
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart' hide Card;

import '../../../../app/scope.dart';
import '../../../../app/update_scope.dart';
import '../../../../data/repositories/onboarding_store.dart';
import '../../../../data/services/app_dir.dart';
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
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart';
import '../../onboarding/views/onboarding_page.dart';
import '../../update/views/update_sheet.dart';
import '../view_models/settings_view_model.dart';

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
          controller: widget.controller,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _Section(
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
                    const SizedBox(height: Sp.x5),
                    _Section(
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
                    const SizedBox(height: Sp.x5),
                    _Section(
                      title: context.t('settings.audio'),
                      // Only note the absence once the engine has actually said
                      // no; before warm-up `supported` answers true on purpose so
                      // the picker does not flash in and out.
                      //
                      // It is a warning, not a note: this is the one sentence
                      // in the group that changes what the user can do, so it
                      // gets its own line on the page instead of the tail of
                      // the heading.
                      warning: vm.speechSupported ? null : context.t('settings.noVoice'),
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
                    const SizedBox(height: Sp.x5),
                    _Section(
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
                    const SizedBox(height: Sp.x5),
                    _SyncSection(
                      vm: vm,
                      autoSync: settings.autoSync,
                      onAutoSync: (v) => vm.patch((s) => s.copyWith(autoSync: v)),
                    ),
                    const SizedBox(height: Sp.x5),
                    _Section(
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
            const SizedBox(height: Sp.x5),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 880),
              child: _AboutSection(
                version: vm.updateState?.current?.name.toString() ?? '—',
                service: vm.updateService,
                state: vm.updateState,
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

/// The left edge every settings column shares.
///
/// `SectionTitle` is normally a page eyebrow sitting flush with the page
/// gutter, while these rows inset their text by `Sp.x4` inside a hover box
/// that owns the full width. Measured on the running build, that put the
/// group name 8dp to the left of the labels underneath it — close enough to
/// read as a rendering slip rather than as an indent. Giving the heading the
/// same inset costs nothing and puts the name directly over the column it
/// names.
const EdgeInsets _kHeadingInset = EdgeInsets.symmetric(horizontal: Sp.x4);

/// The one heading style the page uses.
///
/// Three block titles used to be three styles: `SectionTitle` (13dp, `ink3`),
/// the update block's own display-face 16dp, and the about card's inline
/// 13dp label. All three name a block, so all three are the same thing.
Widget _heading(BuildContext context, String label, {Widget? trailing}) {
  return Padding(
    padding: _kHeadingInset,
    child: SectionTitle(
      label: label,
      trailing: trailing,
      padded: false,
      // `ink3` is the eyebrow level — fainter than the rows it introduces. A
      // page with no other heading cannot afford that: the group name is the
      // only thing naming the block and has to outrank its own annotation,
      // not lose to it.
      color: Palette.of(context).ink2,
    ),
  );
}

/// One named group of settings: a heading, then its rows directly on the page.
///
/// The page used to be a single 880dp card containing every group, with
/// full-bleed hairlines between them. That made eight unrelated decisions read
/// as one form, and the card's own border competed with the dividers inside it
/// — the eye had no clue where a group started, so it read the page as a wall.
/// A heading above its own rows is the same information with a visible edge:
/// each group is a thing you can find by scanning the left margin, which is how
/// the rest of the app is organised now.
///
/// The leading icon is gone. Eight 14dp glyphs in a column never aligned with
/// anything (rows are inset 12dp from the card edge, the icon sat at 20dp), and
/// a settings group is named by its words, not by a symbol.
class _Section extends StatelessWidget {
  const _Section({
    required this.title,
    this.note,
    this.warning,
    required this.children,
  });

  final String title;

  /// A short fact about the group, parked opposite its name. One line only:
  /// anything that needs explaining belongs in a row's hint or in [warning].
  final String? note;

  /// Something the user has to know before the rows below can be trusted —
  /// a missing engine, a failed warm-up. It gets a whole line of the page,
  /// not the tail of the heading.
  ///
  /// The audio group used to pass "this device has no usable voice" as
  /// [note]: 22 characters, ellipsised in one line, at `ink4` (the decorative
  /// grey). The single most consequential sentence in the group was the least
  /// legible thing on the page.
  final String? warning;

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // A settings group is a list of rows, not a box holding rows: the heading
    // names it, a hairline separates each row, and the page itself is the
    // container. The card that used to wrap them added a border around a
    // borderless thing and made every group read as a widget.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          context,
          title,
          trailing: note == null
              ? null
              : Text(
                  note!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: Fonts.mono,
                    fontSize: Fs.xs,
                    height: Lh.tight,
                    color: p.ink3,
                  ),
                ),
        ),
        if (warning != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(Sp.x4, 0, Sp.x4, Sp.x3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: LexIcon(Ic.info, size: 14, color: p.warn),
                ),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: Text(
                    warning!,
                    style: TextStyle(
                      fontSize: Fs.sm,
                      height: Lh.body,
                      color: p.ink2,
                    ),
                  ),
                ),
              ],
            ),
          ),
        HairlineList(
          rule: false,
          padded: false,
          children: [
            for (var i = 0; i < children.length; i++)
              _RowSlot(last: i == children.length - 1, child: children[i]),
          ],
        ),
      ],
    );
  }
}

/// A row plus the hairline that separates it from the next one.
///
/// The divider lives here rather than in `_Row` so a control that is not a
/// `_Row` (a preview, a notice) still gets the same separator between it and
/// its neighbours.
class _RowSlot extends StatelessWidget {
  const _RowSlot({required this.last, required this.child});

  final bool last;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return DecoratedBox(
      decoration: BoxDecoration(
        border: last ? null : Border(bottom: BorderSide(color: p.line)),
      ),
      child: child,
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
        constraints: const BoxConstraints(minHeight: Layout.tap),
        padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
        decoration: BoxDecoration(
          // `null` rather than a literal transparent: the row has no fill at
          // rest, and the only colour this decoration ever carries comes from
          // the palette.
          color: _hover ? p.surfaceHover : null,
          borderRadius: R.borderMd,
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

/// Account and sync. Ports `SyncSection.tsx`.
///
/// Two shapes: signed out shows a sign-in button (the form itself is the
/// first-run gate — see `_openSignIn`), signed in shows who you are, what the
/// last round did, and the two actions. The state comes from
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

  /// Opens the first-run gate as a pushed page, reusing the exact form the app
  /// starts with.
  ///
  /// The gate is a whole page, not a dialog: it owns a layout (the framed
  /// panel beside the form on a wide window), and shrinking it into
  /// [showLexModal]'s centered card would cut the half that makes it read as
  /// a deliberate screen rather than a popup.
  ///
  /// The store is rebuilt here rather than shared with `main`'s: the sidecar
  /// is a fact about this install, re-reading it costs one small file read,
  /// and sharing would mean threading the boot's store through scopes the
  /// rest of the app has no other use for. [OnboardingPage.onConfigured] pops
  /// instead of swapping for the shell — the shell is already underneath.
  Future<void> _openSignIn(BuildContext context) async {
    final engine = SyncScope.engineWithoutDeps(context);
    if (engine == null) return;
    final store = FileOnboardingStore(
      '${AppDir.dataDir}${Platform.pathSeparator}onboarding.json',
    );
    // Not awaited before the push: a pending file read inside the frame
    // would hold the tap for a real disk round trip, and a store that has
    // not read its sidecar yet behaves as "not set up", the honest default.
    unawaited(store.load());
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => OnboardingPage(
          engine: engine,
          onboarding: store,
          // The answer is recorded by the page itself; coming back to the
          // settings page is all the shell needs to do. The status row above
          // rebuilds through [SettingsViewModel]'s engine subscription.
          onConfigured: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }
  final ValueChanged<bool> onAutoSync;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final status = vm.syncStatus;
    final signedIn = status?.isSignedIn ?? false;
    final state = status?.state ?? SyncState.signedOut;
    final formError = vm.syncFormError;

    return _Section(
      title: context.t('settings.sync'),
      children: [
        if (!signedIn) ...[
          // No form here. The first-run gate already asks for the address, the
          // email and the password, and it does it before the shell exists —
          // a second copy of those fields on the settings page was two places
          // to type one password, and the only thing the copy could do that
          // the gate cannot is disagree with it about the server.
          //
          // What stays is the way back: a device set up as local can still
          // change its mind, which is what `onboarding.localBody` promises
          // ("之后随时可以在设置里登录").
          _Row(
            label: context.t('settings.syncStatus'),
            hint: vm.syncSignedInAs,
            control: _StatusPill(state: state),
          ),
          Padding(
            padding: const EdgeInsets.only(top: Sp.x4),
            child: Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                LexButton(
                  label: context.t('settings.syncSignIn'),
                  kind: BtnKind.primary,
                  size: BtnSize.sm,
                  onPressed: () => _openSignIn(context),
                ),
              ],
            ),
          ),
        ] else ...[
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

/// The update row: one sentence about the copy that is running and one button
/// that opens [showUpdateSheet].
///
/// It used to be a card of its own below the about block. The argument for
/// splitting them was that an update is not a preference — nothing here writes
/// to the snapshot. But both blocks answered the same question ("which copy is
/// this?"), so the version arrived twice: once as a chip in the about block and
/// once as this row's heading. Merged, the number is stated once and the action
/// sits directly under it, which is also the only place it means anything.
///
/// [state] arrives from [SettingsViewModel], which subscribes to the service's
/// own notifier — so the phase-switch below is a plain read and this widget
/// holds no subscription of its own.
class _UpdateRow extends StatelessWidget {
  const _UpdateRow({required this.service, required this.state});

  final UpdateService? service;
  final UpdateState? state;

  @override
  Widget build(BuildContext context) {
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
        _Row(
          // This line is where the *state* goes: the newest release, the
          // download, the answer. The build itself is named once, above, by
          // the about block's version chip — repeating it here was what made
          // the version appear twice on the same page.
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
            padding: const EdgeInsets.fromLTRB(Sp.x4, 0, Sp.x4, Sp.x4),
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

class _AboutSection extends StatelessWidget {
  const _AboutSection({
    required this.version,
    required this.service,
    required this.state,
  });

  /// The running build's display name, or `—` when no service is mounted.
  ///
  /// Passed in rather than read from the scope here so the card and the update
  /// row cannot disagree about which build is running.
  final String version;

  /// The updater, or null when no service is mounted (a widget test, or a
  /// stripped build). The row then states the build and offers nothing else.
  final UpdateService? service;

  /// The updater's state, republished by [SettingsViewModel].
  final UpdateState? state;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    // Same shape as every other settings section: a heading over content that
    // sits directly on the page. The box this used to draw put the app's own
    // name inside a frame, one frame away from the frame around the page.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(context, context.t('settings.about')),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x2, Sp.x4, Sp.x4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                // Written out rather than as `\u8bcd\u781a`: this was the only
                // string in the codebase spelled in escapes, so the one place
                // the product's Chinese name appears was the only place nobody
                // could read it in a diff.
                '${context.t('common.appName')} · 词砚',
                // The product name was 13dp `ink3` — fainter than the "关于"
                // heading above it, which named the block rather than the
                // thing. Whatever names the app on its own about card has to
                // be the loudest line in that card.
                style: TextStyle(
                  fontFamily: Fonts.display,
                  fontSize: Fs.md,
                  height: Lh.tight,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.005,
                  color: p.ink,
                ),
              ),
              const SizedBox(height: Sp.x3),
              // The running build and the action that changes it, together.
              //
              // They used to be two blocks, which printed the version twice —
              // once as this chip and once as the update row's own heading. The
              // chip is the page's one statement of which copy is running; the
              // row below says what state that copy is in and offers the way
              // out. Merged, the button reads as a consequence of the version
              // rather than as a separate feature that happens to live nearby.
              //
              // Aligned start, not stretched: the chip is a label for the
              // number of chars it holds, and a chip stretched across the card
              // stops reading as one.
              //
              // The key is the widget tests' handle on this block, and matching
              // on a button's label would tie them to copy that is expected to
              // change.
              KeyedSubtree(
                key: const ValueKey('update-card'),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: _Chip(
                        text: '${context.t('settings.version')} $version',
                      ),
                    ),
                    const SizedBox(height: Sp.x2),
                    // The stack used to share the version's line, so the card
                    // read as one wrapped pile of metadata. It is not the same
                    // kind of fact: the build identifies *this* copy, the stack
                    // says what it was written in. It goes on its own line, at
                    // caption weight.
                    Text(
                      'Flutter · Dart',
                      style: TextStyle(
                        fontFamily: Fonts.mono,
                        fontSize: Fs.xs,
                        height: Lh.tight,
                        color: p.ink4,
                      ),
                    ),
                    const SizedBox(height: Sp.x4),
                    _UpdateRow(service: service, state: state),
                  ],
                ),
              ),
              const SizedBox(height: Sp.x4),
              Text(
                context.t('settings.madeWith'),
                style: TextStyle(fontSize: Fs.sm, height: Lh.loose, color: p.ink2),
              ),
              // The keyboard legend that used to sit here is gone. It was a
              // reference table of keycaps at the bottom of a settings page —
              // the one place the shortcuts it described were least likely to
              // be reached for. They are discoverable where they apply: the
              // cheat sheet on `?`, and the keycap hints beside the actions
              // that have them.
            ],
          ),
        ),
      ],
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
