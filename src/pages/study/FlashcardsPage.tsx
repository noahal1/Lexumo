import { useCallback, useEffect, useRef, useState } from "react";

import { Icon } from "@/components/Icon";
import {
  EmptyState,
  PageShell,
  ProgressBar,
  Ring,
  ShortcutRow,
  StatTile,
  StatusChip,
  TagChip,
} from "@/components/ui";
import { useRouter } from "@/app/router";
import { useT } from "@/i18n";
import { formatInterval, isNew, previewIntervals } from "@/lib/srs";
import { bumpListen, dueWords, getData, gradeWord, reviewsToday, useAppData } from "@/lib/store";
import { speak, speechSupported, stopSpeaking } from "@/lib/tts";
import { STATUS_LABEL_KEY, type AppData, type Grade, type Word } from "@/lib/types";
import { cx, shuffle, startOfDay } from "@/lib/utils";
import "@/styles/study.css";

const GRADES: Grade[] = ["hard", "good", "easy"];

const GRADE_LABEL_KEY: Record<Grade, string> = {
  hard: "flashcards.gradeHard",
  good: "flashcards.gradeGood",
  easy: "flashcards.gradeEasy",
};

interface SessionState {
  ids: string[];
  index: number;
  reviewed: number;
  correct: number;
  skipped: number;
}

/** How many brand-new cards the daily allowance still has room for. */
function newCardsLeft(data: AppData, now: number): number {
  const start = startOfDay(now);
  const introduced = data.words.filter((word) => {
    const srs = word.srs;
    if (!srs) return false;
    return (
      srs.reviewCount === 1 &&
      srs.lastReviewedAt !== null &&
      srs.lastReviewedAt >= start
    );
  }).length;
  return Math.max(0, data.settings.newCardsPerDay - introduced);
}

/** Due reviews first, then up to `newCardsPerDay` fresh cards. */
function buildSession(data: AppData, now: number): string[] {
  const due = dueWords(data, now);
  const review = due.filter((word) => !isNew(word.srs));
  const fresh = due.filter((word) => isNew(word.srs)).slice(0, newCardsLeft(data, now));

  if (data.settings.reviewOrder === "random") {
    return shuffle([...review, ...fresh]).map((word) => word.id);
  }

  const ordered = [...review].sort(
    (a, b) => (a.srs?.dueAt ?? Number.MAX_SAFE_INTEGER) - (b.srs?.dueAt ?? Number.MAX_SAFE_INTEGER),
  );
  return [...ordered, ...fresh].map((word) => word.id);
}

export function FlashcardsPage() {
  const data = useAppData();
  const settings = data.settings;
  const t = useT();
  const router = useRouter();

  const [session, setSession] = useState<SessionState | null>(null);
  const [flipped, setFlipped] = useState(false);
  const spokenRef = useRef<string | null>(null);

  const canSpeak = speechSupported();
  const due = dueWords(data);
  const dueReviewCount = due.filter((word) => !isNew(word.srs)).length;
  const freshLeft = newCardsLeft(data, Date.now());
  const queueSize = buildSession(data, Date.now()).length;
  const nextRoundSize = buildSession(data, Date.now()).length;

  const inProgress = session !== null && session.index < session.ids.length;
  const currentId = inProgress ? session.ids[session.index] : null;
  const word: Word | null = currentId
    ? data.words.find((candidate) => candidate.id === currentId) ?? null
    : null;
  const newCard = word ? isNew(word.srs) : false;
  const preview = word ? previewIntervals(word.srs) : null;
  const accuracy =
    session && session.reviewed > 0 ? session.correct / session.reviewed : 0;

  const play = useCallback(
    (target: Word) => {
      speak(target.term, {
        lang: target.sourceLang,
        rate: settings.ttsRate,
        voiceURI: settings.ttsVoiceURI,
      });
      bumpListen(target.id);
    },
    [settings.ttsRate, settings.ttsVoiceURI],
  );

  const startSession = useCallback(() => {
    const ids = buildSession(getData(), Date.now());
    setFlipped(false);
    spokenRef.current = null;
    setSession(
      ids.length > 0
        ? { ids, index: 0, reviewed: 0, correct: 0, skipped: 0 }
        : null,
    );
  }, []);

  const grade = useCallback(
    (value: Grade) => {
      if (!word) return;
      gradeWord(word.id, value);
      setFlipped(false);
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
    },
    [word],
  );

  const skip = useCallback(() => {
    setFlipped(false);
    setSession((prev) =>
      prev ? { ...prev, index: prev.index + 1, skipped: prev.skipped + 1 } : prev,
    );
  }, []);

  /* Auto-pronounce the term once per card (token guards StrictMode double-run). */
  useEffect(() => {
    if (!word || !inProgress) return;
    if (!settings.autoPlayAudio || !speechSupported()) return;
    const token = `${word.id}:${session?.index ?? 0}`;
    if (spokenRef.current === token) return;
    spokenRef.current = token;
    speak(word.term, {
      lang: word.sourceLang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI,
    });
  }, [
    word,
    inProgress,
    session?.index,
    settings.autoPlayAudio,
    settings.ttsRate,
    settings.ttsVoiceURI,
  ]);

  useEffect(() => () => stopSpeaking(), []);

  /* Space flips · 1/2/3 grade · ←/→ skip */
  useEffect(() => {
    if (!inProgress) return;
    const onKeyDown = (event: KeyboardEvent) => {
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

      if (event.key === "ArrowLeft" || event.key === "ArrowRight") {
        event.preventDefault();
        skip();
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
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [inProgress, flipped, grade, skip]);

  const sidePanel = (
    <aside className="study-side">
      <StatTile
        label={t("stats.reviewsToday")}
        value={reviewsToday(data)}
        sub={`${t("stats.dailyGoal")} ${settings.dailyGoal}`}
        icon="flame"
      />
      <div className="card card-pad stack">
        <div className="card-title">{t("settings.shortcuts")}</div>
        <div className="shortcuts">
          <ShortcutRow keys={["空格"]} label={t("settings.shortcutFlip")} />
          <ShortcutRow keys={["1"]} label={t("flashcards.gradeHard")} />
          <ShortcutRow keys={["2"]} label={t("flashcards.gradeGood")} />
          <ShortcutRow keys={["3"]} label={t("flashcards.gradeEasy")} />
          <ShortcutRow keys={["←", "→"]} label="跳过当前卡" />
        </div>
      </div>
    </aside>
  );

  return (
    <PageShell title={t("flashcards.title")} subtitle={t("flashcards.subtitle")}>
      {!session ? (
        queueSize === 0 ? (
          <div className="card">
            <EmptyState
              icon="cards"
              title={data.words.length === 0 ? t("words.noWords") : t("flashcards.noCards")}
              text={
                data.words.length === 0
                  ? t("words.noWordsHint")
                  : t("flashcards.noCardsHint")
              }
              action={
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() => router.navigate("words")}
                >
                  <Icon name="plus" size={16} />
                  {data.words.length === 0 ? t("words.addFirst") : t("words.addWord")}
                </button>
              }
            />
          </div>
        ) : (
          <div className="study-split">
            <div className="study-main">
              <div className="card fc-intro rise">
                <div className="fc-intro-ico">
                  <Icon name="cards" size={26} />
                </div>
                <div className="stack">
                  <h2 className="fc-intro-title">{t("flashcards.start")}</h2>
                  <p className="fc-intro-text">{t("flashcards.subtitle")}</p>
                </div>
                <div className="row-flex wrap">
                  <span className="chip chip-learning">
                    {t("flashcards.dueCount", { n: dueReviewCount })}
                  </span>
                  <span className="chip chip-new">
                    {t("flashcards.newCount", { n: freshLeft })}
                  </span>
                  <span className="chip chip-tag">
                    {t("flashcards.deckSize", { n: queueSize })}
                  </span>
                </div>
                <div className="study-actions">
                  <button
                    type="button"
                    className="btn btn-primary btn-lg"
                    onClick={startSession}
                  >
                    {t("flashcards.start")}
                    <Icon name="arrow-right" size={17} />
                  </button>
                </div>
                <p className="tiny muted">{t("flashcards.keyboardHint")}</p>
              </div>
            </div>
            {sidePanel}
          </div>
        )
      ) : inProgress ? (
        <div className="study-split">
          <div className="study-main">
            <div className="study-bar">
              <div className="study-bar-row">
                <span className="study-bar-label mono">
                  {t("flashcards.cardOf", {
                    i: session.index + 1,
                    n: session.ids.length,
                  })}
                </span>
                {word && (
                  <StatusChip
                    status={word.status}
                    label={t(STATUS_LABEL_KEY[word.status])}
                  />
                )}
                <span className="spacer" />
                <span className="study-bar-meta">
                  <span>
                    {t("flashcards.reviewedCount")} {session.reviewed}
                  </span>
                  {session.reviewed > 0 && (
                    <span>· {Math.round(accuracy * 100)}%</span>
                  )}
                  {session.skipped > 0 && (
                    <span>· 已跳过 {session.skipped}</span>
                  )}
                </span>
              </div>
              <ProgressBar value={session.index} max={session.ids.length} thick />
            </div>

            {word && preview ? (
              <>
                <div
                  className={cx("card", "fc-card", flipped && "is-flipped")}
                  role="button"
                  tabIndex={0}
                  aria-label={
                    flipped ? t("flashcards.back") : t("flashcards.showAnswer")
                  }
                  onClick={() => {
                    if (!flipped) setFlipped(true);
                  }}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" && !flipped) {
                      event.preventDefault();
                      setFlipped(true);
                    }
                  }}
                >
                  <div className="fc-head">
                    <span className="fc-face-label">
                      {flipped ? t("flashcards.back") : t("flashcards.front")}
                    </span>
                    <span className="spacer" />
                    {canSpeak && (
                      <button
                        type="button"
                        className="btn btn-quiet btn-icon btn-sm"
                        title={t("flashcards.autoPlay")}
                        aria-label={t("flashcards.autoPlay")}
                        onClick={(event) => {
                          event.stopPropagation();
                          play(word);
                        }}
                      >
                        <Icon name="volume" size={16} />
                      </button>
                    )}
                  </div>

                  {flipped ? (
                    <div className="fc-face rise">
                      <div className="fc-def">
                        {word.definition || t("words.noDefinition")}
                      </div>
                      {word.definition2 && (
                        <div className="fc-def2">{word.definition2}</div>
                      )}
                      {word.example && (
                        <div className="fc-example">{word.example}</div>
                      )}
                      {word.note && (
                        <div className="fc-note">
                          <span className="fc-note-ico">
                            <Icon name="info" size={14} />
                          </span>
                          <span>{word.note}</span>
                        </div>
                      )}
                      {word.tags.length > 0 && (
                        <div className="tag-row">
                          {word.tags.map((tag) => (
                            <TagChip key={tag} tag={tag} />
                          ))}
                        </div>
                      )}
                    </div>
                  ) : (
                    <div className="fc-face fc-front">
                      <div className="fc-term">{word.term}</div>
                      <div className="fc-hint">
                        <span className="kbd">空格</span>
                        <span>{t("flashcards.revealHint")}</span>
                      </div>
                    </div>
                  )}
                </div>

                {flipped ? (
                  <div className="fc-grades">
                    {GRADES.map((value, index) => (
                      <button
                        key={value}
                        type="button"
                        className={cx("btn", "fc-grade", value)}
                        onClick={() => grade(value)}
                      >
                        <span className="fc-grade-top">
                          <span className="kbd">{index + 1}</span>
                          <span className="fc-grade-dot" />
                          {t(GRADE_LABEL_KEY[value])}
                        </span>
                        <span className="fc-grade-int">
                          {newCard ? "首次 · " : ""}
                          {formatInterval(preview[value])}
                        </span>
                      </button>
                    ))}
                  </div>
                ) : (
                  <div className="study-actions">
                    <button
                      type="button"
                      className="btn btn-primary btn-lg"
                      onClick={() => setFlipped(true)}
                    >
                      {t("flashcards.showAnswer")}
                      <span className="kbd">空格</span>
                    </button>
                    <button type="button" className="btn btn-quiet" onClick={skip}>
                      {t("quiz.skip")}
                      <span className="kbd">→</span>
                    </button>
                  </div>
                )}
              </>
            ) : (
              <div className="card">
                <EmptyState
                  icon="cards"
                  title={t("flashcards.emptyDeck")}
                  text={t("flashcards.emptyDeckHint")}
                  action={
                    <button type="button" className="btn" onClick={startSession}>
                      {t("flashcards.restart")}
                    </button>
                  }
                />
              </div>
            )}
          </div>
          {sidePanel}
        </div>
      ) : (
        <div className="study-split">
          <div className="study-main">
            <div className="card fc-done rise">
              <Ring
                value={session.correct}
                max={Math.max(session.reviewed, 1)}
                size={136}
                stroke={9}
              >
                <div className="fc-done-num">{Math.round(accuracy * 100)}%</div>
                <div className="tiny muted">{t("flashcards.accuracy")}</div>
              </Ring>
              <div className="stack">
                <h2 className="fc-intro-title">{t("flashcards.sessionDone")}</h2>
                <p className="fc-intro-text">
                  {t("flashcards.sessionDoneText", { n: session.reviewed })}
                </p>
              </div>
              <div className="fc-stats">
                <StatTile
                  label={t("flashcards.reviewedCount")}
                  value={session.reviewed}
                  sub={session.skipped > 0 ? `跳过 ${session.skipped} 张` : undefined}
                />
                <StatTile
                  label={t("flashcards.accuracy")}
                  value={`${Math.round(accuracy * 100)}%`}
                  sub={`${session.correct} / ${Math.max(session.reviewed, 1)}`}
                />
                <StatTile
                  label={t("stats.reviewsToday")}
                  value={reviewsToday(data)}
                />
              </div>
              <div className="study-actions">
                <button
                  type="button"
                  className="btn btn-primary btn-lg"
                  onClick={startSession}
                  disabled={nextRoundSize === 0}
                >
                  {t("flashcards.nextSession")}
                  <Icon name="refresh" size={16} />
                </button>
                <button
                  type="button"
                  className="btn btn-quiet"
                  onClick={() => {
                    setFlipped(false);
                    setSession(null);
                  }}
                >
                  {t("flashcards.restart")}
                </button>
              </div>
              {nextRoundSize === 0 && (
                <p className="tiny muted">
                  暂时没有可复习的卡片了，明天再来吧。
                </p>
              )}
            </div>
          </div>
          {sidePanel}
        </div>
      )}
    </PageShell>
  );
}
