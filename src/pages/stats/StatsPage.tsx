import { useState, type ReactNode } from "react";
import { EmptyState, PageShell, Ring, Segmented, StatTile } from "@/components/ui";
import { useRouter } from "@/app/router";
import { useLang, useT } from "@/i18n";
import { dueWords, reviewsToday, streakDays, useAppData } from "@/lib/store";
import { DAY_MS, formatInterval } from "@/lib/srs";
import { STATUS_LABEL_KEY, STATUS_ORDER, type Grade, type WordStatus } from "@/lib/types";
import { dayKey, startOfDay } from "@/lib/utils";
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

const STATUS_COLOR: Record<WordStatus, string> = {
  new: "var(--ink-4)",
  reviewing: "var(--sky)",
  learning: "var(--amber)",
  mastered: "var(--jade)",
};

const GRADES: Array<{ grade: Grade; labelKey: string; color: string }> = [
  { grade: "hard", labelKey: "flashcards.gradeHard", color: "var(--rose)" },
  { grade: "good", labelKey: "flashcards.gradeGood", color: "var(--sky)" },
  { grade: "easy", labelKey: "flashcards.gradeEasy", color: "var(--jade)" },
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
        <span className="dist-swatch" style={{ background: color }} aria-hidden="true" />
        <span className="dist-name">{name}</span>
        <span className="dist-num">
          {count} · {pct}%
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
        <div className="progress-fill" style={{ width: `${pct}%`, background: color }} />
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
  const lang = useLang();
  const { navigate } = useRouter();
  const data = useAppData();
  const [range, setRange] = useState<Range>("30");

  const now = Date.now();
  const days = range === "7" ? 7 : range === "30" ? 30 : 90;
  const zh = lang === "zh-CN";

  const words = data.words;
  const total = words.length;

  /* Headline numbers ------------------------------------------------- */
  const statusCounts: Record<WordStatus, number> = {
    new: 0,
    reviewing: 0,
    learning: 0,
    mastered: 0,
  };
  let reviewSum = 0;
  let correctSum = 0;
  let reviewedWords = 0;
  let intervalSum = 0;
  let scheduled = 0;
  let overdue = 0;
  const todayStart = startOfDay(now);
  const dueToday = dueWords(data, now).length;

  for (const w of words) {
    statusCounts[w.status] += 1;
    const srs = w.srs;
    if (srs) {
      if (w.status !== "mastered" && srs.dueAt < todayStart) overdue += 1;
      if (srs.reviewCount > 0) {
        reviewedWords += 1;
        reviewSum += srs.reviewCount;
        correctSum += srs.correctCount;
        intervalSum += srs.intervalDays;
        scheduled += 1;
      }
    }
  }

  const mastered = statusCounts.mastered;
  const today = reviewsToday(data, now);
  const streak = streakDays(data, now);
  const goal = Math.max(1, data.settings.dailyGoal);
  const goalPct = Math.min(1, today / goal);
  const reached = today >= goal;
  const remaining = Math.max(0, goal - today);
  const masteryPct = total > 0 ? Math.round((mastered / total) * 100) : 0;
  const retention = reviewSum > 0 ? Math.round((correctSum / reviewSum) * 100) : null;
  const avgInterval = scheduled > 0 ? intervalSum / scheduled : 0;

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
            text={
              zh
                ? "先添加几个词语，统计会随着你的学习慢慢长出形状。"
                : "Add a few words first — your stats will take shape as you study."
            }
            action={
              <button type="button" className="btn btn-primary" onClick={() => navigate("words")}>
                {zh ? "添加词语" : "Add words"}
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
            {zh ? `开始复习 · ${dueToday}` : `Review · ${dueToday}`}
          </button>
        ) : undefined
      }
    >
      <div className="dash">
        {/* Headline metrics ------------------------------------------- */}
        <div className="dash-tiles">
          <StatTile
            icon="words"
            label={t("stats.totalWords")}
            value={total}
            sub={zh ? `${data.lists.length} 个词库` : `${data.lists.length} lists`}
          />
          <StatTile
            icon="check"
            label={t("stats.mastered")}
            value={mastered}
            accent="var(--jade)"
            sub={zh ? `占全部 ${masteryPct}%` : `${masteryPct}% of all words`}
          />
          <StatTile
            icon="cards"
            label={t("stats.reviewsToday")}
            value={today}
            sub={
              reached
                ? t("stats.goalReached")
                : zh
                  ? `还差 ${remaining} 次到目标`
                  : `${remaining} to go today`
            }
          />
          <StatTile
            icon="flame"
            label={t("stats.streak")}
            value={streak}
            accent={streak > 0 ? "var(--amber)" : undefined}
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
                      {zh ? `还差 ${remaining} 次复习` : `${remaining} reviews to go`}
                    </span>
                  )}
                  <span className="goal-foot">
                    {t("stats.dueToday")} · {dueToday}
                  </span>
                  {overdue > 0 && (
                    <span className="goal-foot is-warn">
                      {zh ? `逾期 ${overdue} 个词语` : `${overdue} overdue`}
                    </span>
                  )}
                </div>
              </div>
            </div>
          </section>

          <section className="card">
            <CardHead
              title={t("stats.statusDistribution")}
              sub={zh ? `共 ${total} 个词语` : `${total} words in total`}
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
            title={zh ? `近 ${days} 天复习` : `Reviews · last ${days} days`}
            sub={
              hasReviews
                ? zh
                  ? `累计 ${seriesTotal} 次`
                  : `${seriesTotal} reviews`
                : undefined
            }
            right={
              <Segmented<Range>
                value={range}
                ariaLabel={zh ? "选择统计区间" : "Select range"}
                options={RANGE_OPTIONS.map((r) => ({
                  value: r.value,
                  label: zh ? `${r.days} 天` : `${r.days}d`,
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
                    zh
                      ? `近 ${days} 天共复习 ${seriesTotal} 次，最高一天 ${seriesPeak} 次`
                      : `${seriesTotal} reviews in the last ${days} days, peak ${seriesPeak}`
                  }
                >
                  {series.map((day) => (
                    <div
                      className="chart-col"
                      key={day.key}
                      title={`${day.label} · ${day.count} ${zh ? "次" : "reviews"}`}
                    >
                      <div
                        className={
                          day.count === 0
                            ? "chart-bar is-zero"
                            : day.isToday
                              ? "chart-bar is-today"
                              : "chart-bar"
                        }
                        style={{
                          height: `${
                            day.count === 0
                              ? 2
                              : Math.max(6, Math.round((day.count / seriesMax) * 100))
                          }%`,
                        }}
                      />
                    </div>
                  ))}
                </div>
                <div className="chart-x" aria-hidden="true">
                  {series.map((day, i) => (
                    <span key={day.key} className={day.isToday ? "is-today" : undefined}>
                      {i % labelStep === 0 || i === series.length - 1 ? day.label : ""}
                    </span>
                  ))}
                </div>
                <div className="chart-foot">
                  <span>
                    {zh ? "日均" : "Daily avg"} <b>{seriesAvg.toFixed(1)}</b>
                  </span>
                  <span>
                    {zh ? "单日最高" : "Peak"} <b>{seriesPeak}</b>
                  </span>
                  <span>
                    {t("stats.totalReviews")} <b>{data.logs.length}</b>
                  </span>
                </div>
              </div>
            ) : (
              <div className="dash-empty">
                <EmptyState
                  icon="cards"
                  title={zh ? "还没有复习记录" : "No reviews yet"}
                  text={
                    zh
                      ? "完成第一次闪卡复习后，这里会显示你每天积累的复习量。"
                      : "Finish your first flashcard session and your daily volume will appear here."
                  }
                  action={
                    <button
                      type="button"
                      className="btn btn-primary"
                      onClick={() => navigate("flashcards")}
                    >
                      {zh ? "去复习" : "Start reviewing"}
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
              title={zh ? "评分分布" : "Grade mix"}
              sub={zh ? `近 ${days} 天` : `last ${days} days`}
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
                    title={zh ? "暂无评分数据" : "No grades yet"}
                    text={
                      zh
                        ? "复习时用「困难 / 记得 / 简单」评分，这里会显示你的记忆质量。"
                        : "Grade cards as hard / good / easy and your recall quality shows up here."
                    }
                  />
                </div>
              )}
            </div>
          </section>

          <section className="card">
            <CardHead
              title={zh ? "记忆留存率" : "Retention"}
              sub={zh ? "答对次数 / 复习次数" : "correct / total reviews"}
            />
            <div className="card-pad">
              <div className="metric-line" style={{ marginBottom: "var(--sp-3)" }}>
                <span className={retention === null ? "metric-big is-empty" : "metric-big"}>
                  {retention === null ? "—" : `${retention}%`}
                </span>
                <span className="tiny muted">
                  {retention === null
                    ? zh
                      ? "还没有可计算的复习"
                      : "not enough data yet"
                    : zh
                      ? `${reviewSum} 次复习 · ${correctSum} 次答对`
                      : `${reviewSum} reviews · ${correctSum} correct`}
                </span>
              </div>
              <div className="kv">
                <KvRow
                  label={zh ? "逾期词语" : "Overdue words"}
                  value={overdue}
                  warn={overdue > 0}
                />
                <KvRow
                  label={zh ? "已复习词语" : "Words reviewed"}
                  value={`${reviewedWords} / ${total}`}
                />
                <KvRow
                  label={zh ? "今日待复习" : "Due today"}
                  value={dueToday}
                />
                <KvRow
                  label={zh ? "平均复习间隔" : "Avg. interval"}
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
