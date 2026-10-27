import { useState, type ReactNode } from "react";
import { EmptyState, PageShell, Ring, Segmented, StatTile } from "@/components/ui";
import { useRouter } from "@/app/router";
import { useT, type MessageKey } from "@/i18n";
import { useAppData } from "@/lib/store";
import { DAY_MS, formatInterval } from "@/lib/srs";
import { STATUS_LABEL_KEY, STATUS_ORDER, type Grade, type WordStatus } from "@/lib/types";
import { dayKey, startOfDay } from "@/lib/utils";
import { summarize } from "@/lib/wordIndex";
import "@/styles/insights.css";

/* ------------------------------------------------------------------ */
/* Constants                                                           */
/* ------------------------------------------------------------------ */

const RANGE_OPTIONS = [
  { value: "7", days: 7 },
  { value: "30", days: 30 },
  { value: "90", days: 90 },
] as const;

type Range = (typeof RANGE_OPTIONS)[number]["value"];

/* Status and grade both read as one progress ramp in azurite. This screen's job
   is to show how far words have come, not to run a six-hue legend, and cinnabar
   stays reserved for destruction so it never appears in a chart. */
const STATUS_COLOR: Record<WordStatus, string> = {
  new: "var(--ink-4)",
  reviewing: "color-mix(in srgb, var(--accent) 34%, var(--surface))",
  learning: "color-mix(in srgb, var(--accent) 64%, var(--surface))",
  mastered: "var(--accent)",
};

const GRADES: Array<{ grade: Grade; labelKey: MessageKey; color: string }> = [
  { grade: "hard", labelKey: "flashcards.gradeHard", color: "var(--ink-3)" },
  {
    grade: "good",
    labelKey: "flashcards.gradeGood",
    color: "color-mix(in srgb, var(--accent) 55%, var(--surface))",
  },
  { grade: "easy", labelKey: "flashcards.gradeEasy", color: "var(--accent)" },
];

/* ------------------------------------------------------------------ */
/* Small local building blocks                                         */
/* ------------------------------------------------------------------ */

function CardHead({
  title,
  sub,
  right,
}: {
  title: string;
  sub?: string;
  right?: ReactNode;
}) {
  return (
    <div className="card-head">
      <div style={{ minWidth: 0 }}>
        <div className="card-title">{title}</div>
        {sub && <div className="card-sub">{sub}</div>}
      </div>
      {right && <div className="dash-head-ctl">{right}</div>}
    </div>
  );
}

function DistRow({
  name,
  count,
  pct,
  color,
}: {
  name: string;
  count: number;
  pct: number;
  color: string;
}) {
  return (
    <div className="dist-item">
      <div className="dist-head">
        <span className="dist-name">{name}</span>
        <span className="dist-num">
          {count}（{pct}%）
        </span>
      </div>
      <div
        className="progress thick"
        role="progressbar"
        aria-valuenow={pct}
        aria-valuemin={0}
        aria-valuemax={100}
        aria-label={name}
      >
        <div
          className="progress-fill"
          style={{ transform: `scaleX(${pct / 100})`, background: color }}
        />
      </div>
    </div>
  );
}

function KvRow({
  label,
  value,
  warn,
}: {
  label: string;
  value: ReactNode;
  warn?: boolean;
}) {
  return (
    <div className="kv-row">
      <span className="kv-key">{label}</span>
      <span className={warn ? "kv-val is-warn" : "kv-val"}>{value}</span>
    </div>
  );
}

/* ------------------------------------------------------------------ */
/* Page                                                                */
/* ------------------------------------------------------------------ */

export function StatsPage() {
  const t = useT();
  const { navigate } = useRouter();
  const data = useAppData();
  const [range, setRange] = useState<Range>("30");

  const now = Date.now();
  const days = range === "7" ? 7 : range === "30" ? 30 : 90;

  /* Headline numbers -------------------------------------------------
     One summarize() call owns the arithmetic. The activity series and the
     grade mix below stay in the page: they depend on the selected range. */
  const {
    total,
    statusCounts,
    mastered,
    today,
    streak,
    goal,
    goalPct,
    reached,
    remaining,
    masteryPct,
    retention,
    avgInterval,
    overdue,
    dueToday,
    reviewSum,
    correctSum,
    reviewedWords,
    scheduled,
  } = summarize(data, now);

  const todayStart = startOfDay(now);

  /* Activity series -------------------------------------------------- */
  const countByDay = new Map<string, number>();
  for (const log of data.logs) {
    const key = dayKey(log.at);
    countByDay.set(key, (countByDay.get(key) ?? 0) + 1);
  }
  const series = Array.from({ length: days }, (_, i) => {
    const ts = todayStart - (days - 1 - i) * DAY_MS;
    const date = new Date(ts);
    const key = dayKey(ts);
    return {
      key,
      label: `${date.getMonth() + 1}/${date.getDate()}`,
      count: countByDay.get(key) ?? 0,
      isToday: i === days - 1,
    };
  });
  const seriesMax = Math.max(1, ...series.map((d) => d.count));
  const seriesTotal = series.reduce((sum, d) => sum + d.count, 0);
  const seriesPeak = series.reduce((max, d) => Math.max(max, d.count), 0);
  const seriesAvg = seriesTotal / days;
  const labelStep = days <= 7 ? 1 : days <= 30 ? 5 : 15;
  /* Which days get a tick. Today is always labelled, and it is pinned to the
     right edge — so a scheduled tick that would land within one step of it is
     dropped rather than crowding it into an overlap. A fixed `i % step` rule
     alone put two labels 4px apart on a 390px screen. */
  const lastIdx = series.length - 1;
  const labelIdx: number[] = [];
  for (let i = 0; i <= lastIdx; i += labelStep) {
    if (lastIdx - i >= labelStep) labelIdx.push(i);
  }
  if (labelIdx[labelIdx.length - 1] !== lastIdx) labelIdx.push(lastIdx);
  const xLabels = labelIdx.map((i) => {
    const day = series[i];
    return {
      key: day.key,
      label: day.label,
      isToday: day.isToday,
      pct: (i / Math.max(1, lastIdx)) * 100,
      edge: i === 0 ? "first" : i === lastIdx ? "last" : undefined,
    };
  });

  /* Grade mix over the selected window ------------------------------- */
  const windowStart = todayStart - (days - 1) * DAY_MS;
  const gradeCounts: Record<Grade, number> = { hard: 0, good: 0, easy: 0 };
  let gradeTotal = 0;
  for (const log of data.logs) {
    if (log.at < windowStart) continue;
    gradeCounts[log.grade] += 1;
    gradeTotal += 1;
  }

  const hasReviews = data.logs.length > 0;

  /* Full-page empty state -------------------------------------------- */
  if (total === 0) {
    return (
      <PageShell title={t("stats.title")} subtitle={t("stats.subtitle")}>
        <div className="card card-pad">
          <EmptyState
            icon="words"
            title={t("stats.noData")}
            text={t("stats.emptyHint")}
            action={
              <button type="button" className="btn btn-primary" onClick={() => navigate("words")}>
                {t("stats.addWords")}
              </button>
            }
          />
        </div>
      </PageShell>
    );
  }

  return (
    <PageShell
      title={t("stats.title")}
      subtitle={t("stats.subtitle")}
      actions={
        dueToday > 0 ? (
          <button type="button" className="btn btn-primary" onClick={() => navigate("flashcards")}>
            {t("stats.reviewWithCount", { n: dueToday })}
          </button>
        ) : undefined
      }
    >
      <div className="dash">
        {/* Headline metrics ------------------------------------------- */}
        <div className="dash-tiles">
          <StatTile
            label={t("stats.totalWords")}
            value={total}
            sub={t("stats.listsCount", { n: data.lists.length })}
          />
          <StatTile
            label={t("stats.mastered")}
            value={mastered}
            sub={t("stats.masteryShare", { n: masteryPct })}
          />
          <StatTile
            label={t("stats.reviewsToday")}
            value={today}
            sub={
              reached
                ? t("stats.goalReached")
                : t("stats.remainingToGoal", { n: remaining })
            }
          />
          <StatTile
            label={t("stats.streak")}
            value={streak}
            sub={t("stats.streakUnit")}
          />
        </div>

        {/* Goal + composition ---------------------------------------- */}
        <div className="dash-split wide-left">
          <section className="card">
            <CardHead
              title={t("stats.dailyGoal")}
              sub={t("stats.todayProgress", { n: today, goal })}
            />
            <div className="card-pad">
              <div className="goal-row">
                <Ring value={goalPct} max={1} size={112} stroke={9}>
                  <div>
                    <div className="goal-ring-num">{today}</div>
                    <div className="goal-ring-of">/ {goal}</div>
                  </div>
                </Ring>
                <div className="goal-meta">
                  {reached ? (
                    <span className="goal-done">{t("stats.goalReached")}</span>
                  ) : (
                    <span className="goal-remain">
                      {t("stats.remainingReviews", { n: remaining })}
                    </span>
                  )}
                  <span className="goal-foot">
                    {t("stats.dueToday")} · {dueToday}
                  </span>
                  {overdue > 0 && (
                    <span className="goal-foot is-warn">
                      {t("stats.overdueCount", { n: overdue })}
                    </span>
                  )}
                </div>
              </div>
            </div>
          </section>

          <section className="card">
            <CardHead
              title={t("stats.statusDistribution")}
              sub={t("stats.wordsInTotal", { n: total })}
            />
            <div className="card-pad">
              <div className="dist">
                {STATUS_ORDER.map((status) => {
                  const count = statusCounts[status];
                  const pct = total > 0 ? Math.round((count / total) * 100) : 0;
                  return (
                    <DistRow
                      key={status}
                      name={t(STATUS_LABEL_KEY[status])}
                      count={count}
                      pct={pct}
                      color={STATUS_COLOR[status]}
                    />
                  );
                })}
              </div>
            </div>
          </section>
        </div>

        {/* Activity over time ---------------------------------------- */}
        <section className="card">
          <CardHead
            title={t("stats.reviewsLastDays", { n: days })}
            sub={
              hasReviews
                ? t("stats.windowTotal", { n: days, total: seriesTotal })
                : undefined
            }
            right={
              <Segmented<Range>
                value={range}
                ariaLabel={t("stats.selectRange")}
                options={RANGE_OPTIONS.map((r) => ({
                  value: r.value,
                  label: t("stats.rangeDays", { n: r.days }),
                }))}
                onChange={setRange}
              />
            }
          />
          <div className="card-pad">
            {hasReviews ? (
              <div className="chart">
                <div
                  className={days >= 90 ? "chart-plot dense" : "chart-plot"}
                  role="img"
                  aria-label={
                    t("stats.chartSummary", {
                      days,
                      total: seriesTotal,
                      peak: seriesPeak,
                    })
                  }
                >
                  {series.map((day) => {
                    const barPct =
                      day.count === 0
                        ? 2
                        : Math.max(6, Math.round((day.count / seriesMax) * 100));
                    return (
                      <div
                        className="chart-col"
                        key={day.key}
                        title={`${day.label} ${t("stats.reviewCount", { n: day.count })}`}
                      >
                        <div
                          className={
                            day.count === 0
                              ? "chart-bar is-zero"
                              : day.isToday
                                ? "chart-bar is-today"
                                : "chart-bar"
                          }
                          style={{ transform: `scaleY(${barPct / 100})` }}
                        />
                      </div>
                    );
                  })}
                  <div
                    className="chart-avg"
                    style={{ bottom: `${Math.min(100, (seriesAvg / seriesMax) * 100)}%` }}
                  />
                  <span className="chart-y-max">{seriesPeak}</span>
                </div>
                <div className="chart-x" aria-hidden="true">
                  {xLabels.map((l) => (
                    <span
                      key={l.key}
                      className={[l.edge && `is-${l.edge}`, l.isToday && "is-today"]
                        .filter(Boolean)
                        .join(" ")}
                      style={{ left: `${l.pct}%` }}
                    >
                      {l.label}
                    </span>
                  ))}
                </div>
                <div className="chart-foot">
                  <span>
                    {t("stats.dailyAvg")} <b>{seriesAvg.toFixed(1)}</b>
                  </span>
                  <span>
                    {t("stats.peakDay")} <b>{seriesPeak}</b>
                  </span>
                  <span>
                    {t("stats.allReviews")} <b>{data.logs.length}</b>
                  </span>
                </div>
              </div>
            ) : (
              <div className="dash-empty">
                <EmptyState
                  icon="cards"
                  title={t("stats.noReviews")}
                  text={t("stats.noReviewsHint")}
                  action={
                    <button
                      type="button"
                      className="btn btn-primary"
                      onClick={() => navigate("flashcards")}
                    >
                      {t("stats.startReviewing")}
                    </button>
                  }
                />
              </div>
            )}
          </div>
        </section>

        {/* Quality: grades + retention ------------------------------- */}
        <div className="dash-split">
          <section className="card">
            <CardHead
              title={t("stats.gradeMix")}
              sub={t("stats.lastDays", { n: days })}
            />
            <div className="card-pad">
              {gradeTotal > 0 ? (
                <div className="dist">
                  {GRADES.map((g) => {
                    const count = gradeCounts[g.grade];
                    const pct = gradeTotal > 0 ? Math.round((count / gradeTotal) * 100) : 0;
                    return (
                      <DistRow
                        key={g.grade}
                        name={t(g.labelKey)}
                        count={count}
                        pct={pct}
                        color={g.color}
                      />
                    );
                  })}
                </div>
              ) : (
                <div className="dash-empty">
                  <EmptyState
                    icon="quiz"
                    title={t("stats.noGrades")}
                    text={t("stats.noGradesHint")}
                  />
                </div>
              )}
            </div>
          </section>

          <section className="card">
            <CardHead
              title={t("stats.retention")}
              sub={t("stats.retentionSub")}
            />
            <div className="card-pad">
              <div className="metric-line" style={{ marginBottom: "var(--sp-3)" }}>
                <span className={retention === null ? "metric-big is-empty" : "metric-big"}>
                  {retention === null ? "—" : `${retention}%`}
                </span>
                <span className="tiny muted">
                  {retention === null
                    ? t("stats.notEnoughData")
                    : t("stats.retentionDetail", {
                        reviews: reviewSum,
                        correct: correctSum,
                      })}
                </span>
              </div>
              <div className="kv">
                <KvRow
                  label={t("stats.overdueWords")}
                  value={overdue}
                  warn={overdue > 0}
                />
                <KvRow
                  label={t("stats.reviewedWords")}
                  value={`${reviewedWords} / ${total}`}
                />
                <KvRow
                  label={t("stats.dueToday")}
                  value={dueToday}
                />
                <KvRow
                  label={t("stats.avgInterval")}
                  value={scheduled > 0 ? formatInterval(Math.round(avgInterval)) : "—"}
                />
              </div>
            </div>
          </section>
        </div>
      </div>
    </PageShell>
  );
}
