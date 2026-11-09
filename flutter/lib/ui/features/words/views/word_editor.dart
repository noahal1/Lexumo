/// Add / edit one word — the page behind "Add word" and a row click.
///
/// Ports the web build's `WordEditor.tsx`. The behaviour is deliberately the
/// same: the draft owns every keystroke, nothing is written to the store until
/// Save, closing a dirty draft asks first (inline in the footer, so a second
/// dialog never stacks on this one), and duplicate detection runs on every
/// keystroke so the notice is there before the user commits.
///
/// This file is the layout plus the two editing surfaces the view model cannot
/// own:
///
///   * **the text buffers.** [WordEditorViewModel] keeps the draft as plain
///     strings; [_EditorBuffers] holds the seven `TextEditingController`s and
///     the focus node, because a controller owns a cursor, a selection and an
///     IME composition — editing surface, not screen state. [_EditorBuffers]
///     pushes keystrokes into the view model and mirrors lookup results back
///     out, so the two stay in step without either owning the other.
///   * **the route.** [_WordEditorPage] owns the bar, the scrolling form and
///     the pinned footer, and disposes both of the above when it unmounts.
///
/// The lookup and save logic — including the two guards that drop a late answer
/// — lives in the view model. Read that file for why they exist.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../../app/scope.dart';
import '../../../../domain/models/languages.dart';
import '../../../../domain/models/srs.dart' show STATUS_ORDER;
import '../../../../domain/models/types.dart';
import '../../../core/context_feedback.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/controls.dart';
import '../../../core/widgets/keyboard_hints.dart';
import '../../../core/widgets/lex_icon.dart';
import '../../../core/widgets/widgets.dart' show Kbd;
import '../view_models/word_editor_view_model.dart';

/// Opens the editor and resolves when it closes.
///
/// [word] null means create mode. The future carries the word the user asked to
/// delete (via the footer's Delete button), or null — the page owns the
/// confirmation, exactly as the TS parent did, so this page never stacks a
/// second one on top of itself.
///
/// It is a **pushed page**, not a dialog. The editor asks for seven text
/// fields, two lookups and five actions; at a phone's width that is more than a
/// centered card can hold without either a cramped scroll area or a footer
/// whose buttons run off the edge. A page owns the whole viewport, which is
/// what the form actually needs.
Future<Word?> showWordEditor(
  BuildContext context, {
  required Word? word,
  required String defaultListId,
}) async {
  final vm = WordEditorViewModel(
    store: context.store,
    feedback: ContextFeedback(context),
    word: word,
    defaultListId: defaultListId,
  );
  final buffers = _EditorBuffers(vm);
  // The strings are read here, off the caller's context, rather than inside the
  // route builder: by the time the page is disposed the caller's element may
  // be gone, and a deactivated context throws on an inherited lookup.
  return Navigator.of(context).push<Word>(
    MaterialPageRoute<Word>(
      builder: (_) => _WordEditorPage(
        vm: vm,
        buffers: buffers,
        title: context.t(word == null ? 'words.addWord' : 'words.editWord'),
        subtitle: word?.term ?? context.t('words.subtitle'),
      ),
    ),
  );
}

/* ------------------------------------------------------------------ */
/* Editing buffers                                                     */
/* ------------------------------------------------------------------ */

/// The dialog's editing surfaces, and the two-way bridge to the view model.
///
/// A `TextEditingController` is not screen state: it carries a cursor, a
/// selection and an in-flight IME composition, and rebuilding it from a string
/// on every notification would fight the keyboard. So the controllers live here,
/// the draft's *values* live in [WordEditorViewModel], and this class keeps the
/// two consistent:
///
///   * **outward** — every controller gets a listener that pushes its text into
///     the view model. The view model's setters are no-ops when the value has
///     not changed, so this cannot loop.
///   * **inward** — [syncFrom] writes the view model's text back into any
///     controller that disagrees, which is how a lookup's payload reaches the
///     fields. It listens to the view model rather than being called from a
///     builder: a controller write notifies the field's own `ValueNotifier`,
///     which would mark widgets dirty mid-build.
class _EditorBuffers {
  _EditorBuffers(this._vm) {
    _push(term, _vm.setTerm);
    _push(pos, _vm.setPos);
    _push(definition, _vm.setDefinition);
    _push(definition2, _vm.setDefinition2);
    _push(example, _vm.setExample);
    _push(exampleZh, _vm.setExampleZh);
    _push(note, _vm.setNote);
    // Inward: a lookup lands asynchronously, so the view model's notification
    // arrives between frames — the one moment it is safe to write a controller.
    // Doing this from the builder instead would fire `notifyListeners` on the
    // field's own `ValueNotifier` mid-build ("setState() called during build").
    // Registered after the pushes so the first sync already sees the seed text.
    _vm.addListener(syncFrom);
  }

  final WordEditorViewModel _vm;

  final TextEditingController term = TextEditingController();
  final TextEditingController pos = TextEditingController();
  final TextEditingController definition = TextEditingController();
  final TextEditingController definition2 = TextEditingController();
  final TextEditingController example = TextEditingController();
  final TextEditingController exampleZh = TextEditingController();
  final TextEditingController note = TextEditingController();

  /// Where Enter lands after the term field — the meaning, never Save.
  final FocusNode definitionFocus = FocusNode();

  List<TextEditingController> get _all => <TextEditingController>[
        term,
        pos,
        definition,
        definition2,
        example,
        exampleZh,
        note,
      ];

  void _push(TextEditingController c, void Function(String) sink) {
    // The initial value comes from the view model, then every keystroke goes
    // back into it.
    c.text = _textFor(c);
    c.addListener(() => sink(c.text));
  }

  String _textFor(TextEditingController c) {
    if (identical(c, term)) return _vm.term;
    if (identical(c, pos)) return _vm.pos;
    if (identical(c, definition)) return _vm.definition;
    if (identical(c, definition2)) return _vm.definition2;
    if (identical(c, example)) return _vm.example;
    if (identical(c, exampleZh)) return _vm.exampleZh;
    return _vm.note;
  }

  /// Mirror the view model's draft into the buffers that disagree with it.
  ///
  /// Runs on every view-model notification, never during a build. Only writes on
  /// a real difference: assigning `text` resets the selection, so doing it
  /// unconditionally would drag the caret to the end of the field on every
  /// repaint.
  void syncFrom() {
    void sync(TextEditingController c, String value) {
      if (c.text != value) c.text = value;
    }

    sync(term, _vm.term);
    sync(pos, _vm.pos);
    sync(definition, _vm.definition);
    sync(definition2, _vm.definition2);
    sync(example, _vm.example);
    sync(exampleZh, _vm.exampleZh);
    sync(note, _vm.note);
  }

  void dispose() {
    _vm.removeListener(syncFrom);
    for (final c in _all) {
      c.dispose();
    }
    definitionFocus.dispose();
  }
}

/* ------------------------------------------------------------------ */
/* Save / close                                                        */
/* ------------------------------------------------------------------ */

/// The translator, bound once per build so helpers take it as a parameter.
typedef _Translate = String Function(String key, [Map<String, Object>? vars]);

/// Esc, a backdrop tap and × all land here: a dirty draft asks first, inline in
/// the footer. [Navigator.pop] (not `maybePop`) is used for the confirmed exits
/// so the [PopScope] guard below cannot swallow them.
void _requestClose(BuildContext context, WordEditorViewModel vm) {
  if (vm.dismissOpen) {
    vm.setDismissOpen(false);
    return;
  }
  if (vm.dirty) {
    vm.setDismissOpen(true);
    return;
  }
  Navigator.of(context).pop();
}

/// Write the draft and close, or leave the dialog open on an empty term.
void _save(BuildContext context, WordEditorViewModel vm) {
  if (!vm.save()) return;
  Navigator.of(context).pop();
}

/* ------------------------------------------------------------------ */
/* The page                                                            */
/* ------------------------------------------------------------------ */

/// The editor's own route: a bar, a scrolling form, and a footer that never
/// runs off the edge.
///
/// The three parts are laid out here rather than inside `showLexModal` because
/// the dialog version put the footer in a single `Row` pinned to the card's
/// width. On a phone that row (favorite + delete + cancel + save, or the
/// discard line's three buttons) is wider than the card, so it overflowed —
/// and the discard line, which is the one the user meets when they try to back
/// out, was the worst of them. A page follows the platform instead: the form
/// scrolls, the actions stay pinned, and each action row wraps when it has to.
class _WordEditorPage extends StatefulWidget {
  const _WordEditorPage({
    required this.vm,
    required this.buffers,
    required this.title,
    required this.subtitle,
  });

  final WordEditorViewModel vm;
  final _EditorBuffers buffers;
  final String title;
  final String subtitle;

  @override
  State<_WordEditorPage> createState() => _WordEditorPageState();
}

class _WordEditorPageState extends State<_WordEditorPage> {
  @override
  void dispose() {
    // Disposal belongs to the route's own unmount, not to the future the
    // caller awaits: that future resolves when the route pops, while the
    // closing frame still builds the form and reads these controllers.
    widget.buffers.dispose();
    widget.vm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return Scaffold(
      backgroundColor: p.bg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _EditorBar(title: widget.title, subtitle: widget.subtitle),
            Expanded(
              child: _EditorBody(vm: widget.vm, buffers: widget.buffers),
            ),
            _EditorFooter(vm: widget.vm, buffers: widget.buffers),
          ],
        ),
      ),
    );
  }
}

/// The page's own top bar: a way back, the action's name, and the word when
/// there is one.
class _EditorBar extends StatelessWidget {
  const _EditorBar({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return Container(
      decoration: BoxDecoration(
        color: p.surface,
        border: Border(bottom: BorderSide(color: p.line)),
      ),
      padding: const EdgeInsetsDirectional.only(
        start: Sp.x2,
        end: Sp.x6,
        top: Sp.x2,
        bottom: Sp.x2,
      ),
      child: Row(
        children: <Widget>[
          // The bar's own back control, with a 44dp target on every platform:
          // this is the primary way out of a page that fills the screen.
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              key: const ValueKey<String>('editor-back'),
              onTap: () => Navigator.of(context).maybePop(),
              behavior: HitTestBehavior.opaque,
              child: SizedBox(
                width: Layout.tap,
                height: Layout.tap,
                child: Center(
                  child: LexIcon(Ic.chevronLeft, size: 20, color: p.ink2),
                ),
              ),
            ),
          ),
          const SizedBox(width: Sp.x1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: Fonts.display,
                    fontSize: Fs.md,
                    height: Lh.tight,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.005,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: Fs.xs,
                    height: Lh.snug,
                    color: p.ink3,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ------------------------------------------------------------------ */
/* Body                                                                */
/* ------------------------------------------------------------------ */

class _EditorBody extends StatelessWidget {
  const _EditorBody({required this.vm, required this.buffers});

  final WordEditorViewModel vm;
  final _EditorBuffers buffers;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: vm,
      builder: (BuildContext context, Widget? _) {
        final t = context.t;
        final AppData data = context.data;
        final String uiLang = context.i18n.lang.wire;
        final String pairLabel =
            '${langName(vm.fromLang, uiLang)} → ${langName(vm.toLang, uiLang)}';
        final bool showDuplicate = vm.showDuplicate;

        return CallbackShortcuts(
          // Cmd/Ctrl+Enter saves from anywhere in the page; Esc is the
          // keyboard's way back. The dialog got Esc for free from
          // `showLexModal`'s own binding, so the page has to carry it.
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
                _save(context, vm),
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
                _save(context, vm),
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                _requestClose(context, vm),
          },
          child: Focus(
            autofocus: true,
            child: PopScope(
              // The bar's back arrow, a system back gesture and Esc are all
              // `maybePop`; refusing the pop while dirty routes them into the
              // footer's discard line instead of losing the draft.
              canPop: !vm.dirty,
              onPopInvokedWithResult: (bool didPop, Object? _) {
                if (!didPop) _requestClose(context, vm);
              },
              child: SingleChildScrollView(
                key: const ValueKey<String>('word-editor-body'),
                // The form scrolls, the bar and the footer do not. On a phone
                // this is the difference between a keyboard that hides the
                // footer's buttons and one that never can.
                padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x5, Sp.x4, Sp.x6),
                child: Align(
                  alignment: Alignment.topCenter,
                  child: ConstrainedBox(
                    // One reading width on every screen. Left unconstrained, a
                    // 1920-wide window draws a two-field row a metre across;
                    // this is the same column the dialog used to be.
                    constraints: const BoxConstraints(maxWidth: 640),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        _termField(context, t),
                        const SizedBox(height: Sp.x4),
                        _definitionsRow(context, t, pairLabel),
                        if (showDuplicate) ...<Widget>[
                          const SizedBox(height: Sp.x4),
                          _duplicateNotice(context, t),
                        ],
                        const SizedBox(height: Sp.x4),
                        _exampleField(context, t),
                        const SizedBox(height: Sp.x4),
                        _notesField(context, t),
                        const SizedBox(height: Sp.x4),
                        _classifiers(context, t, data),
                        if (context.showsKeyHints) ...<Widget>[
                          const SizedBox(height: Sp.x4),
                          _keyboardLegend(context, t),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /* ---- term ---- */
  Widget _termField(BuildContext context, _Translate t) {
    final p = Palette.of(context);
    final bool canReverse =
        vm.definition.trim().isNotEmpty &&
        vm.reversePhase != LookupPhase.loading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: _label(p, t('words.term'))),
            // The other half of the pair. It sits on the term field because
            // that is the field it fills, and it stays disabled until there is
            // a meaning to search with — searching an empty string is a request
            // the dictionary answers with an error.
            Tooltip(
              message: t('words.reverseHint'),
              waitDuration: const Duration(milliseconds: 500),
              child: LexButton(
                label: vm.reversePhase == LookupPhase.loading
                    ? t('words.translating')
                    : t('words.reverseTranslate'),
                icon: vm.reversePhase == LookupPhase.loading
                    ? Ic.refresh
                    : Ic.undo,
                kind: BtnKind.quiet,
                size: BtnSize.sm,
                onPressed: canReverse
                    ? vm.reverseLookup
                    : null,
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        LexInput(
          controller: buffers.term,
          placeholder: t('words.termPlaceholder'),
          autofocus: true,
          onChanged: (String _) => vm.setError(''),
          onSubmitted: (String _) {
            // Enter moves on to the meaning instead of saving; Ctrl/⌘+Enter
            // still saves from anywhere.
            if (vm.term.trim().isEmpty) {
              _save(context, vm);
              return;
            }
            buffers.definitionFocus.requestFocus();
          },
        ),
        if (vm.phonetic.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            '/${vm.phonetic}/ ${t('words.phonetic')}',
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.xs,
              height: Lh.snug,
              color: p.ink3,
            ),
          ),
        ],
        if (vm.error.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            vm.error,
            style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.danger),
          ),
        ],
        // A failed reverse lookup reports under the field it would have filled,
        // not in a toast: the message is the answer to the button just pressed.
        if (vm.reversePhase == LookupPhase.failed) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            vm.reverseFailureText ?? '',
            style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.danger),
          ),
        ],
      ],
    );
  }

  /* ---- definition + secondary meaning ---- */
  Widget _definitionsRow(
    BuildContext context,
    _Translate t,
    String pairLabel,
  ) {
    // The two fields sit side by side only when both can hold their own header:
    // the label, the language pair and the 翻译 button need ~215dp, so a column
    // below ~250dp squeezes the label to zero width and it wraps mid-word
    // ("释义" printed as two stacked characters). The web build collapses
    // `.field-row` to one column below 820px for the same reason; the dialog
    // here is capped at 560, so the equivalent check is on the space actually
    // offered to the pair rather than on the window.
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Widget primary = _definitionField(context, t, pairLabel);
        final Widget secondary = _secondaryDefinitionField(context, t);
        if (constraints.maxWidth < 520) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              primary,
              const SizedBox(height: Sp.x4),
              secondary,
            ],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(child: primary),
            const SizedBox(width: Sp.x3),
            Expanded(child: secondary),
          ],
        );
      },
    );
  }

  Widget _definitionField(
    BuildContext context,
    _Translate t,
    String pairLabel,
  ) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            // The label is not expanded: it is the name of the field, so it
            // keeps its intrinsic width and the optional language hint gives
            // way instead. Expanded here is what let "释义" be squeezed to a
            // 0dp box on a phone — the hint and the button had already taken
            // everything, and a zero-width Text still wraps, so the label
            // appeared as two stacked characters rather than disappearing.
            _label(p, t('common.definition')),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                pairLabel,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink3),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Tooltip(
              message: t('words.translateHint'),
              waitDuration: const Duration(milliseconds: 500),
              child: LexButton(
                label: vm.forwardPhase == LookupPhase.loading
                    ? t('words.translating')
                    : vm.forwardPhase == LookupPhase.failed
                        ? t('words.retranslate')
                        : t('words.translate'),
                icon: vm.forwardPhase == LookupPhase.loading
                    ? Ic.refresh
                    : Ic.sparkles,
                kind: BtnKind.quiet,
                size: BtnSize.sm,
                // Nothing to look up until there is a term — and a click
                // mid-flight would only race the one already running.
                onPressed: vm.term.trim().isEmpty ||
                        vm.forwardPhase == LookupPhase.loading
                    ? null
                    : vm.forwardLookup,
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            // The tag is a label for the gloss, not part of it: the way
            // a card and the list both read it.
            SizedBox(
              width: 72,
              child: LexInput(
                controller: buffers.pos,
                placeholder: t('words.posPlaceholder'),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: LexInput(
                controller: buffers.definition,
                placeholder: t('words.definitionPlaceholder'),
                focusNode: buffers.definitionFocus,
              ),
            ),
          ],
        ),
        if (vm.forwardPhase == LookupPhase.failed) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            vm.forwardFailureText ?? '',
            style: TextStyle(
              fontSize: Fs.xs,
              height: Lh.snug,
              color: p.danger,
            ),
          ),
        ],
      ],
    );
  }

  Widget _secondaryDefinitionField(BuildContext context, _Translate t) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            _label(p, t('common.definition2')),
            const SizedBox(width: Sp.x2),
            Text(
              t('common.optional'),
              style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink3),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        LexInput(
          controller: buffers.definition2,
          placeholder: t('words.definition2Placeholder'),
        ),
      ],
    );
  }

  /* ---- duplicate notice ---- */
  Widget _duplicateNotice(BuildContext context, _Translate t) {
    final p = Palette.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(color: p.accentSoft, borderRadius: R.borderSm),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: LexIcon(Ic.alert, size: 15, color: p.accentInk),
          ),
          const SizedBox(width: Sp.x3),
          Expanded(
            child: Text(
              t('words.duplicate'),
              style: TextStyle(
                fontSize: Fs.sm,
                height: Lh.body,
                color: p.accentInk,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /* ---- example ---- */
  Widget _exampleField(BuildContext context, _Translate t) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _labelWithOptional(p, t('common.example'), t('common.optional')),
        const SizedBox(height: Sp.x2),
        LexTextArea(
          controller: buffers.example,
          placeholder: t('words.examplePlaceholder'),
        ),
        // Only offered once there is a sentence to translate; keyed off the
        // typed value so pasting a sentence reveals it immediately.
        if (vm.example.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x2),
          LexInput(
            controller: buffers.exampleZh,
            placeholder: t('words.exampleZhPlaceholder'),
          ),
        ],
      ],
    );
  }

  /* ---- notes ---- */
  Widget _notesField(BuildContext context, _Translate t) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _labelWithOptional(p, t('common.notes'), t('common.optional')),
        const SizedBox(height: Sp.x2),
        LexTextArea(
          controller: buffers.note,
          placeholder: t('words.notePlaceholder'),
        ),
      ],
    );
  }

  /* ---- list + status ---- */
  Widget _classifiers(
    BuildContext context,
    _Translate t,
    AppData data,
  ) {
    String listName(String id) =>
        data.lists.where((WordList l) => l.id == id).firstOrNull?.name ?? id;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: LexField(
            label: t('common.list'),
            child: LexSelect<String>(
              value: vm.listId,
              options: data.lists.map((WordList l) => l.id).toList(),
              onChanged: vm.setListId,
              labelOf: listName,
            ),
          ),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: LexField(
            label: t('common.status'),
            child: LexSelect<WordStatus>(
              value: vm.status,
              options: STATUS_ORDER,
              onChanged: vm.setStatus,
              labelOf: (WordStatus s) => t('status.${s.wire}'),
            ),
          ),
        ),
      ],
    );
  }

  /* ---- keyboard legend ---- */
  Widget _keyboardLegend(BuildContext context, _Translate t) {
    final p = Palette.of(context);
    final TextStyle style = TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink3);
    const Widget gap = SizedBox(width: Sp.x1);
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: Sp.x1,
      runSpacing: Sp.x1,
      children: <Widget>[
        const Kbd('Enter'),
        gap,
        Text(t('words.enterNext'), style: style),
        Text('，', style: style),
        const Kbd('Ctrl'),
        Text('+', style: style),
        const Kbd('Enter'),
        gap,
        Text(t('words.saveAnywhere'), style: style),
        Text('，', style: style),
        const Kbd('Esc'),
        gap,
        Text(t('common.cancel'), style: style),
      ],
    );
  }

  /* ---- small type helpers ---- */
  Widget _label(Palette p, String text) => Text(
        text,
        style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w500, color: p.ink2),
      );

  Widget _labelWithOptional(Palette p, String label, String optional) => Row(
        children: <Widget>[
          _label(p, label),
          const SizedBox(width: Sp.x2),
          Text(
            optional,
            style: TextStyle(
              fontSize: Fs.xs,
              height: Lh.snug,
              fontWeight: FontWeight.w400,
              color: p.ink3,
            ),
          ),
        ],
      );
}

/* ------------------------------------------------------------------ */
/* Footer                                                              */
/* ------------------------------------------------------------------ */

/// The page's pinned action bar.
///
/// It used to be one `Row` of four buttons inside a centered dialog. On a phone
/// that row is wider than the card, so it overflowed — and the discard line was
/// the worst case, because it carries a whole sentence *and* two buttons and
/// only appears at the moment the user is trying to get out. Everything here
/// wraps or stacks instead of overflowing:
///
///   * wide windows keep the one-line row, with the destructive actions pushed
///     to the left edge and the two that close the page on the right;
///   * narrow ones stack: the secondary actions on their own row, then cancel
///     and save sharing the width below them, which is where a thumb expects
///     them and what every phone form does;
///   * the discard question sits above its own two buttons on any width, so the
///     sentence never gets squeezed into the middle of a row of controls.
class _EditorFooter extends StatelessWidget {
  const _EditorFooter({required this.vm, required this.buffers});

  final WordEditorViewModel vm;
  final _EditorBuffers buffers;

  @override
  Widget build(BuildContext context) {
    final Palette p = Palette.of(context);
    return ListenableBuilder(
      listenable: vm,
      builder: (BuildContext context, Widget? _) {
        return Container(
          decoration: BoxDecoration(
            color: p.surface,
            border: Border(top: BorderSide(color: p.line)),
          ),
          padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x3, Sp.x4, Sp.x3),
          child: SafeArea(
            // A phone's gesture bar sits under exactly this strip.
            top: false,
            child: Align(
              alignment: Alignment.center,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: vm.dismissOpen
                    ? _discardConfirm(context)
                    : _actions(context),
              ),
            ),
          ),
        );
      },
    );
  }

  /// "Discard this draft?" — the question on its own line, the answer below it.
  Widget _discardConfirm(BuildContext context) {
    final Palette p = Palette.of(context);
    final t = context.t;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          t('words.discardConfirm'),
          style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink2),
        ),
        const SizedBox(height: Sp.x2),
        Row(
          children: <Widget>[
            // Keep editing is the safe half and gets the width; discarding is a
            // single deliberate tap that should not be the easiest target here.
            Expanded(
              flex: 2,
              child: LexButton(
                label: t('words.keepEditing'),
                block: true,
                onPressed: () => vm.setDismissOpen(false),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: LexButton(
                label: t('words.discardChanges'),
                kind: BtnKind.danger,
                block: true,
                onPressed: () {
                  vm.setDismissOpen(false);
                  Navigator.of(context).pop();
                },
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Favorite, delete, cancel, save — laid out for the width on offer.
  Widget _actions(BuildContext context) {
    final t = context.t;
    final Word? word = vm.word;

    final List<Widget> secondary = <Widget>[
      if (word != null) ...<Widget>[
        LexButton(
          label: t('common.favorite'),
          icon: vm.favorite ? Ic.starFilled : Ic.star,
          kind: vm.favorite ? BtnKind.normal : BtnKind.quiet,
          size: BtnSize.sm,
          onPressed: vm.toggleFavorite,
        ),
        const SizedBox(width: Sp.x2),
        LexButton(
          label: t('common.delete'),
          icon: Ic.trash,
          kind: BtnKind.danger,
          size: BtnSize.sm,
          // The page owns the confirmation, so this only reports intent.
          onPressed: () => Navigator.of(context).pop(word),
        ),
      ],
    ];

    final Widget cancel = LexButton(
      label: t('common.cancel'),
      onPressed: () => _requestClose(context, vm),
    );
    final Widget save = LexButton(
      label: t('common.save'),
      icon: Ic.check,
      kind: BtnKind.primary,
      onPressed: () => _save(context, vm),
    );

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        // 640 is the form column; below 440 the four controls cannot share one
        // row with their labels at any sane size, so they split into two.
        if (constraints.maxWidth < 440) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (secondary.isNotEmpty) ...<Widget>[
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  children: secondary,
                ),
                const SizedBox(height: Sp.x2),
              ],
              Row(
                children: <Widget>[
                  Expanded(
                    child: LexButton(
                      label: t('common.cancel'),
                      block: true,
                      onPressed: () => _requestClose(context, vm),
                    ),
                  ),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    flex: 2,
                    child: LexButton(
                      label: t('common.save'),
                      icon: Ic.check,
                      kind: BtnKind.primary,
                      block: true,
                      onPressed: () => _save(context, vm),
                    ),
                  ),
                ],
              ),
            ],
          );
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            ...secondary,
            if (secondary.isNotEmpty) const SizedBox(width: Sp.x4),
            cancel,
            const SizedBox(width: Sp.x2),
            save,
          ],
        );
      },
    );
  }
}
