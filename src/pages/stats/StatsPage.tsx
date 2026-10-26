import type { ReactNode } from "react";
import { useT } from "@/i18n";
import {
  PageShell,
  EmptyState,
  StatTile,
  Ring,
  StatusChip,
  ProgressBar,
} from "@/components/ui";
import { Icon } from "@/components/Icon";
import { useAppData, reviewsToday, streakDays } from "@/lib/store";
import { DAY_MS } from "@/lib/srs";
import { dayKey } from "@/lib/utils";
import { STATUS_ORDER, STATUS_LABEL_KEY } from "@/lib/types";
import type { Grade, WordStatus } from "@/lib/types";

const STATUS_COLOR: Record<WordStatus, string> = {
  new: "var(--ink-4)",
  reviewing: "var(--sky)",
  learning: "var(--amber)",
  mastered: "var(--jade)",
};

const GRADES: Array<{ grade: Grade; labelKey: string; color: string }> = [
  { grade: "hard", labelKey: "flashcards.gradeHard", color: "var(--rose)" },
  { grade: "good", labelKey: "flashcards.gradeGood", color: "var(--jade)" },
  { grade: "easy", labelKey: "flashcards.gradeEasy", color: "var(--sky)" },
];

function SectionCard({
  title,
  right,
  children,
}: {
  title: string;
  right?: ReactNode;
  children: ReactNode;
}) {
  return (
    <section className="card">
      <div className="card-head">
        <div className="card-title">{title}</div>
        {right !== undefined && (
          <div className="card-sub" style={{ marginLeft: "auto" }}>
            {right}
          </div>
        )}
      </div>
      <div
        className="card-pad"
        style={{ display: "flex", flexDirection: "column", gap: "var(--sp-4)" }}
      >
        {children}
      </div>
    </section>
  );
}

export function StatsPage() {
  const t = useT();
  const data = useAppData();
  const now = Date.now();
  const settings = data.settings;

  if (data.words.length === 0) {
    return (
      <PageShell title={t("stats.title")} subtitle={t("stats.subtitle")}>
        <EmptyState icon="stats" title={t("stats.noData")} text={t("stats.noDataHint")} />
      </PageShell>
    );
  }

  const total = data.words.length;
  const mastered = data.words.filter((word) => word.status === "mastered").length;
  const today = reviewsToday(data, now);
  const streak = streakDays(data, now);
  const goal = Math.max(1, settings.dailyGoal);
  const reached = today >= goal;
  const overdue = data.words.filter(
    (word) => word.srs !== null && word.srs.dueAt < now,
  ).length;

  const statusCounts: Record<WordStatus, number> = {
    new: 0,
    reviewing: 0,
    learning: 0,
    mastered: 0,
  };
  for (const word of data.words) statusCounts[word.status] += 1;

  /* Last 14 days of review activity, oldest → today. */
  const days = Array.from({ length: 14 }, (_, index) => {
    const back = 13 - index;
    const date = new Date(now);
    date.setDate(date.getDate() - back);
    return {
      key: dayKey(date.getTime()),
      label: `${date.getMonth() + 1}/${date.getDate()}`,
      count: 0,
      isToday: back === 0,
    };
  });
  const dayByKey = new Map(days.map((day) => [day.key, day]));
  for (const log of data.logs) {
    const hit = dayByKey.get(dayKey(log.at));
    if (hit) hit.count += 1;
  }
  const maxDay = Math.max(1, ...days.map((day) => day.count));
  const sum14 = days.reduce((acc, day) => acc + day.count, 0);

  /* Grade mix over the last 30 days. */
  const cutoff = now - 30 * DAY_MS;
  const gradeCounts: Record<Grade, number> = { hard: 0, good: 0, easy: 0 };
  for (const log of data.logs) {
    if (log.at >= cutoff) gradeCounts[log.grade] += 1;
  }
  const gradeTotal = GRADES.reduce((acc, item) => acc + gradeCounts[item.grade], 0);

  /* Retention: correct answers over all graded reviews, from SRS counters. */
  let reviewSum = 0;
  let correctSum = 0;
  for (const word of data.words) {
    if (!word.srs) continue;
    reviewSum += word.srs.reviewCount;
    correctSum += word.srs.correctCount;
  }
  const retention = reviewSum > 0 ? Math.round((correctSum / reviewSum) * 100) : 0;

  return (
    <PageShell title={t("stats.title")} subtitle={t("stats.subtitle")}>
      {/* Headline numbers */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(168px, 1fr))",
          gap: "var(--sp-4)",
        }}
      >
        <StatTile
          label={t("stats.totalWords")}
          value={total}
          sub={`${t("common.list")} · ${data.lists.length}`}
        />
        <StatTile
          label={t("stats.mastered")}
          value={mastered}
          sub={`${Math.round((mastered / total) * 100)}%`}
          accent="var(--jade)"
        />
        <StatTile
          label={t("stats.reviewsToday")}
          value={today}
          sub={reached ? t("stats.goalReached") : `${t("stats.dailyGoal")} ${goal}`}
        />
        <StatTile
          label={t("stats.streak")}
          value={streak}
          sub={t("stats.streakUnit")}
          accent="var(--amber)"
        />
      </div>

      {/* Daily goal + status distribution */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(320px, 1fr))",
          gap: "var(--sp-5)",
          alignItems: "stretch",
        }}
      >
        <SectionCard title={t("stats.dailyGoal")}>
          <div className="row-flex" style={{ gap: "var(--sp-5)" }}>
            <Ring value={today} max={goal} size={116} stroke={9}>
              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  lineHeight: 1.05,
                }}
              >
                <span
                  style={{
                    fontFamily: "var(--font-display)",
                    fontSize: 26,
                    fontWeight: 600,
                    fontVariantNumeric: "tabular-nums",
                  }}
                >
                  {today}
                </span>
                <span className="tiny muted">/ {goal}</span>
              </div>
            </Ring>
            <div style={{ minWidth: 0, display: "flex", flexDirection: "column", gap: 6 }}>
              <div className="tiny muted">
                {t("stats.todayProgress", { n: today, goal })}
              </div>
              {reached ? (
                <div
                  className="row-flex"
                  style={{ gap: 6, color: "var(--jade)", fontWeight: 540 }}
                >
                  <Icon name="check" size={16} />
                  {t("stats.goalReached")}
                </div>
              ) : (
                <div className="hint">还差 {goal - today} 次复习</div>
              )}
              <div
                className="tiny muted row-flex"
                style={{ gap: 6, marginTop: 2 }}
              >
                <Icon name="flame" size={14} />
                {t("stats.streak")} · {streak} {t("stats.streakUnit")}
              </div>
            </div>
          </div>
        </SectionCard>

        <SectionCard
          title={t("stats.statusDistribution")}
          right={`${total} ${t("common.words")}`}
        >
          {STATUS_ORDER.map((status) => {
            const count = statusCounts[status];
            const pct = total > 0 ? (count / total) * 100 : 0;
            return (
              <div
                key={status}
                style={{ display: "flex", flexDirection: "column", gap: 6 }}
              >
                <div className="row-flex" style={{ gap: "var(--sp-2)" }}>
                  <StatusChip status={status} label={t(STATUS_LABEL_KEY[status])} />
                  <span className="tiny mono muted" style={{ marginLeft: "auto" }}>
                    {count} · {pct.toFixed(0)}%
                  </span>
                </div>
                <div
                  style={{
                    height: 8,
                    borderRadius: 999,
                    background: "var(--surface-2)",
                    overflow: "hidden",
                  }}
                >
                  <div
                    style={{
                      height: "100%",
                      width: `${pct}%`,
                      borderRadius: 999,
                      background: STATUS_COLOR[status],
                      transition: "width 500ms var(--ease-out)",
                    }}
                  />
                </div>
              </div>
            );
          })}
        </SectionCard>
      </div>

      {/* 14-day activity */}
      <SectionCard
        title={t("stats.last14Days")}
        right={`累计 ${sum14} 次`}
      >
        <div>
          <div
            style={{
              display: "flex",
              alignItems: "flex-end",
              gap: 6,
              height: 112,
              borderBottom: "1px solid var(--line)",
            }}
          >
            {days.map((day) => {
              const height =
                day.count === 0
                  ? 0
                  : Math.max(6, Math.round((day.count / maxDay) * 100));
              return (
                <div
                  key={day.key}
                  title={`${day.label} · ${day.count}`}
                  style={{
                    flex: 1,
                    minWidth: 0,
                    height: "100%",
                    display: "flex",
                    alignItems: "flex-end",
                  }}
                >
                  <div
                    style={{
                      width: "100%",
                      height: day.count === 0 ? 3 : `${height}%`,
                      borderRadius: 4,
                      background:
                        day.count === 0 ? "var(--line-strong)" : "var(--jade)",
                      opacity:
                        day.count === 0 ? 0.45 : day.isToday ? 1 : 0.72,
                      transition: "height 420ms var(--ease-out)",
                    }}
                  />
                </div>
              );
            })}
          </div>
          <div style={{ display: "flex", gap: 6, marginTop: 8 }}>
            {days.map((day) => (
              <div
                key={day.key}
                className="tiny"
                style={{
                  flex: 1,
                  minWidth: 0,
                  textAlign: "center",
                  color: day.isToday ? "var(--jade)" : "var(--ink-3)",
                  fontWeight: day.isToday ? 600 : 400,
                }}
              >
                {day.label}
              </div>
            ))}
          </div>
        </div>
      </SectionCard>

      {/* Grade mix + memory health */}
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(300px, 1fr))",
          gap: "var(--sp-5)",
          alignItems: "stretch",
        }}
      >
        <SectionCard title="评分分布" right="近 30 天">
          {GRADES.map((item) => {
            const count = gradeCounts[item.grade];
            const pct = gradeTotal > 0 ? (count / gradeTotal) * 100 : 0;
            return (
              <div
                key={item.grade}
                style={{ display: "flex", flexDirection: "column", gap: 6 }}
              >
                <div className="row-flex" style={{ gap: 8 }}>
                  <span
                    style={{
                      width: 8,
                      height: 8,
                      borderRadius: "50%",
                      background: item.color,
                      flex: "0 0 auto",
                    }}
                  />
                  <span style={{ fontSize: "var(--fs-sm)", fontWeight: 540 }}>
                    {t(item.labelKey)}
                  </span>
                  <span className="tiny mono muted" style={{ marginLeft: "auto" }}>
                    {count} · {pct.toFixed(0)}%
                  </span>
                </div>
                <div
                  style={{
                    height: 8,
                    borderRadius: 999,
                    background: "var(--surface-2)",
                    overflow: "hidden",
                  }}
                >
                  <div
                    style={{
                      height: "100%",
                      width: `${pct}%`,
                      borderRadius: 999,
                      background: item.color,
                      transition: "width 500ms var(--ease-out)",
                    }}
                  />
                </div>
              </div>
            );
          })}
          {gradeTotal === 0 && <div className="hint">还没有评分记录</div>}
        </SectionCard>

        <SectionCard title="记忆留存率">
          <div style={{ display: "flex", alignItems: "baseline", gap: 8 }}>
            <span
              style={{
                fontFamily: "var(--font-display)",
                fontSize: 34,
                fontWeight: 600,
                lineHeight: 1.1,
                color: "var(--jade)",
                fontVariantNumeric: "tabular-nums",
              }}
            >
              {reviewSum > 0 ? `${retention}%` : "—"}
            </span>
            <span className="tiny muted">
              {correctSum} / {reviewSum} 次正确
            </span>
          </div>
          <ProgressBar value={retention} max={100} />
          <div className="divider" />
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "1fr auto",
              rowGap: 10,
              columnGap: "var(--sp-4)",
              alignItems: "center",
            }}
          >
            <span className="tiny muted">逾期词数</span>
            <span
              className="mono"
              style={{
                fontWeight: 600,
                color: overdue > 0 ? "var(--amber)" : "var(--ink)",
              }}
            >
              {overdue}
            </span>
            <span className="tiny muted">{t("stats.totalReviews")}</span>
            <span className="mono" style={{ fontWeight: 600 }}>
              {data.logs.length}
            </span>
          </div>
        </SectionCard>
      </div>
    </PageShell>
  );
}
