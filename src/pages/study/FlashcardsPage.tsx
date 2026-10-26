/**
 * 闪卡复习页：到期 + 新词会话队列、翻面、三档评分（显示下次间隔）、
 * 键盘 1/2/3 + 空格、自动 / 手动发音，以及结束小结。
 */
import { useCallback, useEffect, useRef, useState } from "react";
import { EmptyState, PageShell, ProgressBar, Ring, StatusChip, TagChip } from "@/components/ui";
import { Icon } from "@/components/Icon";
import { useT } from "@/i18n";
import { useRouter } from "@/app/router";
import {
  bumpListen,
  dueWords,
  getData,
  gradeWord,
  reviewsToday,
  useAppData,
} from "@/lib/store";
import { formatInterval, isNew, previewIntervals } from "@/lib/srs";
import { speak, speechSupported, stopSpeaking } from "@/lib/tts";
import { shuffle, startOfDay } from "@/lib/utils";
import { STATUS_LABEL_KEY, type AppData, type Grade, type Word } from "@/lib/types";

interface SessionState {
  ids: string[];
  index: number;
  reviewed: number;
  correct: number;
}

const GRADES: Grade[] = ["hard", "good", "easy"];

const GRADE_ACCENT: Record<Grade, string> = {
  hard: "var(--amber)",
  good: "var(--jade)",
  easy: "var(--sky)",
};

/**
 * 今日还能引入多少张新卡：newCardsPerDay 是每日额度，
 * 需要扣掉今天已经完成首次复习（reviewCount === 1 且 lastReviewedAt 在今天）的词。
 */
function newCardsLeft(data: AppData, now: number): number {
  const today = startOfDay(now);
  const usedToday = data.words.filter(
    (w) =>
      w.srs !== null &&
      w.srs.reviewCount === 1 &&
      w.srs.lastReviewedAt !== null &&
      w.srs.lastReviewedAt >= today,
  ).length;
  return Math.max(0, data.settings.newCardsPerDay - usedToday);
}

/**
 * 会话队列：到期词 + 受每日新卡额度限制的新词；
 * 到期顺序按 dueAt 升序（新词排在到期词之后），随机模式整体打乱。
 */
function buildSession(data: AppData, now: number): string[] {
  const due = dueWords(data, now);
  const freshLimit = newCardsLeft(data, now);
  const fresh = due.filter((w) => isNew(w.srs)).slice(0, freshLimit);
  const review = due.filter((w) => !isNew(w.srs));
  const queue = [...review, ...fresh];
  const ordered =
    data.settings.reviewOrder === "random"
      ? shuffle(queue)
      : queue
          .slice()
          .sort(
            (a, b) =>
              (a.srs?.dueAt ?? Number.MAX_SAFE_INTEGER) -
              (b.srs?.dueAt ?? Number.MAX_SAFE_INTEGER),
          );
  return ordered.map((w) => w.id);
}

export function FlashcardsPage() {
  const t = useT();
  const { navigate } = useRouter();
  const data = useAppData();
  const settings = data.settings;

  const [session, setSession] = useState<SessionState | null>(null);
  const [flipped, setFlipped] = useState(false);
  // 记录已自动朗读过的卡片，避免 StrictMode 下 effect 双跑导致重复发音。
  const spokenRef = useRef<string | null>(null);

  const now = Date.now();
  const due = dueWords(data, now);
  const freshBudget = newCardsLeft(data, now);
  const fresh = due.filter((w) => isNew(w.srs)).slice(0, freshBudget);
  const review = due.filter((w) => !isNew(w.srs));
  const queueSize = review.length + fresh.length;

  const mode: "idle" | "active" | "done" = !session
    ? "idle"
    : session.index >= session.ids.length
      ? "done"
      : "active";
  const step = session?.index ?? 0;
  const total = session?.ids.length ?? 0;
  const currentId = mode === "active" && session ? session.ids[step] : null;
  const word = currentId ? data.words.find((w) => w.id === currentId) : undefined;
  const newCard = word ? isNew(word.srs) : false;
  const preview = word ? previewIntervals(word.srs) : null;
  const canSpeak = speechSupported();
  const accuracy = session && session.reviewed > 0 ? session.correct / session.reviewed : 0;
  // 结束后是否还有下一组可复习（避免点「再来一组」落进空状态）。
  const nextRoundSize = mode === "done" ? buildSession(data, now).length : 0;

  const startSession = useCallback(() => {
    const ids = buildSession(getData(), Date.now());
    setFlipped(false);
    spokenRef.current = null;
    if (ids.length === 0) {
      setSession(null);
      return;
    }
    setSession({ ids, index: 0, reviewed: 0, correct: 0 });
  }, []);

  const grade = useCallback(
    (value: Grade) => {
      if (!session || !word) return;
      const result = gradeWord(word.id, value);
      if (!result) return;
      setSession((prev) =>
        prev
          ? {
              ...prev,
              index: prev.index + 1,
              reviewed: prev.reviewed + 1,
              correct: prev.correct + (value === "hard" ? 0 : 1),
            }
          : prev,
      );
      setFlipped(false);
    },
    [session, word],
  );

  const play = (target: Word) => {
    speak(target.term, {
      lang: target.sourceLang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI,
    });
    bumpListen(target.id);
  };

  // 每张新卡出现时按设置自动朗读。
  useEffect(() => {
    if (!word || !settings.autoPlayAudio) return;
    if (!speechSupported()) return;
    const token = `${word.id}:${step}`;
    if (spokenRef.current === token) return;
    spokenRef.current = token;
    speak(word.term, {
      lang: word.sourceLang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI,
    });
  }, [word, step, settings.autoPlayAudio, settings.ttsRate, settings.ttsVoiceURI]);

  useEffect(() => () => stopSpeaking(), []);

  // 键盘：空格翻面，1 / 2 / 3 评分。
  useEffect(() => {
    if (mode !== "active") return;
    const onKey = (event: KeyboardEvent) => {
      const target = event.target as HTMLElement | null;
      if (
        target &&
        (target.tagName === "INPUT" ||
          target.tagName === "TEXTAREA" ||
          target.isContentEditable)
      ) {
        return;
      }
      if (event.code === "Space" || event.key === " ") {
        event.preventDefault();
        if (!flipped) setFlipped(true);
        return;
      }
      if (!flipped) return;
      if (event.key === "1") {
        event.preventDefault();
        grade("hard");
      } else if (event.key === "2") {
        event.preventDefault();
        grade("good");
      } else if (event.key === "3") {
        event.preventDefault();
        grade("easy");
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [mode, flipped, grade]);

  return (
    <PageShell title={t("flashcards.title")} subtitle={t("flashcards.subtitle")}>
      {mode === "idle" && queueSize === 0 && (
        <EmptyState
          icon="cards"
          title={t("flashcards.noCards")}
          text={t("flashcards.noCardsHint")}
          action={
            <button className="btn btn-primary" type="button" onClick={() => navigate("words")}>
              <Icon name="plus" size={16} />
              去词库添加词语
            </button>
          }
        />
      )}

      {mode === "idle" && queueSize > 0 && (
        <div
          className="card rise"
          style={{
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: 18,
            padding: "clamp(32px, 6vw, 56px) 24px",
            textAlign: "center",
          }}
        >
          <div
            style={{
              width: 64,
              height: 64,
              borderRadius: "50%",
              background: "var(--jade-soft)",
              color: "var(--jade-ink)",
              display: "grid",
              placeItems: "center",
            }}
          >
            <Icon name="cards" size={28} />
          </div>
          <div
            style={{
              fontFamily: "var(--font-display)",
              fontSize: 28,
              fontWeight: 600,
              letterSpacing: "-0.01em",
            }}
          >
            {t("flashcards.start")}
          </div>
          <p className="muted" style={{ maxWidth: 420 }}>
            {t("flashcards.deckSize", { n: queueSize })}
          </p>
          <div className="row-flex" style={{ gap: 8, flexWrap: "wrap", justifyContent: "center" }}>
            <span className="chip chip-reviewing">
              {t("flashcards.dueCount", { n: review.length })}
            </span>
            <span className="chip chip-learning">
              {t("flashcards.newCount", { n: fresh.length })}
            </span>
          </div>
          <button
            className="btn btn-primary btn-lg"
            type="button"
            onClick={startSession}
            style={{ minWidth: 200 }}
          >
            {t("flashcards.start")}
          </button>
          <div className="row-flex" style={{ gap: 12, flexWrap: "wrap", justifyContent: "center" }}>
            <span className="tiny muted">
              <span className="kbd">空格</span> {t("flashcards.showAnswer")}
            </span>
            <span className="tiny muted">
              <span className="kbd">1</span> {t("flashcards.gradeHard")}
            </span>
            <span className="tiny muted">
              <span className="kbd">2</span> {t("flashcards.gradeGood")}
            </span>
            <span className="tiny muted">
              <span className="kbd">3</span> {t("flashcards.gradeEasy")}
            </span>
          </div>
        </div>
      )}

      {mode === "active" && !word && (
        <EmptyState
          icon="cards"
          title={t("flashcards.emptyDeck")}
          text={t("flashcards.emptyDeckHint")}
        />
      )}

      {mode === "active" && word && (
        <div className="stack" style={{ gap: 14 }}>
          <div className="row-flex" style={{ gap: 10 }}>
            <span className="tiny muted mono">
              {t("flashcards.cardOf", { i: step + 1, n: total })}
            </span>
            <div className="spacer" />
            <StatusChip status={word.status} label={t(STATUS_LABEL_KEY[word.status])} />
          </div>
          <ProgressBar value={step} max={total || 1} />

          <div
            key={word.id}
            className="card rise"
            role="button"
            tabIndex={0}
            aria-label={flipped ? word.term : t("flashcards.showAnswer")}
            onClick={() => {
              if (!flipped) setFlipped(true);
            }}
            onKeyDown={(event) => {
              if ((event.key === "Enter" || event.key === " ") && !flipped) {
                event.preventDefault();
                setFlipped(true);
              }
            }}
            style={{
              position: "relative",
              minHeight: 360,
              maxHeight: "56vh",
              overflowY: "auto",
              padding: "clamp(28px, 5vw, 48px)",
              display: "flex",
              flexDirection: "column",
              alignItems: "center",
              justifyContent: flipped ? "flex-start" : "center",
              gap: 20,
              cursor: flipped ? "default" : "pointer",
            }}
          >
            <div
              className="tiny"
              style={{
                position: "absolute",
                top: 14,
                left: 16,
                color: "var(--ink-4)",
                letterSpacing: "0.12em",
                textTransform: "uppercase",
                pointerEvents: "none",
              }}
            >
              {flipped ? t("flashcards.back") : t("flashcards.front")}
            </div>

            {canSpeak && (
              <button
                type="button"
                className="btn btn-icon btn-ghost"
                style={{ position: "absolute", top: 10, right: 10, zIndex: 1 }}
                aria-label={`播放 ${word.term}`}
                onClick={(event) => {
                  event.stopPropagation();
                  play(word);
                }}
              >
                <Icon name="volume" size={17} />
              </button>
            )}

            {!flipped ? (
              <div
                style={{
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 16,
                  textAlign: "center",
                }}
              >
                <div
                  style={{
                    fontFamily: "var(--font-display)",
                    fontSize: "clamp(38px, 6vw, 60px)",
                    lineHeight: 1.08,
                    letterSpacing: "-0.02em",
                    wordBreak: "break-word",
                  }}
                >
                  {word.term}
                </div>
                <div className="tiny muted">
                  {t("flashcards.revealHint")} · <span className="kbd">空格</span>
                </div>
              </div>
            ) : (
              <div
                style={{
                  width: "100%",
                  maxWidth: 560,
                  margin: "0 auto",
                  paddingTop: 6,
                  display: "flex",
                  flexDirection: "column",
                  gap: 16,
                  textAlign: "left",
                }}
              >
                <div>
                  <div
                    className="tiny muted"
                    style={{
                      letterSpacing: "0.1em",
                      textTransform: "uppercase",
                      marginBottom: 6,
                    }}
                  >
                    {t("common.definition")}
                  </div>
                  <div style={{ fontFamily: "var(--font-display)", fontSize: 22, lineHeight: 1.55 }}>
                    {word.definition || t("words.noDefinition")}
                  </div>
                </div>

                {word.definition2 && (
                  <div style={{ fontSize: 14.5, lineHeight: 1.65, color: "var(--ink-2)" }}>
                    {word.definition2}
                  </div>
                )}

                {word.example && (
                  <div
                    style={{
                      borderLeft: "2px solid var(--line-strong)",
                      paddingLeft: 12,
                      fontSize: 14.5,
                      lineHeight: 1.65,
                      color: "var(--ink-2)",
                      fontStyle: "italic",
                    }}
                  >
                    {word.example}
                  </div>
                )}

                {word.note && (
                  <div
                    style={{
                      display: "flex",
                      alignItems: "flex-start",
                      gap: 8,
                      padding: "10px 12px",
                      borderRadius: "var(--r-sm)",
                      background: "var(--surface-2)",
                      color: "var(--ink-2)",
                      fontSize: 13,
                    }}
                  >
                    <span
                      style={{
                        display: "grid",
                        placeItems: "center",
                        marginTop: 1,
                        color: "var(--ink-3)",
                      }}
                    >
                      <Icon name="info" size={14} />
                    </span>
                    <span>{word.note}</span>
                  </div>
                )}

                {word.tags.length > 0 && (
                  <div className="row-flex wrap" style={{ gap: 6 }}>
                    {word.tags.map((tag) => (
                      <TagChip key={tag} tag={tag} />
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>

          <div style={{ minHeight: 112, display: "flex", flexDirection: "column", gap: 10 }}>
            {!flipped ? (
              <button
                className="btn btn-lg"
                type="button"
                style={{ alignSelf: "center", minWidth: 220 }}
                onClick={() => setFlipped(true)}
              >
                {t("flashcards.showAnswer")}
                <span className="kbd">空格</span>
              </button>
            ) : (
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "repeat(3, minmax(0, 1fr))",
                  gap: 10,
                }}
              >
                {GRADES.map((value, i) => {
                  const label =
                    value === "hard"
                      ? t("flashcards.gradeHard")
                      : value === "good"
                        ? t("flashcards.gradeGood")
                        : t("flashcards.gradeEasy");
                  return (
                    <button
                      key={value}
                      className="btn"
                      type="button"
                      onClick={() => grade(value)}
                      style={{
                        height: "auto",
                        padding: "9px 10px",
                        flexDirection: "column",
                        gap: 1,
                      }}
                    >
                      <span
                        style={{
                          display: "flex",
                          alignItems: "center",
                          gap: 6,
                          fontSize: 13.5,
                          fontWeight: 560,
                          color: GRADE_ACCENT[value],
                        }}
                      >
                        <span className="kbd" style={{ fontSize: 10 }}>
                          {i + 1}
                        </span>
                        {label}
                      </span>
                      <span className="tiny muted mono">
                        {preview
                          ? `${newCard ? "首次 · " : ""}${formatInterval(preview[value])}`
                          : "—"}
                      </span>
                    </button>
                  );
                })}
              </div>
            )}
            <div className="row-flex" style={{ justifyContent: "center", gap: 12, flexWrap: "wrap" }}>
              <span className="tiny muted">
                <span className="kbd">空格</span> {t("flashcards.showAnswer")}
              </span>
              <span className="tiny muted">
                <span className="kbd">1</span> {t("flashcards.gradeHard")}
              </span>
              <span className="tiny muted">
                <span className="kbd">2</span> {t("flashcards.gradeGood")}
              </span>
              <span className="tiny muted">
                <span className="kbd">3</span> {t("flashcards.gradeEasy")}
              </span>
            </div>
          </div>
        </div>
      )}

      {mode === "done" && session && (
        <div
          className="card rise"
          style={{
            display: "flex",
            flexDirection: "column",
            alignItems: "center",
            gap: 20,
            padding: "clamp(28px, 5vw, 44px)",
            textAlign: "center",
          }}
        >
          <div
            style={{
              width: 60,
              height: 60,
              borderRadius: "50%",
              background: "var(--jade-soft)",
              color: "var(--jade-ink)",
              display: "grid",
              placeItems: "center",
            }}
          >
            <Icon name="sparkles" size={26} />
          </div>
          <div>
            <div style={{ fontFamily: "var(--font-display)", fontSize: 26, fontWeight: 600 }}>
              {t("flashcards.sessionDone")}
            </div>
            <p className="muted" style={{ marginTop: 6 }}>
              {t("flashcards.sessionDoneText", { n: session.reviewed })}
            </p>
          </div>

          <Ring value={session.correct} max={Math.max(1, session.reviewed)} size={124} stroke={9}>
            <div>
              <div
                style={{
                  fontFamily: "var(--font-display)",
                  fontSize: 30,
                  fontWeight: 600,
                  lineHeight: 1,
                }}
              >
                {Math.round(accuracy * 100)}%
              </div>
              <div className="tiny muted">{t("flashcards.accuracy")}</div>
            </div>
          </Ring>

          <div className="row-flex" style={{ gap: 36, justifyContent: "center", flexWrap: "wrap" }}>
            <div>
              <div style={{ fontFamily: "var(--font-display)", fontSize: 24, fontWeight: 600 }}>
                {session.reviewed}
              </div>
              <div className="tiny muted">{t("flashcards.reviewedCount")}</div>
            </div>
            <div>
              <div style={{ fontFamily: "var(--font-display)", fontSize: 24, fontWeight: 600 }}>
                {reviewsToday(data)}
              </div>
              <div className="tiny muted">{t("stats.reviewsToday")}</div>
            </div>
          </div>

          <button
            className="btn btn-primary btn-lg"
            type="button"
            onClick={startSession}
            disabled={nextRoundSize === 0}
          >
            <Icon name="refresh" size={16} />
            {t("flashcards.nextSession")}
          </button>
          {nextRoundSize === 0 && (
            <div className="tiny muted">暂时没有可复习的卡片了，明天再来吧</div>
          )}
        </div>
      )}
    </PageShell>
  );
}
