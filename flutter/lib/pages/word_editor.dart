/// Add / edit one word — the dialog behind "Add word" and a row click.
///
/// Ports `src/pages/words/WordEditor.tsx`. The behaviour is deliberately the
/// same: the draft owns every keystroke, nothing is written to the store until
/// Save, closing a dirty draft asks first (inline in the footer, so a second
/// dialog never stacks on this one), and duplicate detection runs on every
/// keystroke so the notice is there before the user commits.
///
/// The web build carried two halves of a dictionary lookup here (term → meaning
/// and meaning → term) plus a text-to-speech preview. Both were browser-only:
/// `src/lib/translate.ts` is an HTTP client over Youdao / Google / MyMemory and
/// `src/lib/tts.ts` is Web Speech. The Flutter port has neither a networking
/// layer nor a speech layer, so the two lookup buttons keep their place, their
/// label and their hint but stay disabled: a control that cannot do its job
/// should look unavailable rather than silently do nothing. Nothing else in
/// this dialog depends on them.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/scope.dart';
import '../data/store.dart';
import '../design/tokens.dart';
import '../domain/languages.dart';
import '../domain/srs.dart' show STATUS_ORDER;
import '../domain/types.dart';
import '../ui/controls.dart';
import '../ui/keyboard_hints.dart';
import '../ui/lex_icon.dart';
import '../ui/widgets.dart' show Kbd;

/// Opens the editor and resolves when it closes.
///
/// [word] null means create mode. The future carries the word the user asked to
/// delete (via the footer's Delete button), or null — the page owns the
/// confirmation, exactly as the TS parent did, so this dialog never stacks a
/// second one on top of itself.
Future<Word?> showWordEditor(
  BuildContext context, {
  required Word? word,
  required String defaultListId,
}) async {
  final model = _EditorModel(word: word, defaultListId: defaultListId);
  return showLexModal<Word>(
    context: context,
    width: 620,
    title: context.t(word == null ? 'words.addWord' : 'words.editWord'),
    subtitle: word?.term ?? context.t('words.subtitle'),
    body: _EditorBody(model: model),
    footer: _EditorFooter(model: model),
    // Disposal belongs to the modal's own unmount, not to this future: the
    // future resolves when the route pops, while the closing frame still builds
    // the body and reads these controllers.
    onDispose: model.dispose,
  );
}

/* ------------------------------------------------------------------ */
/* Draft state                                                         */
/* ------------------------------------------------------------------ */

/// Every field of the draft, its dirty comparison and its error line.
///
/// A plain [ChangeNotifier] rather than a widget: the modal's body and footer
/// are two separate widget trees (the shared modal renders them in different
/// places), so one object has to outlive both and tell each to rebuild.
class _EditorModel extends ChangeNotifier {
  _EditorModel({required this.word, required this.defaultListId})
      : listId = word?.listId ?? defaultListId,
        status = word?.status ?? WordStatus.new_,
        favorite = word?.favorite ?? false,
        _phonetic = word?.phonetic ?? '' {
    term.text = word?.term ?? '';
    pos.text = word?.pos ?? '';
    definition.text = word?.definition ?? '';
    definition2.text = word?.definition2 ?? '';
    example.text = word?.example ?? '';
    exampleZh.text = word?.exampleZh ?? '';
    note.text = word?.note ?? '';
    // Any keystroke can change `dirty` and the duplicate notice, so the draft
    // forwards the controllers' own notifications instead of every field
    // wiring its own `onChanged`.
    for (final controller in _controllers) {
      controller.addListener(notifyListeners);
    }
  }

  /// The word being edited; null in create mode.
  final Word? word;

  /// The list the create form starts on (the page's active list).
  final String defaultListId;

  final TextEditingController term = TextEditingController();
  final TextEditingController pos = TextEditingController();
  final TextEditingController definition = TextEditingController();
  final TextEditingController definition2 = TextEditingController();
  final TextEditingController example = TextEditingController();
  final TextEditingController exampleZh = TextEditingController();
  final TextEditingController note = TextEditingController();

  /// Where Enter lands after the term field — the meaning, never Save.
  final FocusNode definitionFocus = FocusNode();

  String listId;
  WordStatus status;
  bool favorite;
  String error = '';
  bool dismissOpen = false;

  /// Read-only in this port: only the (unavailable) lookup ever set it, so it
  /// survives as the value loaded from the word and is written back on save.
  final String _phonetic;

  String get phonetic => _phonetic;

  List<TextEditingController> get _controllers => <TextEditingController>[
        term,
        pos,
        definition,
        definition2,
        example,
        exampleZh,
        note,
      ];

  /// A draft is dirty when any field differs from what was loaded. The create
  /// baseline is all-empty, so a word typed half-way counts too — closing after
  /// that must not throw the text away without asking.
  bool get dirty =>
      term.text != (word?.term ?? '') ||
      phonetic != (word?.phonetic ?? '') ||
      pos.text != (word?.pos ?? '') ||
      definition.text != (word?.definition ?? '') ||
      definition2.text != (word?.definition2 ?? '') ||
      example.text != (word?.example ?? '') ||
      exampleZh.text != (word?.exampleZh ?? '') ||
      note.text != (word?.note ?? '') ||
      listId != (word?.listId ?? defaultListId) ||
      status != (word?.status ?? WordStatus.new_) ||
      favorite != (word?.favorite ?? false);

  void setError(String value) {
    if (error == value) return;
    error = value;
    notifyListeners();
  }

  void setDismissOpen(bool value) {
    if (dismissOpen == value) return;
    dismissOpen = value;
    notifyListeners();
  }

  void setListId(String value) {
    if (listId == value) return;
    listId = value;
    notifyListeners();
  }

  void setStatus(WordStatus value) {
    if (status == value) return;
    status = value;
    notifyListeners();
  }

  void toggleFavorite() {
    favorite = !favorite;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.removeListener(notifyListeners);
      controller.dispose();
    }
    definitionFocus.dispose();
    super.dispose();
  }
}

/* ------------------------------------------------------------------ */
/* Save / close                                                        */
/* ------------------------------------------------------------------ */

/// Esc, a backdrop tap and × all land here: a dirty draft asks first, inline in
/// the footer. [Navigator.pop] (not `maybePop`) is used for the confirmed exits
/// so the [PopScope] guard below cannot swallow them.
void _requestClose(BuildContext context, _EditorModel model) {
  if (model.dismissOpen) {
    model.setDismissOpen(false);
    return;
  }
  if (model.dirty) {
    model.setDismissOpen(true);
    return;
  }
  Navigator.of(context).pop();
}

/// The translator, bound once per build so helpers take it as a parameter.
typedef _Translate = String Function(String key, [Map<String, Object>? vars]);

void _save(BuildContext context, _EditorModel model) {
  String t(String key, [Map<String, Object>? vars]) => context.t(key, vars);
  final trimmed = model.term.text.trim();
  if (trimmed.isEmpty) {
    model.setError(t('words.termRequired'));
    return;
  }

  final store = context.store;
  final String phonetic = model.phonetic.trim();
  final String pos = model.pos.text.trim();
  final String exampleZh = model.exampleZh.text.trim();
  final Word? word = model.word;

  if (word != null) {
    store.updateWord(
      word.id,
      // Explicit reconstruction rather than `copyWith`: an emptied phonetic,
      // pos or translated example has to become null, and `copyWith` treats null
      // as "keep the old value".
      (current) => Word(
        id: current.id,
        term: trimmed,
        phonetic: phonetic.isEmpty ? null : phonetic,
        pos: pos.isEmpty ? null : pos,
        definition: model.definition.text.trim(),
        definition2: model.definition2.text.trim(),
        example: model.example.text.trim(),
        exampleZh: exampleZh.isEmpty ? null : exampleZh,
        note: model.note.text.trim(),
        status: model.status,
        favorite: model.favorite,
        listId: model.listId,
        sourceLang: current.sourceLang,
        targetLang: current.targetLang,
        listenCount: current.listenCount,
        srs: current.srs,
        createdAt: current.createdAt,
        updatedAt: current.updatedAt,
      ),
    );
    context.toast(t('words.wordUpdated'), ToastKind.ok);
  } else {
    store.addWord(
      NewWordInput(
        term: trimmed,
        phonetic: phonetic,
        pos: pos.isEmpty ? null : pos,
        definition: model.definition.text,
        definition2: model.definition2.text,
        example: model.example.text,
        exampleZh: model.exampleZh.text,
        note: model.note.text,
        listId: model.listId,
        status: model.status,
      ),
    );
    context.toast(t('words.wordAdded', <String, Object>{'term': trimmed}), ToastKind.ok);
  }
  Navigator.of(context).pop();
}

/* ------------------------------------------------------------------ */
/* Body                                                                */
/* ------------------------------------------------------------------ */

class _EditorBody extends StatelessWidget {
  const _EditorBody({required this.model});

  final _EditorModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (BuildContext context, Widget? _) {
        final t = context.t;
        final AppData data = context.data;
        final String uiLang = context.i18n.lang.wire;
        final WordList? list = data.lists
            .where((WordList l) => l.id == model.listId)
            .firstOrNull ??
            data.lists.firstOrNull;
        final String pairLabel =
            '${langName(list?.sourceLang ?? 'en', uiLang)} → '
            '${langName(list?.targetLang ?? 'zh-CN', uiLang)}';

        final String trimmed = model.term.text.trim();
        final Word? duplicate =
            trimmed.isEmpty ? null : findDuplicate(data, trimmed, model.listId);
        final bool showDuplicate =
            duplicate != null && duplicate.id != model.word?.id;

        return CallbackShortcuts(
          // Cmd/Ctrl+Enter saves from anywhere in the dialog.
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.enter, control: true): () =>
                _save(context, model),
            const SingleActivator(LogicalKeyboardKey.enter, meta: true): () =>
                _save(context, model),
          },
          child: Focus(
            autofocus: true,
            child: PopScope(
              // ×, Esc and the backdrop are all `maybePop`; refusing the pop
              // while dirty routes them into the footer's discard line.
              canPop: !model.dirty,
              onPopInvokedWithResult: (bool didPop, Object? _) {
                if (!didPop) _requestClose(context, model);
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
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
        );
      },
    );
  }

  /* ---- term ---- */
  Widget _termField(BuildContext context, _Translate t) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(child: _label(p, t('words.term'))),
            // The other half of the pair. It sits on the term field because
            // that is the field it would fill, and it stays disabled until
            // there is a meaning to search with — and, in this port, because
            // there is no dictionary client behind it.
            LexButton(
              label: t('words.reverseTranslate'),
              icon: Ic.undo,
              kind: BtnKind.quiet,
              size: BtnSize.sm,
              onPressed: null,
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        LexInput(
          controller: model.term,
          placeholder: t('words.termPlaceholder'),
          autofocus: true,
          onChanged: (String _) => model.setError(''),
          onSubmitted: (String _) {
            // Enter moves on to the meaning instead of saving; Ctrl/⌘+Enter
            // still saves from anywhere.
            if (model.term.text.trim().isEmpty) {
              _save(context, model);
              return;
            }
            model.definitionFocus.requestFocus();
          },
        ),
        if (model.phonetic.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            '/${model.phonetic}/ ${t('words.phonetic')}',
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.xs,
              height: Lh.snug,
              color: p.ink3,
            ),
          ),
        ],
        if (model.error.isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Text(
            model.error,
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
    final p = Palette.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(child: _label(p, t('common.definition'))),
                  Text(
                    pairLabel,
                    style: TextStyle(fontSize: Fs.xs, height: Lh.snug, color: p.ink3),
                  ),
                  const SizedBox(width: Sp.x2),
                  LexButton(
                    label: t('words.translate'),
                    icon: Ic.sparkles,
                    kind: BtnKind.quiet,
                    size: BtnSize.sm,
                    onPressed: null,
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
                      controller: model.pos,
                      placeholder: t('words.posPlaceholder'),
                    ),
                  ),
                  const SizedBox(width: Sp.x2),
                  Expanded(
                    child: LexInput(
                      controller: model.definition,
                      placeholder: t('words.definitionPlaceholder'),
                      focusNode: model.definitionFocus,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: Column(
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
                controller: model.definition2,
                placeholder: t('words.definition2Placeholder'),
              ),
            ],
          ),
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
          controller: model.example,
          placeholder: t('words.examplePlaceholder'),
        ),
        // Only offered once there is a sentence to translate; keyed off the
        // typed value so pasting a sentence reveals it immediately.
        if (model.example.text.trim().isNotEmpty) ...<Widget>[
          const SizedBox(height: Sp.x2),
          LexInput(
            controller: model.exampleZh,
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
          controller: model.note,
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
              value: model.listId,
              options: data.lists.map((WordList l) => l.id).toList(),
              onChanged: model.setListId,
              labelOf: listName,
            ),
          ),
        ),
        const SizedBox(width: Sp.x3),
        Expanded(
          child: LexField(
            label: t('common.status'),
            child: LexSelect<WordStatus>(
              value: model.status,
              options: STATUS_ORDER,
              onChanged: model.setStatus,
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

class _EditorFooter extends StatelessWidget {
  const _EditorFooter({required this.model});

  final _EditorModel model;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: model,
      builder: (BuildContext context, Widget? _) {
        final t = context.t;
        final Word? word = model.word;

        if (model.dismissOpen) {
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                t('words.discardConfirm'),
                style: TextStyle(
                  fontSize: Fs.xs,
                  height: Lh.snug,
                  color: Palette.of(context).ink3,
                ),
              ),
              const SizedBox(width: Sp.x2),
              LexButton(
                label: t('words.keepEditing'),
                size: BtnSize.sm,
                onPressed: () => model.setDismissOpen(false),
              ),
              const SizedBox(width: Sp.x2),
              LexButton(
                label: t('words.discardChanges'),
                kind: BtnKind.danger,
                size: BtnSize.sm,
                onPressed: () {
                  model.setDismissOpen(false);
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        }

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (word != null) ...<Widget>[
              LexButton(
                label: t('common.favorite'),
                icon: model.favorite ? Ic.starFilled : Ic.star,
                kind: model.favorite ? BtnKind.normal : BtnKind.quiet,
                size: BtnSize.sm,
                onPressed: model.toggleFavorite,
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
              const SizedBox(width: Sp.x4),
            ],
            LexButton(
              label: t('common.cancel'),
              onPressed: () => _requestClose(context, model),
            ),
            const SizedBox(width: Sp.x2),
            LexButton(
              label: t('common.save'),
              icon: Ic.check,
              kind: BtnKind.primary,
              onPressed: () => _save(context, model),
            ),
          ],
        );
      },
    );
  }
}
