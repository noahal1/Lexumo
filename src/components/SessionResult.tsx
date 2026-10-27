/**
 * End-of-session card shared by flashcards and quiz. Both modes finish on the
 * same ring + three-stat layout, so the accuracy figure is formatted here once
 * instead of in each page. The mode-specific bits (which stats, which actions,
 * the ring's fill) come in as props; only the shared shape lives here.
 */
import type { ReactNode } from "react";

import { Ring, StatTile } from "@/components/ui";
import { formatAccuracy } from "@/lib/session";

export function SessionResult({
  accuracy,
  ringValue,
  ringMax,
  ringSize = 136,
  accuracyLabel,
  accuracySub,
  title,
  text,
  leftStat,
  rightStat,
  actions,
  footer,
}: {
  /** correct / reviewed (flashcards) or / total (quiz), 0..1. */
  accuracy: number;
  /** Ring fill, kept separate because the two modes divide by different totals. */
  ringValue: number;
  ringMax: number;
  ringSize?: number;
  accuracyLabel: string;
  accuracySub?: string;
  title: ReactNode;
  text: ReactNode;
  leftStat: ReactNode;
  rightStat: ReactNode;
  actions: ReactNode;
  footer?: ReactNode;
}) {
  const percent = formatAccuracy(accuracy);

  return (
    <div className="card fc-done rise">
      <Ring value={ringValue} max={ringMax} size={ringSize} stroke={9}>
        <div className="fc-done-num">{percent}</div>
        <div className="tiny muted">{accuracyLabel}</div>
      </Ring>
      <div className="stack">
        <h2 className="fc-intro-title">{title}</h2>
        <p className="fc-intro-text">{text}</p>
      </div>
      <div className="fc-stats">
        {leftStat}
        <StatTile label={accuracyLabel} value={percent} sub={accuracySub} />
        {rightStat}
      </div>
      <div className="study-actions">{actions}</div>
      {footer}
    </div>
  );
}
