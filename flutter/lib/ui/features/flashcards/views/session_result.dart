/// End-of-session card shared by the flashcards and quiz pages.
///
/// Ports `src/components/SessionResult.tsx`. Both study modes finish on the
/// same ring + three-stat layout, so the accuracy figure is formatted in one
/// place instead of twice. The mode-specific parts (which stats, which actions,
/// what the ring measures) come in as parameters; only the shared shape lives
/// here.
library;

// `Card` is ours (ui/widgets.dart), not Material's, so the Material one is
// hidden rather than imported ambiguously.
import 'package:flutter/material.dart' hide Card;

import '../../../core/tokens.dart';
import '../../../../domain/models/session.dart';
import '../../../core/widgets/entrance.dart';
import '../../../core/widgets/widgets.dart';

/// The finished-session summary.
///
/// [accuracy] is correct / reviewed for flashcards and correct / total for the
/// quiz, 0..1. [ringValue] and [ringMax] are separate because the two modes
/// divide by different totals — the ring can show progress while the number in
/// its middle shows accuracy.
class SessionResult extends StatelessWidget {
  const SessionResult({
    super.key,
    required this.accuracy,
    required this.ringValue,
    required this.ringMax,
    this.ringSize = 136,
    required this.accuracyLabel,
    this.accuracySub,
    required this.title,
    required this.text,
    required this.leftStat,
    required this.rightStat,
    required this.actions,
    this.footer,
  });

  final double accuracy;
  final double ringValue;
  final double ringMax;
  final double ringSize;
  final String accuracyLabel;
  final String? accuracySub;
  final String title;
  final String text;
  final Widget leftStat;
  final Widget rightStat;
  final List<Widget> actions;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    final p = Palette.of(context);
    final percent = formatAccuracy(accuracy);

    // The web build hangs `.rise` on this card (`SessionResult.tsx:44`): the one
    // moment in the app that is worth an entrance, because it is the only screen
    // that arrives on its own rather than in response to a tap inside it.
    return FadeRise(
      offset: 10,
      child: Card(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(
            child: Ring(
              value: ringValue,
              max: ringMax,
              size: ringSize,
              stroke: 9,
              children: [
                Text(
                  percent,
                  style: TextStyle(
                    fontFamily: Fonts.display,
                    fontSize: Fs.x2xl,
                    height: Lh.display,
                    fontWeight: FontWeight.w600,
                    color: p.ink,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  accuracyLabel,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: Fs.xs, height: Lh.tight, color: p.ink3),
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x6),
          Text(
            title,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: Fonts.display,
              fontSize: Fs.xl,
              height: Lh.title,
              fontWeight: FontWeight.w600,
              color: p.ink,
            ),
          ),
          const SizedBox(height: Sp.x2),
          Text(
            text,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: Fs.base, height: Lh.body, color: p.ink2),
          ),
          const SizedBox(height: Sp.x6),
          Row(
            children: [
              Expanded(child: leftStat),
              const SizedBox(width: Sp.x3),
              Expanded(
                child: StatTile(
                  label: accuracyLabel,
                  value: percent,
                  sub: accuracySub,
                ),
              ),
              const SizedBox(width: Sp.x3),
              Expanded(child: rightStat),
            ],
          ),
          const SizedBox(height: Sp.x6),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (var i = 0; i < actions.length; i++) ...[
                if (i > 0) const SizedBox(width: Sp.x3),
                actions[i],
              ],
            ],
          ),
            if (footer != null) ...[
              const SizedBox(height: Sp.x4),
              footer!,
            ],
          ],
        ),
      ),
    );
  }
}
