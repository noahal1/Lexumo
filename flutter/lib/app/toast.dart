/// The toast stack: one provider, one column at the bottom, cards that own their
/// own timers.
///
/// The web build kept this in React state with a `useEffect` per card so that
/// hovering could hold a message open. Here the same behaviour is a
/// [StatefulWidget] per card: it arms a [Timer], pauses it on hover, and closes
/// through a short slide-out so a message never blinks out mid-sentence.
library;

import 'dart:async';

import 'package:flutter/widgets.dart';

import '../design/tokens.dart';
import '../ui/lex_icon.dart';
import 'scope.dart';

/// One message in the stack.
@immutable
class ToastMessage {
  const ToastMessage({
    required this.id,
    required this.text,
    required this.kind,
    required this.durationMs,
    this.actionLabel,
    this.onAction,
  });

  final int id;
  final String text;
  final ToastKind kind;
  final int durationMs;
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// Default dwell per kind. Errors get longer: an error that vanishes while it is
/// still being read is worse than no message at all.
const Map<ToastKind, int> kToastMs = <ToastKind, int>{
  ToastKind.ok: 3200,
  ToastKind.info: 3200,
  ToastKind.err: 6000,
};

/// The stack plus the `show` callback handed to [ToastScope].
///
/// Kept above the shell so a page can raise a toast without knowing where the
/// stack is drawn. At most three cards: a fourth push drops the oldest, which is
/// the same cap the web build used.
class ToastHost extends StatefulWidget {
  const ToastHost({super.key, required this.child});

  final Widget child;

  @override
  State<ToastHost> createState() => ToastHostState();
}

class ToastHostState extends State<ToastHost> {
  final List<ToastMessage> _items = <ToastMessage>[];
  int _seq = 0;

  @override
  void dispose() {
    _items.clear();
    super.dispose();
  }

  void show(
    String text,
    ToastKind kind, {
    String? actionLabel,
    VoidCallback? onAction,
    int? durationMs,
  }) {
    final message = ToastMessage(
      id: ++_seq,
      text: text,
      kind: kind,
      durationMs: durationMs ?? kToastMs[kind]!,
      actionLabel: actionLabel,
      onAction: onAction,
    );
    setState(() {
      // Keep the newest three; the tail is what a user reads.
      if (_items.length >= 3) _items.removeRange(0, _items.length - 2);
      _items.add(message);
    });
  }

  void _dismiss(int id) {
    if (!mounted) return;
    setState(() => _items.removeWhere((m) => m.id == id));
  }

  @override
  Widget build(BuildContext context) {
    return ToastScope(
      show: show,
      child: Stack(
        children: [
          widget.child,
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: IgnorePointer(
              child: SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(Sp.x4, 0, Sp.x4, Sp.x6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final item in _items)
                        Padding(
                          padding: const EdgeInsets.only(top: Sp.x2),
                          child: _ToastCard(
                            key: ValueKey<int>(item.id),
                            message: item,
                            onDismiss: _dismiss,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({super.key, required this.message, required this.onDismiss});

  final ToastMessage message;
  final void Function(int id) onDismiss;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> {
  Timer? _timer;
  bool _held = false;

  @override
  void initState() {
    super.initState();
    _arm();
  }

  @override
  void didUpdateWidget(covariant _ToastCard old) {
    super.didUpdateWidget(old);
    // A new message reuses no state (keyed by id), so nothing to re-arm.
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _arm() {
    _timer?.cancel();
    if (_held) return;
    // 400ms floor: an action-carrying toast still has to be reachable.
    final ms = widget.message.durationMs < 400 ? 400 : widget.message.durationMs;
    _timer = Timer(Duration(milliseconds: ms), _close);
  }

  void _close() {
    _timer?.cancel();
    widget.onDismiss(widget.message.id);
  }

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final m = widget.message;
    final icon = switch (m.kind) {
      ToastKind.ok => Ic.check,
      ToastKind.err => Ic.alert,
      ToastKind.info => Ic.info,
    };
    final iconColor = switch (m.kind) {
      ToastKind.ok => p.accent,
      ToastKind.err => p.danger,
      ToastKind.info => p.warn,
    };

    return MouseRegion(
      onEnter: (_) {
        _held = true;
        _timer?.cancel();
      },
      onExit: (_) {
        _held = false;
        _arm();
      },
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: GestureDetector(
          onTap: m.onAction == null ? _close : null,
          child: Container(
            padding: EdgeInsets.fromLTRB(Sp.x4, Sp.x2, m.onAction == null ? Sp.x4 : Sp.x2, Sp.x2),
            decoration: BoxDecoration(
              // Inverted ink: a receipt on the paper, not a celebration.
              color: p.ink,
              borderRadius: R.borderSm,
              boxShadow: p.isDark ? Shadows.popDark : Shadows.pop,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                LexIcon(icon, size: 14, color: iconColor),
                const SizedBox(width: Sp.x2),
                Flexible(
                  child: Text(
                    m.text,
                    style: TextStyle(
                      fontSize: Fs.sm,
                      height: Lh.snug,
                      fontWeight: FontWeight.w500,
                      color: p.bg,
                    ),
                  ),
                ),
                if (m.actionLabel != null) ...[
                  const SizedBox(width: Sp.x3),
                  _ToastAction(
                    label: m.actionLabel!,
                    onTap: () {
                      m.onAction?.call();
                      _close();
                    },
                  ),
                ],
                const SizedBox(width: Sp.x2),
                _ToastClose(onTap: _close, color: p.bg),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastAction extends StatelessWidget {
  const _ToastAction({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: Sp.x1),
          decoration: BoxDecoration(
            color: p.wash,
            borderRadius: R.borderXs,
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: Fs.sm,
              fontWeight: FontWeight.w600,
              color: p.bg,
              decoration: TextDecoration.underline,
              decorationColor: p.bg,
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastClose extends StatelessWidget {
  const _ToastClose({required this.onTap, required this.color});

  final VoidCallback onTap;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: SizedBox(
          width: 22,
          height: 22,
          child: Center(child: LexIcon(Ic.x, size: 12, color: color.withValues(alpha: 0.65))),
        ),
      ),
    );
  }
}
