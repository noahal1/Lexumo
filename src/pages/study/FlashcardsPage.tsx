import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { Icon } from "@/components/Icon";
import { SessionResult } from "@/components/SessionResult";
import {
  ConfirmDialog,
  EmptyState,
  PageShell,
  ProgressBar,
  Segmented,
  ShortcutRow,
  StatTile,
  StatusChip,
  TagChip,
  useToast,
} from "@/components/ui";
import { useRouter } from "@/app/router";
import { useT, type MessageKey } from "@/i18n";
import { prefersReducedMotion } from "@/lib/motion";
import {
  createSession,
  formatAccuracy,
  gradeCountsAsCorrect,
  type Session,
  type SessionProgress,
} from "@/lib/session";
import { formatInterval, isNew, previewGrades } from "@/lib/srs";
import {
  bumpListen,
  dueWords,
  getData,
  gradeWord,
  reviewsToday,
  undoReview,
  useAppData,
} from "@/lib/store";
import { speak, speechSupported, stopSpeaking } from "@/lib/tts";
import { SHORTCUTS, useShortcutScope, type ShortcutBinding } from "@/lib/shortcuts";
import {
  STATUS_LABEL_KEY,
  type AppData,
  type Grade,
  type SrsState,
  type Word,
  type WordStatus,
} from "@/lib/types";
import { cx, shuffle, startOfDay } from "@/lib/utils";
import "@/styles/study.css";

const GRADES: Grade[] = ["hard", "good", "easy"];

const GRADE_LABEL_KEY: Record<Grade, MessageKey> = {
  hard: "flashcards.gradeHard",
  good: "flashcards.gradeGood",
  easy: "flashcards.gradeEasy",
};

/** Where the cards in a session come from. */
type DeckSource = "due" | "new" | "all" | "favorites";

/**
 * What the page renders. The session itself is a mutable closure, so we take a
 * snapshot after every step to give React a new object to re-render from.
 */
interface SessionView {
  progress: SessionProgress;
  current: string | null;
  canUndo: boolean;
}

/**
 * Store-side half of an undo: the schedule and log the last grade overwrote.
 * The session owns the counters; this is everything else needed to put the card
 * back exactly as it was.
 */
interface StoreStep {
  id: string;
  prevSrs: SrsState | null;
  prevStatus: WordStatus;
  logId: string;
}

/** How many brand-new cards the daily allowance still has room for. */
function newCardsLeft(data: AppData, now: number): number {
  const start = startOfDay(now);
  /* A card counts as "introduced today" when its earliest review log is
     from today. Deriving this from logs (rather than reviewCount === 1)
     keeps the count stable even if a fresh card is graded twice in one
     day, and undoing a first grade restores the allowance naturally. */
  const firstReviewAt = new Map<string, number>();
  for (const log of data.logs) {
    const prev = firstReviewAt.get(log.wordId);
    if (prev === undefined || log.at < prev) firstReviewAt.set(log.wordId, log.at);
  }
  const introduced = data.words.filter((word) => {
    const at = firstReviewAt.get(word.id);
    return at !== undefined && at >= start;
  }).length;
  return Math.max(0, data.settings.newCardsPerDay - introduced);
}

/** Card ids for a session, ordered by the user's review-order setting. */
function buildSession(data: AppData, now: number, source: DeckSource): string[] {
  if (source === "all") {
    return shuffle(data.words).map((word) => word.id);
  }
  if (source === "favorites") {
    return shuffle(data.words.filter((word) => word.favorite)).map(
      (word) => word.id,
    );
  }
  if (source === "new") {
    return data.words
      .filter((word) => isNew(word.srs))
      .slice(0, newCardsLeft(data, now))
      .map((word) => word.id);
  }

  const due = dueWords(data, now);
  const review = due.filter((word) => !isNew(word.srs));
  const fresh = due
    .filter((word) => isNew(word.srs))
    .slice(0, newCardsLeft(data, now));

  if (data.settings.reviewOrder === "random") {
    return shuffle([...review, ...fresh]).map((word) => word.id);
  }

  const ordered = [...review].sort(
    (a, b) =>
      (a.srs?.dueAt ?? Number.MAX_SAFE_INTEGER) -
      (b.srs?.dueAt ?? Number.MAX_SAFE_INTEGER),
  );
  return [...ordered, ...fresh].map((word) => word.id);
}

export function FlashcardsPage() {
  const data = useAppData();
  const settings = data.settings;
  const t = useT();
  const router = useRouter();
  const toast = useToast();

  const [deck, setDeck] = useState<DeckSource>("due");
  const [confirmExit, setConfirmExit] = useState(false);
  const sessionRef = useRef<Session | null>(null);
  const [view, setView] = useState<SessionView | null>(null);
  const [flipped, setFlipped] = useState(false);
  const [storeSteps, setStoreSteps] = useState<StoreStep[]>([]);
  const spokenRef = useRef<string | null>(null);

  /* The card turn is two halves driven by timers (see `study.css`): rotate the
     front to edge-on, swap the face while it is invisible, rotate the back in.
     Splitting it that way is what keeps the back text from ever being seen
     mirrored — CSS alone cannot swap the DOM at the right instant. */
  const [turn, setTurn] = useState<"idle" | "out" | "in">("idle");
  const turnTimers = useRef<number[]>([]);
  const clearTurn = useCallback(() => {
    turnTimers.current.forEach((id) => window.clearTimeout(id));
    turnTimers.current = [];
  }, []);
  useEffect(() => clearTurn, [clearTurn]);

  /* Snapshot the mutable session into render state. Every mutation below writes
     through the ref and then calls this, so the page never reads stale counters
     and React always gets a fresh object to re-render from. */
  const sync = useCallback(() => {
    const session = sessionRef.current;
    setView(
      session
        ? {
            progress: session.progress(),
            current: session.current(),
            canUndo: session.canUndo(),
          }
        : null,
    );
  }, []);

  /* Reveal the answer. With reduced motion the face simply appears — no
     timers, no rotation, no 125ms wait before the answer is readable. */
  const reveal = useCallback(() => {
    /* Ignore a second reveal while the card is already turning: restarting the
       rotation mid-way would snap it back to face-on. */
    if (flipped || turn !== "idle") return;
    if (prefersReducedMotion()) {
      setFlipped(true);
      return;
    }
    clearTurn();
    setTurn("out");
    turnTimers.current.push(
      window.setTimeout(() => {
        setFlipped(true);
        setTurn("in");
        turnTimers.current.push(window.setTimeout(() => setTurn("idle"), 190));
      }, 125),
    );
  }, [flipped, turn, clearTurn]);

  /* Put the card back to its front face, cancelling a turn in flight. */
  const resetFlip = useCallback(() => {
    clearTurn();
    setTurn("idle");
    setFlipped(false);
  }, [clearTurn]);

  const now = Date.now();
  const canSpeak = speechSupported();
  const due = dueWords(data, now);
  const dueReviewCount = due.filter((word) => !isNew(word.srs)).length;
  const freshLeft = newCardsLeft(data, now);
  /* "Caught up" is the good state, not an error: nothing is due today. */
  const caughtUp = due.length === 0;
  const hasNewWords = data.words.some((candidate) => isNew(candidate.srs));
  const capReached =
    settings.newCardsPerDay > 0 && freshLeft === 0 && hasNewWords;

  /* Cheap per-deck sizes: no need to materialise four full sessions. */
  const counts: Record<DeckSource, number> = {
    due:
      dueReviewCount +
      Math.min(due.filter((word) => isNew(word.srs)).length, freshLeft),
    new: Math.min(data.words.filter((word) => isNew(word.srs)).length, freshLeft),
    all: data.words.length,
    favorites: data.words.filter((word) => word.favorite).length,
  };
  const deckSize = counts[deck];

  const progress = view?.progress ?? null;
  const inProgress = progress !== null && !progress.done;
  const currentId = view?.current ?? null;
  const canUndo = view?.canUndo ?? false;
  const word: Word | null = currentId
    ? data.words.find((candidate) => candidate.id === currentId) ?? null
    : null;
  const newCard = word ? isNew(word.srs) : false;
  const preview = word
    ? previewGrades({ srs: word.srs, status: word.status })
    : null;
  const remaining = progress ? Math.max(0, progress.total - progress.index) : 0;

  const deckOptions: Array<{ value: DeckSource; label: string; count: number }> = [
    { value: "due", label: t("flashcards.deckDue"), count: counts.due },
    { value: "new", label: t("flashcards.deckNew"), count: counts.new },
    { value: "all", label: t("flashcards.deckAll"), count: counts.all },
    {
      value: "favorites",
      label: t("flashcards.deckFavorites"),
      count: counts.favorites,
    },
  ];

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
    const ids = buildSession(getData(), Date.now(), deck);
    resetFlip();
    setStoreSteps([]);
    spokenRef.current = null;
    sessionRef.current = ids.length > 0 ? createSession({ ids }) : null;
    sync();
  }, [deck, sync, resetFlip]);

  const exitSession = useCallback(() => {
    stopSpeaking();
    sessionRef.current = null;
    sync();
    resetFlip();
    setStoreSteps([]);
    setConfirmExit(false);
  }, [sync, resetFlip]);

  /* Leaving mid-session loses your place, so ask first — but only once the
     reader has actually graded something. */
  const requestExit = useCallback(() => {
    const current = sessionRef.current?.progress();
    if (current && current.reviewed > 0 && !current.done) {
      setConfirmExit(true);
      return;
    }
    exitSession();
  }, [exitSession]);

  const confirmExitNow = useCallback(() => {
    const reviewed = sessionRef.current?.progress().reviewed ?? 0;
    exitSession();
    if (reviewed > 0) {
      toast(t("flashcards.exitSaved", { n: reviewed }), "ok");
    }
  }, [exitSession, toast, t]);

  const grade = useCallback(
    (value: Grade) => {
      const session = sessionRef.current;
      if (!word || !session) return;
      const prevSrs = word.srs;
      const prevStatus = word.status;
      const result = gradeWord(word.id, value);
      if (!result) return;
      setStoreSteps((prev) => [
        ...prev,
        { id: word.id, prevSrs, prevStatus, logId: result.logId },
      ]);
      session.record({ correct: gradeCountsAsCorrect(value) });
      sync();
      resetFlip();
    },
    [word, sync, resetFlip],
  );

  const skip = useCallback(() => {
    const session = sessionRef.current;
    if (!session) return;
    session.skip();
    sync();
    resetFlip();
  }, [sync, resetFlip]);

  /* Roll back the last grade or skip. `undoReview` must run outside the state
     updater: StrictMode invokes updaters twice, which would double-undo. */
  const undo = useCallback(() => {
    const session = sessionRef.current;
    if (!session) return;
    const step = session.undo();
    if (!step) return;

    if (step.kind === "record") {
      const storeStep = storeSteps[storeSteps.length - 1];
      if (storeStep) {
        undoReview(
          storeStep.id,
          storeStep.prevSrs,
          storeStep.prevStatus,
          storeStep.logId,
        );
      }
      setStoreSteps((prev) => prev.slice(0, -1));
      clearTurn();
      setTurn("idle");
      setFlipped(true);
    } else {
      setFlipped(false);
    }
    sync();
  }, [storeSteps, sync, clearTurn]);

  /* Auto-pronounce the term once per card (token guards StrictMode double-run).
     Normal mode speaks on reveal, matching the setting's wording; listening
     mode (audioFirst) speaks while the term is still hidden. */
  useEffect(() => {
    if (!word || !inProgress) return;
    if (!speechSupported()) return;
    const listening = settings.audioFirst;
    const shouldSpeak = listening
      ? !flipped
      : flipped && settings.autoPlayAudio;
    if (!shouldSpeak) return;
    const token = `${word.id}:${progress?.index ?? 0}:${flipped ? "back" : "front"}`;
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
    flipped,
    progress?.index,
    settings.audioFirst,
    settings.autoPlayAudio,
    settings.ttsRate,
    settings.ttsVoiceURI,
  ]);

  useEffect(() => () => stopSpeaking(), []);

  /* Space flips · 1/2/3 grade · ←/→ skip · Ctrl+Z undo */
  const pageShortcuts = useMemo<ShortcutBinding[]>(() => {
    if (!inProgress) return [];
    return [
      {
        ...SHORTCUTS.undo,
        match: (event) =>
          (event.ctrlKey === true || event.metaKey === true) &&
          event.key.toLowerCase() === "z",
        run: () => undo(),
      },
      {
        ...SHORTCUTS.flip,
        match: (event) => event.code === "Space" || event.key === " ",
        /* A focused button owns Space; otherwise it would flip the card *and*
           activate the button. */
        when: (event) =>
          (event.target as { tagName?: string } | null)?.tagName !== "BUTTON",
        run: () => (flipped ? resetFlip() : reveal()),
      },
      {
        ...SHORTCUTS.skip,
        match: (event) => event.key === "ArrowLeft" || event.key === "ArrowRight",
        run: () => skip(),
      },
      {
        ...SHORTCUTS.grade,
        when: () => flipped,
        match: (event) =>
          event.key === "1" || event.key === "2" || event.key === "3",
        run: (event) => {
          if (event.key === "1") grade("hard");
          else if (event.key === "2") grade("good");
          else grade("easy");
        },
      },
    ];
  }, [inProgress, flipped, grade, skip, undo, reveal, resetFlip]);
  useShortcutScope("page", pageShortcuts);

  const sidePanel = (
    <aside className="study-side">
      {inProgress && (
        <StatTile
          label={t("flashcards.remaining")}
          value={remaining}
          sub={t("flashcards.deckSize", { n: progress?.total ?? 0 })}
          icon="layers"
        />
      )}
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
          <ShortcutRow keys={["←", "→"]} label={t("quiz.skip")} />
          <ShortcutRow keys={["Ctrl", "Z"]} label={t("flashcards.undo")} />
        </div>
      </div>
    </aside>
  );

  return (
    <PageShell title={t("flashcards.title")} subtitle={t("flashcards.subtitle")}>
      {!progress ? (
        data.words.length === 0 ? (
          <div className="card">
            <EmptyState
              icon="cards"
              title={t("words.noWords")}
              text={t("words.noWordsHint")}
              action={
                <button
                  type="button"
                  className="btn btn-primary"
                  onClick={() => router.navigate("words")}
                >
                  <Icon name="plus" size={16} />
                  {t("words.addFirst")}
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

                <div className="fc-deck">
                  <span className="label">{t("flashcards.buildDeck")}</span>
                  <Segmented
                    value={deck}
                    options={deckOptions}
                    onChange={setDeck}
                    ariaLabel={t("flashcards.buildDeck")}
                  />
                </div>

                <div className="row-flex wrap">
                  <span className="chip chip-learning">
                    {t("flashcards.dueCount", { n: dueReviewCount })}
                  </span>
                  <span className="chip chip-new">
                    {t("flashcards.newCount", { n: counts.new })}
                  </span>
                  <span className="chip chip-tag">
                    {t("flashcards.deckSize", { n: deckSize })}
                  </span>
                </div>

                {capReached && !caughtUp && (
                  <div className="notice">
                    <span className="notice-ico">
                      <Icon name="info" size={15} />
                    </span>
                    <span>
                      {t("flashcards.newCapReached", {
                        n: settings.newCardsPerDay,
                      })}
                    </span>
                  </div>
                )}

                {deckSize === 0 ? (
                  caughtUp && (deck === "due" || deck === "new") ? (
                    <EmptyState
                      icon="sparkles"
                      title={t("flashcards.noCards")}
                      text={t("flashcards.noCardsHint")}
                      action={
                        <div className="row-flex wrap">
                          <button
                            type="button"
                            className="btn btn-primary"
                            onClick={() => router.navigate("quiz")}
                          >
                            <Icon name="quiz" size={16} />
                            {t("flashcards.goQuiz")}
                          </button>
                          <button
                            type="button"
                            className="btn btn-quiet"
                            onClick={() => router.navigate("words")}
                          >
                            <Icon name="plus" size={16} />
                            {t("words.addWord")}
                          </button>
                        </div>
                      }
                    />
                  ) : (
                    <div className="notice">
                      <span className="notice-ico">
                        <Icon name="info" size={15} />
                      </span>
                      <span>
                        {t("flashcards.emptyDeck")}{" "}
                        {t("flashcards.emptyDeckHint")}
                      </span>
                    </div>
                  )
                ) : (
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
                )}
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
                    i: progress.index + 1,
                    n: progress.total,
                  })}
                </span>
                {word && (
                  <StatusChip
                    status={word.status}
                    label={t(STATUS_LABEL_KEY[word.status])}
                  />
                )}
                <span className="spacer" />
                <button
                  type="button"
                  className="btn btn-quiet btn-icon btn-sm"
                  title={t("flashcards.undo")}
                  aria-label={t("flashcards.undo")}
                  onClick={undo}
                  disabled={!canUndo}
                >
                  <Icon name="undo" size={16} />
                </button>
                <button
                  type="button"
                  className="btn btn-quiet btn-sm"
                  onClick={requestExit}
                >
                  <Icon name="x" size={15} />
                  {t("flashcards.exit")}
                </button>
              </div>
              <ProgressBar value={progress.index} max={progress.total} thick />
              <div className="study-bar-meta">
                <span>
                  {t("flashcards.reviewedCount")} {progress.reviewed}
                </span>
                {progress.reviewed > 0 && (
                  <span>· {formatAccuracy(progress.accuracy)}</span>
                )}
                {progress.skipped > 0 && (
                  <span>
                    · {t("flashcards.skippedCount", { n: progress.skipped })}
                  </span>
                )}
              </div>
            </div>

            {word && preview ? (
              <>
                <div
                  key={word.id}
                  className={cx(
                    "card",
                    "fc-card",
                    flipped && "is-flipped",
                    turn === "out" && "is-turn-out",
                    turn === "in" && "is-turn-in",
                  )}
                  role={flipped ? undefined : "button"}
                  tabIndex={flipped ? -1 : 0}
                  aria-label={
                    flipped ? undefined : t("flashcards.showAnswer")
                  }
                  onClick={() => {
                    if (!flipped) reveal();
                  }}
                  onKeyDown={(event) => {
                    if (event.key === "Enter" && !flipped) {
                      event.preventDefault();
                      reveal();
                    }
                  }}
                >
                  <div className="fc-head">
                    <span className="fc-face-label">
                      {flipped ? t("flashcards.back") : t("flashcards.front")}
                    </span>
                    <span className="spacer" />
                    <button
                      type="button"
                      className="btn btn-quiet btn-icon btn-sm"
                      title={t("quiz.skip")}
                      aria-label={t("quiz.skip")}
                      onClick={(event) => {
                        event.stopPropagation();
                        skip();
                      }}
                    >
                      <Icon name="arrow-right" size={16} />
                    </button>
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
                      <div className="fc-term-sm">{word.term}</div>
                      <div className="fc-divider" />
                      <div className="fc-def">
                        {word.definition || t("words.noDefinition")}
                      </div>
                      {word.definition2 && (
                        <div className="fc-def2">{word.definition2}</div>
                      )}
                      {word.example && (
                        <div className="fc-example">
                          <span className="fc-example-en">{word.example}</span>
                          {word.exampleZh && (
                            <span className="fc-example-zh">{word.exampleZh}</span>
                          )}
                        </div>
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
                  ) : settings.audioFirst ? (
                    <div className="fc-face fc-front rise">
                      <div className="fc-listen">
                        <Icon name="volume" size={34} />
                        <p className="fc-listen-text">
                          {t("flashcards.listenPrompt")}
                        </p>
                        {canSpeak && (
                          <button
                            type="button"
                            className="btn btn-quiet btn-sm"
                            onClick={(event) => {
                              event.stopPropagation();
                              play(word);
                            }}
                          >
                            <Icon name="volume" size={15} />
                            {t("flashcards.listenAgain")}
                          </button>
                        )}
                      </div>
                      <div className="fc-hint">
                        <span className="kbd">{t("flashcards.spaceKey")}</span>
                        <span>{t("flashcards.revealHint")}</span>
                      </div>
                    </div>
                  ) : (
                    <div className="fc-face fc-front rise">
                      <div className="fc-term">{word.term}</div>
                      <div className="fc-hint">
                        <span className="kbd">{t("flashcards.spaceKey")}</span>
                        <span>{t("flashcards.revealHint")}</span>
                      </div>
                    </div>
                  )}
                </div>

                {flipped ? (
                  <>
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
                            {t(GRADE_LABEL_KEY[value])}
                          </span>
                          <span className="fc-grade-int">
                            {newCard
                              ? t("flashcards.firstTime")
                              : formatInterval(preview[value].intervalDays)}
                          </span>
                        </button>
                      ))}
                    </div>
                    {newCard && (
                      <p className="tiny muted fc-grade-note">
                        {t("flashcards.firstGradeHint")}
                      </p>
                    )}
                  </>
                ) : (
                  <div className="study-actions">
                    <button
                      type="button"
                      className="btn btn-primary btn-lg"
                      onClick={reveal}
                    >
                      {t("flashcards.showAnswer")}
                      <span className="kbd">{t("flashcards.spaceKey")}</span>
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
            <SessionResult
              accuracy={progress.accuracy}
              ringValue={progress.correct}
              ringMax={Math.max(progress.reviewed, 1)}
              accuracyLabel={t("flashcards.accuracy")}
              accuracySub={`${progress.correct} / ${Math.max(progress.reviewed, 1)}`}
              title={t("flashcards.sessionDone")}
              text={t("flashcards.sessionDoneText", { n: progress.reviewed })}
              leftStat={
                <StatTile
                  label={t("flashcards.reviewedCount")}
                  value={progress.reviewed}
                  sub={
                    progress.skipped > 0
                      ? t("flashcards.skippedCount", { n: progress.skipped })
                      : undefined
                  }
                />
              }
              rightStat={
                <StatTile
                  label={t("stats.reviewsToday")}
                  value={reviewsToday(data)}
                />
              }
              actions={
                <>
                  {deckSize > 0 ? (
                    <button
                      type="button"
                      className="btn btn-primary btn-lg"
                      onClick={startSession}
                    >
                      {t("flashcards.nextSession")}
                      <Icon name="refresh" size={16} />
                    </button>
                  ) : (
                    <button
                      type="button"
                      className="btn btn-primary btn-lg"
                      onClick={() => router.navigate("quiz")}
                    >
                      <Icon name="quiz" size={16} />
                      {t("flashcards.goQuiz")}
                    </button>
                  )}
                  {canUndo && (
                    <button type="button" className="btn btn-quiet" onClick={undo}>
                      <Icon name="undo" size={16} />
                      {t("flashcards.undo")}
                    </button>
                  )}
                  <button
                    type="button"
                    className="btn btn-quiet"
                    onClick={exitSession}
                  >
                    {t("common.back")}
                  </button>
                </>
              }
              footer={
                deckSize === 0 ? (
                  <p className="tiny muted">{t("flashcards.noCardsHint")}</p>
                ) : undefined
              }
            />
          </div>
          {sidePanel}
        </div>
      )}
      <ConfirmDialog
        open={confirmExit}
        title={t("flashcards.exit")}
        body={t("flashcards.exitConfirm", { n: remaining })}
        confirmLabel={t("flashcards.exit")}
        cancelLabel={t("common.cancel")}
        onConfirm={confirmExitNow}
        onCancel={() => setConfirmExit(false)}
      />
    </PageShell>
  );
}
