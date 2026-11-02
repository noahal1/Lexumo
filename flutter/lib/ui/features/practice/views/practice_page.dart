/// The practice screen: one destination for both ways of practising a deck.
///
/// Mirrors the reference's 「练习」 entry point — a single tab whose page flips
/// between review (flashcards) and quiz, where the old build had two separate
/// destinations for them. The two sub-pages keep their own view models, focus
/// nodes and keyboard bindings; this page owns only the [PracticeMode] switch
/// and the segmented control that changes it.
///
/// Only the active sub-page is built, never both: each carries its own
/// [ScrollController] target (the shell's one controller per destination) and
/// its own [FocusNode], and keeping both in the tree would fight over the same
/// scroll position and the same keyboard. Switching mode drops an in-flight
/// session on the page you leave — that is the point of switching.
library;

import 'package:flutter/material.dart';

import '../../../../app/scope.dart';
import '../../../core/tokens.dart';
import '../../../core/widgets/widgets.dart';
import '../../flashcards/views/flashcards_page.dart';
import '../../quiz/views/quiz_page.dart';

/// The two faces of a practice session, in the order the segmented control
/// presents them.
enum PracticeMode { review, quiz }

class PracticePage extends StatefulWidget {
  const PracticePage({super.key, this.controller});

  /// Owned by the shell, so the page scroll position survives a page switch.
  final ScrollController? controller;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> {
  PracticeMode _mode = PracticeMode.review;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(context),
        Expanded(
          // One page at a time: see the header comment on why both are never
          // mounted together.
          child: _mode == PracticeMode.review
              ? FlashcardsPage(controller: widget.controller)
              : QuizPage(controller: widget.controller),
        ),
      ],
    );
  }

  /// The mode switch, left-aligned on the same measure the sub-pages use so the
  /// picker reads as the page's own header rather than a floating control. The
  /// switch carries the top spacing; the sub-page below it starts its own body
  /// padding, so this header ends flush and the two spacings do not stack.
  /// Scrollable, not stretched, so a 2x text scale can widen the two labels
  /// without a RenderFlex overflow — the same guard the quiz page's direction
  /// picker already carries.
  Widget _header(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x6, 0),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: Layout.contentMax),
          child: Align(
            alignment: AlignmentDirectional.centerStart,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Segmented<PracticeMode>(
                value: _mode,
                options: <SegOption<PracticeMode>>[
                  SegOption<PracticeMode>(
                    value: PracticeMode.review,
                    label: context.t('practice.review'),
                  ),
                  SegOption<PracticeMode>(
                    value: PracticeMode.quiz,
                    label: context.t('practice.quiz'),
                  ),
                ],
                onChanged: (PracticeMode m) => setState(() => _mode = m),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
