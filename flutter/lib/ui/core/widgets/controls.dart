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

import '../../../app/scope.dart';
import '../tokens.dart';
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

  /// Held down right now. The press is a 1.5% contraction, not a colour change:
  /// the web build's `.btn:active { transform: scale(0.985) }`. A colour change
  /// on press would compete with the hover tint and make a deliberate press look
  /// like a hover that has not finished yet.
  bool _pressed = false;

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
          _hover ? p.surfaceHover : fadeFrom(p.surfaceHover),
          _hover ? p.ink : p.ink2,
          Colors.transparent,
        ),
      BtnKind.quiet => (
          _hover ? p.surfaceHover : fadeFrom(p.surfaceHover),
          _hover ? p.ink : p.ink3,
          Colors.transparent,
        ),
      BtnKind.danger => (
          _hover ? p.dangerSoft : fadeFrom(p.dangerSoft),
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
      // A press has to be visible on touch too, where there is no hover to
      // signal that the button was in fact aimed at. `onTapDown`/`onTapCancel`
      // bracket the gesture; `onTap` still owns the callback so a drag that
      // turns into a scroll cancels the press without firing.
      child: AnimatedScale(
        scale: _pressed && enabled ? 0.985 : 1,
        duration: _pressed ? Motion.dur1 : Motion.dur2,
        curve: Motion.ease,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          child: GestureDetector(
            onTap: widget.onPressed,
            onTapDown: enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel: enabled ? () => setState(() => _pressed = false) : null,
            child: AnimatedContainer(
              duration: Motion.dur1,
              curve: Motion.ease,
              height: height,
              padding: EdgeInsets.symmetric(horizontal: padH),
              decoration: BoxDecoration(
                color: bg,
                // Every button is a capsule. The page's reading surface is the
                // only square-cornered thing left, so a button reads as an
                // object you press rather than a piece of the page.
                borderRadius: R.borderPill,
                border: Border.all(color: line),
              ),
              child: ContentCenter(child: content),
            ),
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
    return AnimatedContainer(
      duration: Motion.dur1,
      curve: Curves.easeOut,
      // A field you type into is the one control a phone cannot shrink: the
      // finger has to land in it before the keyboard appears.
      height: context.controlH,
      decoration: BoxDecoration(
        // A pill: the reference's field is a filled capsule with no outline of
        // its own. Focus is the only time a line appears.
        color: _focus ? p.surface : p.surface2,
        borderRadius: R.borderPill,
        border: Border.all(color: _focus ? p.accent : fadeFrom(p.accent)),
      ),
      child: Row(
        children: [
          if (widget.prefix != null) ...[
            const SizedBox(width: Sp.x4),
            widget.prefix!,
            const SizedBox(width: Sp.x2),
          ] else
            const SizedBox(width: Sp.x4),
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
                  // The theme's decoration draws its own fill and borders; a
                  // call-site `border` alone does NOT suppress the theme's
                  // enabled/focused borders, which is how every field ended up
                  // with two outlines. All of it is pinned off here.
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
            const SizedBox(width: Sp.x4),
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
    return AnimatedContainer(
      duration: Motion.dur1,
      curve: Curves.easeOut,
      constraints: BoxConstraints(minHeight: widget.minHeight),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
      decoration: BoxDecoration(
        color: _focus ? p.surface : p.surface2,
        // Same capsule as [LexInput] — a multi-line field is still a field.
        borderRadius: R.borderLg,
        border: Border.all(color: _focus ? p.accent : fadeFrom(p.accent)),
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

/// The web build's `.switch`.
///
/// Material's [Switch] is not an option here: it ships a 48px touch target, a
/// ripple, its own thumb shadow and a colour-scheme mapping, so it reads as a
/// foreign object on this app's pages. This is 42×24 with a 2px inset knob and
/// a 120ms border tint on hover, matching `.switch` exactly.
///
/// It lived in the settings page while that was the only screen with a switch.
/// The practice front page has two, and copying it would have meant two
/// switches that drift apart one tweak at a time — the same reason every other
/// control in this file is here.
class LexSwitch extends StatefulWidget {
  const LexSwitch({
    super.key,
    required this.checked,
    required this.label,
    required this.onChanged,
  });

  final bool checked;

  /// The switch's accessible name. Drawn nowhere: the row that holds the
  /// switch prints the label, and printing it twice is a bug on a phone.
  final String label;

  final ValueChanged<bool> onChanged;

  @override
  State<LexSwitch> createState() => _LexSwitchState();
}

class _LexSwitchState extends State<LexSwitch> {
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
                  border: Border.all(
                    color: on ? p.accent : (_hover ? p.accent : p.lineStrong),
                  ),
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

/// A number you nudge one at a time: round minus, figure, round plus.
///
/// A text field would let somebody type 4000 into a field that means "how many
/// cards this sitting", and the clamp would then have to silently rewrite what
/// they typed. Stepping cannot produce a value outside the range at all, and
/// the figure stays centred between the two controls so the row reads as one
/// object rather than as a field with ornaments.
///
/// The ends are disabled rather than wrapped: at the floor the minus greys out,
/// which says "this is as small as it goes" instead of silently doing nothing.
class LexStepper extends StatelessWidget {
  const LexStepper({
    super.key,
    required this.value,
    required this.min,
    required this.max,
    required this.onChanged,
    this.decrementLabel,
    this.incrementLabel,
  });

  final int value;
  final int min;
  final int max;
  final ValueChanged<int> onChanged;

  /// Accessible names for the two buttons; they carry no text of their own.
  final String? decrementLabel;
  final String? incrementLabel;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        _StepButton(
          icon: Ic.minimize,
          label: decrementLabel,
          onPressed: value > min ? () => onChanged(value - 1) : null,
        ),
        // A fixed slot, so the row does not shuffle sideways when the count
        // crosses 10 and gains a digit.
        ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44),
          child: Text(
            '$value',
            textAlign: TextAlign.center,
            maxLines: 1,
            style: TextStyle(
              fontFamily: Fonts.mono,
              fontSize: Fs.md,
              height: Lh.tight,
              fontWeight: FontWeight.w600,
              color: p.ink,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
        _StepButton(
          icon: Ic.plus,
          label: incrementLabel,
          onPressed: value < max ? () => onChanged(value + 1) : null,
        ),
      ],
    );
  }
}

class _StepButton extends StatefulWidget {
  const _StepButton({
    required this.icon,
    required this.onPressed,
    this.label,
  });

  final String icon;
  final VoidCallback? onPressed;
  final String? label;

  @override
  State<_StepButton> createState() => _StepButtonState();
}

class _StepButtonState extends State<_StepButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final bool enabled = widget.onPressed != null;
    final Color fg = enabled ? p.ink : p.ink4;
    final Color line = !enabled
        ? fadeFrom(p.line)
        : (_hover ? p.accent : p.lineStrong);
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hover = true),
        onExit: (_) => setState(() => _hover = false),
        child: GestureDetector(
          onTap: widget.onPressed,
          child: TapTarget(
            child: AnimatedContainer(
              duration: Motion.dur1,
              curve: Motion.ease,
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: _hover && enabled ? p.surfaceHover : p.surface,
                shape: BoxShape.circle,
                border: Border.all(color: line),
              ),
              child: Center(child: LexIcon(widget.icon, size: 15, color: fg)),
            ),
          ),
        ),
      ),
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
