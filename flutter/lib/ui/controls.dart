/// Form controls: buttons, text fields, selects, checkboxes and the modal.
///
/// The web build got these from `.btn`, `.input` and `.modal` rules in
/// `global.css`; Flutter has no stylesheet, so each recipe is one widget here.
/// The rules that matter are carried over verbatim:
///
///   · one filled button per screen — the fill *is* the signal, no shadow,
///   · a field's edge is held at 3:1 (it is the only thing that says "you can
///     type here"), and focus moves the *border* colour, never its width, so
///     nothing reflows when a field is focused,
///   · a modal is dismissed by Escape or the backdrop, and never stacks on
///     another modal.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../app/scope.dart';
import '../design/tokens.dart';
import 'density.dart';
import 'lex_icon.dart';

/// Button recipes, mirroring `.btn` + its modifiers.
enum BtnKind {
  /// Paper fill, strong hairline. The default.
  normal,

  /// Accent fill. One per screen.
  primary,

  /// No chrome until hover. For toolbars and row actions.
  ghost,

  /// Quiet, for the third thing in a dialog.
  quiet,

  /// Danger outline, for destructive confirmation.
  danger,
}

enum BtnSize { sm, md, lg }

class LexButton extends StatefulWidget {
  const LexButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.kind = BtnKind.normal,
    this.size = BtnSize.md,
    this.icon,
    this.block = false,
    this.trailing,
  });

  final String label;
  final VoidCallback? onPressed;
  final BtnKind kind;
  final BtnSize size;
  final String? icon;
  final bool block;
  final Widget? trailing;

  @override
  State<LexButton> createState() => _LexButtonState();
}

class _LexButtonState extends State<LexButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final enabled = widget.onPressed != null;

    final (Color bg, Color fg, Color line) = switch (widget.kind) {
      BtnKind.normal => (
          _hover ? p.surfaceHover : p.surface,
          p.ink,
          p.lineStrong,
        ),
      BtnKind.primary => (
          _hover ? p.accentHover : p.accent,
          p.onAccent,
          Colors.transparent,
        ),
      BtnKind.ghost => (
          _hover ? p.surfaceHover : Colors.transparent,
          _hover ? p.ink : p.ink2,
          Colors.transparent,
        ),
      BtnKind.quiet => (
          _hover ? p.surfaceHover : Colors.transparent,
          _hover ? p.ink : p.ink3,
          Colors.transparent,
        ),
      BtnKind.danger => (
          _hover ? p.dangerSoft : Colors.transparent,
          p.danger,
          p.danger,
        ),
    };

    // The design height is a mouse measurement. A fingertip cannot reliably hit
    // a 32px button, and a row of three of them is where the wrong word gets
    // deleted — so on touch the box grows to `Layout.tap`. The label size and
    // padding are untouched: only the box the finger aims at gets bigger.
    final height = switch (widget.size) {
      BtnSize.sm => context.controlHSm,
      BtnSize.md => context.controlH,
      BtnSize.lg => math.max(40.0, context.controlH),
    };
    final fontSize = switch (widget.size) {
      BtnSize.sm => Fs.sm,
      BtnSize.md => Fs.base,
      BtnSize.lg => Fs.md,
    };
    final padH = switch (widget.size) {
      BtnSize.sm => Sp.x2,
      BtnSize.md => Sp.x3,
      BtnSize.lg => Sp.x5,
    };

    final content = Row(
      mainAxisSize: widget.block ? MainAxisSize.max : MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (widget.icon != null) ...[
          LexIcon(widget.icon!, size: 16, color: fg),
          const SizedBox(width: Sp.x2),
        ],
        Flexible(
          child: Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: fontSize, fontWeight: FontWeight.w500, color: fg),
          ),
        ),
        if (widget.trailing != null) ...[
          const SizedBox(width: Sp.x1),
          widget.trailing!,
        ],
      ],
    );

    return Opacity(
      opacity: enabled ? 1 : 0.55,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: Container(
            height: height,
            padding: EdgeInsets.symmetric(horizontal: padH),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: R.borderSm,
              border: Border.all(color: line),
            ),
            child: ContentCenter(child: content),
          ),
        ),
      ),
    );
  }
}

/// Centres [child] without [Row]'s unbounded-height trouble inside a fixed
/// height box.
class ContentCenter extends StatelessWidget {
  const ContentCenter({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => Center(widthFactor: 1, child: child);
}

/// A labelled field: `label`, then the control, then an optional hint.
class LexField extends StatelessWidget {
  const LexField({
    super.key,
    required this.label,
    required this.child,
    this.hint,
    this.error,
  });

  final String label;
  final Widget child;
  final String? hint;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(fontSize: Fs.sm, fontWeight: FontWeight.w500, color: p.ink2),
        ),
        const SizedBox(height: Sp.x2),
        child,
        if (error != null) ...[
          const SizedBox(height: Sp.x1),
          Text(error!, style: TextStyle(fontSize: Fs.xs, color: p.danger)),
        ] else if (hint != null) ...[
          const SizedBox(height: Sp.x1),
          Text(hint!, style: TextStyle(fontSize: Fs.xs, color: p.ink3)),
        ],
      ],
    );
  }
}

/// A single-line input. Focus moves the border colour only.
class LexInput extends StatefulWidget {
  const LexInput({
    super.key,
    required this.controller,
    this.placeholder,
    this.onChanged,
    this.onSubmitted,
    this.autofocus = false,
    this.obscure = false,
    this.numeric = false,
    this.prefix,
    this.suffix,
    this.focusNode,
  });

  final TextEditingController controller;
  final String? placeholder;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool autofocus;
  final bool obscure;
  final bool numeric;
  final Widget? prefix;
  final Widget? suffix;
  final FocusNode? focusNode;

  @override
  State<LexInput> createState() => _LexInputState();
}

class _LexInputState extends State<LexInput> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      // A field you type into is the one control a phone cannot shrink: the
      // finger has to land in it before the keyboard appears.
      height: context.controlH,
      decoration: BoxDecoration(
        color: _focus ? p.surface : p.surface2,
        borderRadius: R.borderSm,
        border: Border.all(color: _focus ? p.accent : p.lineControl),
      ),
      child: Row(
        children: [
          if (widget.prefix != null) ...[
            const SizedBox(width: Sp.x3),
            widget.prefix!,
            const SizedBox(width: Sp.x2),
          ] else
            const SizedBox(width: Sp.x3),
          Expanded(
            child: Focus(
              onFocusChange: (v) => setState(() => _focus = v),
              child: TextField(
                controller: widget.controller,
                focusNode: widget.focusNode,
                autofocus: widget.autofocus,
                obscureText: widget.obscure,
                onChanged: widget.onChanged,
                onSubmitted: widget.onSubmitted,
                keyboardType: widget.numeric ? TextInputType.number : null,
                inputFormatters:
                    widget.numeric ? [FilteringTextInputFormatter.digitsOnly] : null,
                cursorColor: p.accent,
                style: TextStyle(fontSize: Fs.base, color: p.ink),
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  border: InputBorder.none,
                  hintText: widget.placeholder,
                  hintStyle: TextStyle(fontSize: Fs.base, color: p.ink3),
                  contentPadding: EdgeInsets.zero,
                ),
              ),
            ),
          ),
          if (widget.suffix != null) ...[
            widget.suffix!,
            const SizedBox(width: Sp.x2),
          ] else
            const SizedBox(width: Sp.x3),
        ],
      ),
    );
  }
}

/// A multi-line input, for definitions, examples and notes.
class LexTextArea extends StatefulWidget {
  const LexTextArea({
    super.key,
    required this.controller,
    this.placeholder,
    this.minHeight = 76,
    this.onChanged,
  });

  final TextEditingController controller;
  final String? placeholder;
  final double minHeight;
  final ValueChanged<String>? onChanged;

  @override
  State<LexTextArea> createState() => _LexTextAreaState();
}

class _LexTextAreaState extends State<LexTextArea> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Container(
      constraints: BoxConstraints(minHeight: widget.minHeight),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
      decoration: BoxDecoration(
        color: _focus ? p.surface : p.surface2,
        borderRadius: R.borderSm,
        border: Border.all(color: _focus ? p.accent : p.lineControl),
      ),
      child: Focus(
        onFocusChange: (v) => setState(() => _focus = v),
        child: TextField(
          controller: widget.controller,
          onChanged: widget.onChanged,
          maxLines: null,
          minLines: 3,
          cursorColor: p.accent,
          style: TextStyle(fontSize: Fs.base, height: Lh.body, color: p.ink),
          decoration: InputDecoration(
            isDense: true,
            filled: false,
            border: InputBorder.none,
            hintText: widget.placeholder,
            hintStyle: TextStyle(fontSize: Fs.base, color: p.ink3),
            contentPadding: EdgeInsets.zero,
          ),
        ),
      ),
    );
  }
}

/// A labelled option list rendered as a tappable row — the Flutter stand-in for
/// `<select>`. Deliberately not a [DropdownButton]: the app's chrome is
/// square-cornered and borderless, and Material's menu would not match it.
class LexSelect<T> extends StatelessWidget {
  const LexSelect({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    required this.labelOf,
  });

  final T value;
  final List<T> options;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;

  @override
  Widget build(BuildContext context) {
    return _SelectButton<T>(
      value: value,
      options: options,
      onChanged: onChanged,
      labelOf: labelOf,
    );
  }
}

class _SelectButton<T> extends StatefulWidget {
  const _SelectButton({
    required this.value,
    required this.options,
    required this.onChanged,
    required this.labelOf,
  });

  final T value;
  final List<T> options;
  final ValueChanged<T> onChanged;
  final String Function(T) labelOf;

  @override
  State<_SelectButton<T>> createState() => _SelectButtonState<T>();
}

class _SelectButtonState<T> extends State<_SelectButton<T>> {
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return MenuAnchor(
      builder: (ctx, controller, child) => MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Focus(
          onFocusChange: (v) => setState(() => _focus = v),
          child: GestureDetector(
            onTap: () => controller.isOpen ? controller.close() : controller.open(),
            child: Container(
              height: context.controlH,
              padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
              decoration: BoxDecoration(
                color: p.surface2,
                borderRadius: R.borderSm,
                border: Border.all(color: _focus ? p.accent : p.lineControl),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.labelOf(widget.value),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: Fs.base, color: p.ink),
                    ),
                  ),
                  const SizedBox(width: Sp.x2),
                  LexIcon(Ic.chevronDown, size: 14, color: p.ink3),
                ],
              ),
            ),
          ),
        ),
      ),
      menuChildren: [
        for (final option in widget.options)
          MenuItemButton(
            onPressed: () => widget.onChanged(option),
            style: ButtonStyle(
              backgroundColor: WidgetStatePropertyAll<Color>(
                option == widget.value ? p.surfaceHover : p.surface,
              ),
              shape: WidgetStatePropertyAll<OutlinedBorder>(
                RoundedRectangleBorder(borderRadius: R.borderXs),
              ),
              minimumSize: const WidgetStatePropertyAll<Size>(Size(180, 40)),
            ),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                widget.labelOf(option),
                style: TextStyle(fontSize: Fs.sm, color: p.ink),
              ),
            ),
          ),
      ],
    );
  }
}

/// The dialog shell: title, optional subtitle, body, footer.
///
/// Escape and the backdrop both close it unless [dismissible] is false. The
/// body scrolls; the head and foot do not, so a long form never pushes its
/// buttons off-screen.
///
/// [onDispose] runs when the dialog's subtree is finally unmounted — after the
/// exit animation, not when the future completes. A caller that owns
/// controllers (see `showWordEditor`) must clean up here: disposing as soon as
/// the future resolves tears them down while the closing frame is still being
/// built, and the framework then throws "A TextEditingController was used after
/// being disposed".
Future<T?> showLexModal<T>({
  required BuildContext context,
  required String title,
  String? subtitle,
  required Widget body,
  Widget? footer,
  double width = 560,
  bool dismissible = true,
  bool barrierDismissible = true,
  VoidCallback? onDispose,
}) {
  return showDialog<T>(
    context: context,
    barrierDismissible: dismissible && barrierDismissible,
    barrierColor: Palette.of(context).scrim,
    builder: (ctx) {
      final p = Palette.of(ctx);
      return _ModalShell(
        onDispose: onDispose,
        child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () {
            if (dismissible) Navigator.of(ctx).maybePop();
          },
        },
        child: Focus(
          autofocus: true,
          child: Dialog(
            backgroundColor: Colors.transparent,
            elevation: 0,
            insetPadding: const EdgeInsets.all(Sp.x4),
            child: Container(
              width: width,
              constraints: const BoxConstraints(maxHeight: 720),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: R.borderLg,
                boxShadow: p.isDark ? Shadows.overlayDark : Shadows.overlay,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x5, Sp.x6, Sp.x3),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                title,
                                style: TextStyle(
                                  fontFamily: Fonts.display,
                                  fontSize: Fs.lg,
                                  height: Lh.title,
                                  fontWeight: FontWeight.w600,
                                  color: p.ink,
                                ),
                              ),
                              if (subtitle != null) ...[
                                const SizedBox(height: 2),
                                Text(
                                  subtitle,
                                  style: TextStyle(fontSize: Fs.sm, height: Lh.snug, color: p.ink3),
                                ),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: Sp.x3),
                        _ModalClose(onTap: () => Navigator.of(ctx).maybePop()),
                      ],
                    ),
                  ),
                  Flexible(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.fromLTRB(Sp.x6, 0, Sp.x6, Sp.x5),
                      child: body,
                    ),
                  ),
                  if (footer != null)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(Sp.x6, 0, Sp.x6, Sp.x5),
                      child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [footer]),
                    ),
                ],
              ),
            ),
          ),
        ),
        ),
      );
    },
  );
}

/// Runs [onDispose] once the dialog is gone for good.
///
/// The dialog's future completes when the route is popped, which is *before*
/// the exit animation unmounts the body. Anything the body still reads on that
/// last frame has to stay alive until here.
class _ModalShell extends StatefulWidget {
  const _ModalShell({required this.child, this.onDispose});

  final Widget child;
  final VoidCallback? onDispose;

  @override
  State<_ModalShell> createState() => _ModalShellState();
}

class _ModalShellState extends State<_ModalShell> {
  @override
  void dispose() {
    widget.onDispose?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _ModalClose extends StatelessWidget {
  const _ModalClose({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          width: 28,
          height: 28,
          child: Center(child: LexIcon(Ic.x, size: 15, color: p.ink3)),
        ),
      ),
    );
  }
}

/// The two-button confirmation the web build used for every destructive action.
Future<bool> confirmLex(
  BuildContext context, {
  required String title,
  String? subtitle,
  String? confirmLabel,
  String? cancelLabel,
  bool danger = false,
}) async {
  final result = await showLexModal<bool>(
    context: context,
    title: title,
    subtitle: subtitle,
    width: 440,
    body: const SizedBox.shrink(),
    footer: Row(
      children: [
        LexButton(
          label: cancelLabel ?? context.t('common.cancel'),
          kind: BtnKind.quiet,
          onPressed: () => Navigator.of(context).pop(false),
        ),
        const SizedBox(width: Sp.x2),
        LexButton(
          label: confirmLabel ?? context.t('common.confirm'),
          kind: danger ? BtnKind.danger : BtnKind.primary,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    ),
  );
  return result ?? false;
}
