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
  useToast,
} from "@/components/ui";
import { useRouter } from "@/app/router";
import { useT } from "@/i18n";
import {
  QUIZ_CHOICES,
  QUIZ_ROUND,
  buildQuiz,
  quizEligibleWords,
  type QuizDirection,
  type QuizQuestion,
} from "@/lib/quiz";
import { createSession, type Session, type SessionProgress } from "@/lib/session";
import { SHORTCUTS, useShortcutScope, type ShortcutBinding } from "@/lib/shortcuts";
import { getData, useAppData } from "@/lib/store";
import { speak, speechSupported, stopSpeaking } from "@/lib/tts";
import type { Word } from "@/lib/types";
import { cx } from "@/lib/utils";
import "@/styles/study.css";

type Phase = "idle" | "active" | "done";

const LETTERS = ["A", "B", "C", "D"];

const KEY_TO_INDEX: Record<string, number> = {
  a: 0,
  b: 1,
  c: 2,
  d: 3,
  "1": 0,
  "2": 1,
  "3": 2,
  "4": 3,
};

function formatDuration(ms: number): string {
  const total = Math.max(0, Math.round(ms / 1000));
  const minutes = Math.floor(total / 60);
  const seconds = total % 60;
  return `${minutes}:${String(seconds).padStart(2, "0")}`;
}

export function QuizPage() {
  const data = useAppData();
  const settings = data.settings;
  const t = useT();
  const router = useRouter();
  const toast = useToast();

  const [direction, setDirection] = useState<QuizDirection>("termToDef");
  const [phase, setPhase] = useState<Phase>("idle");
  const [questions, setQuestions] = useState<QuizQuestion[]>([]);
  const [answers, setAnswers] = useState<Array<number | null>>([]);
  const [selected, setSelected] = useState<number | null>(null);
  const [elapsed, setElapsed] = useState(0);
  const sessionRef = useRef<Session | null>(null);
  const [progress, setProgress] = useState<SessionProgress | null>(null);
  const [confirmFinish, setConfirmFinish] = useState(false);

  const startedAtRef = useRef(0);
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const eligible = quizEligibleWords(data.words);
  const enough = eligible.length >= QUIZ_CHOICES;
  const answered = selected !== null;

  /* While the feedback for an answer is on screen the session has already moved
     past that question, so step back one to keep showing the card it belonged
     to. */
  const currentIndex = progress ? progress.index - (answered ? 1 : 0) : -1;
  const current =
    phase === "active" && currentIndex >= 0 && currentIndex < questions.length
      ? questions[currentIndex]
      : undefined;
  const total = progress?.total ?? 0;
  const score = progress?.correct ?? 0;
  const answeredCount = progress?.reviewed ?? 0;
  /* Score against the questions actually answered: quitting early must not turn
     a clean 3/3 into "30%". */
  const accuracy = answeredCount > 0 ? score / answeredCount : 0;
  const perfect =
    answeredCount > 0 &&
    answeredCount === questions.length &&
    score === answeredCount;
  const endedEarly = answeredCount > 0 && answeredCount < questions.length;
  const questionLabel =
    progress && progress.total > 0
      ? t("quiz.question", {
          i: Math.min(progress.index + (answered ? 0 : 1), progress.total),
          n: progress.total,
        })
      : "";

  const wordById = useMemo(
    () => new Map<string, Word>(data.words.map((word) => [word.id, word])),
    [data.words],
  );

  const mistakes = questions
    .map((question, questionIndex) => ({
      question,
      answer: answers[questionIndex] ?? null,
      key: `${question.wordId}-${questionIndex}`,
    }))
    .filter((item) => item.answer !== item.question.answerIndex);

  const directionLabel =
    direction === "termToDef" ? t("quiz.termToDef") : t("quiz.defToTerm");
  const canSpeak = speechSupported();

  const play = useCallback(
    (target: Word) => {
      speak(target.term, {
        lang: target.sourceLang,
        rate: settings.ttsRate,
        voiceURI: settings.ttsVoiceURI,
      });
    },
    [settings.ttsRate, settings.ttsVoiceURI],
  );

  const clearTimer = useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
  }, []);

  const finish = useCallback(() => {
    clearTimer();
    stopSpeaking();
    setElapsed(Date.now() - startedAtRef.current);
    setPhase("done");
    setConfirmFinish(false);
  }, [clearTimer]);

  /* Looking at results early is fine, but say how many questions are left. */
  const requestFinish = useCallback(() => {
    const current = sessionRef.current?.progress();
    if (current && current.reviewed > 0 && !current.done) {
      setConfirmFinish(true);
      return;
    }
    finish();
  }, [finish]);

  const goNext = useCallback(() => {
    clearTimer();
    /* Ask the session rather than the rendered state: the 900ms feedback timer
       fires after the last answer has already advanced the session. */
    if (!sessionRef.current || sessionRef.current.progress().done) {
      finish();
      return;
    }
    setSelected(null);
  }, [clearTimer, finish]);

  const start = useCallback(
    (dir: QuizDirection) => {
      const built = buildQuiz(getData().words, dir, QUIZ_ROUND);
      if (built.length === 0) {
        toast(t("quiz.noWords"), "info");
        return;
      }
      const session = createSession({
        ids: built.map((question) => question.wordId),
      });
      sessionRef.current = session;
      setQuestions(built);
      setAnswers(new Array<number | null>(built.length).fill(null));
      setSelected(null);
      setElapsed(0);
      setProgress(session.progress());
      startedAtRef.current = Date.now();
      setPhase("active");
    },
    [toast, t],
  );

  const choose = useCallback(
    (option: number) => {
      const session = sessionRef.current;
      if (selected !== null || !session) return;
      const position = session.progress().index;
      const question = questions[position];
      if (!question) return;
      setSelected(option);
      setAnswers((prev) => {
        const next = prev.slice();
        next[position] = option;
        return next;
      });
      const isCorrect = option === question.answerIndex;
      session.record({ correct: isCorrect });
      setProgress(session.progress());
      /* A correct answer may glide on, but a miss must stay put until the
         correction has actually been read. */
      if (isCorrect) {
        timerRef.current = setTimeout(() => {
          timerRef.current = null;
          goNext();
        }, 900);
      }
    },
    [selected, questions, goNext],
  );

  useEffect(() => () => {
    clearTimer();
    stopSpeaking();
  }, [clearTimer]);

  /* 1–4 / A–D pick an option · Enter advances */
  const pageShortcuts = useMemo<ShortcutBinding[]>(() => {
    if (phase !== "active") return [];
    return [
      {
        ...SHORTCUTS.quizAnswer,
        match: (event) => event.key === "Enter",
        when: () => selected !== null,
        run: () => goNext(),
      },
      {
        ...SHORTCUTS.quizChoose,
        match: (event) => KEY_TO_INDEX[event.key.toLowerCase()] !== undefined,
        run: (event) => choose(KEY_TO_INDEX[event.key.toLowerCase()]),
      },
    ];
  }, [phase, selected, choose, goNext]);
  useShortcutScope("page", pageShortcuts);

  const sidePanel = (
    <aside className="study-side">
      <StatTile
        label={t("quiz.score")}
        value={`${score} / ${answeredCount}`}
        sub={questionLabel || t("quiz.eligible", { n: eligible.length })}
        icon="target"
      />
      <div className="card card-pad stack">
        <div className="card-title">{t("settings.shortcuts")}</div>
        <div className="shortcuts">
          <ShortcutRow keys={["A", "B", "C", "D"]} label={t("quiz.chooseAnswer")} />
          <ShortcutRow
            keys={["1", "2", "3", "4"]}
            label={t("quiz.chooseAnswerNum")}
          />
          <ShortcutRow keys={["Enter"]} label={t("quiz.next")} />
        </div>
      </div>
    </aside>
  );

  return (
    <PageShell
      title={t("quiz.title")}
      subtitle={t("quiz.subtitle")}
      actions={
        phase === "active" ? (
          <button type="button" className="btn btn-quiet" onClick={requestFinish}>
            {t("quiz.finish")}
          </button>
        ) : (
          <Segmented<QuizDirection>
            value={direction}
            options={[
              { value: "termToDef", label: t("quiz.termToDef") },
              { value: "defToTerm", label: t("quiz.defToTerm") },
            ]}
            onChange={setDirection}
            ariaLabel={t("quiz.direction")}
          />
        )
      }
    >
      {phase === "idle" ? (
        <div className="study-split">
          <div className="study-main">
            {enough ? (
              <div className="card fc-intro rise">
                <div className="fc-intro-ico">
                  <Icon name="quiz" size={26} />
                </div>
                <div className="stack">
                  <h2 className="fc-intro-title">{t("quiz.start")}</h2>
                  <p className="fc-intro-text">
                    {directionLabel} · {t("quiz.chooseCount")}{" "}
                    {Math.min(QUIZ_ROUND, eligible.length)}
                  </p>
                </div>
                <div className="row-flex wrap">
                  <span className="chip chip-tag">{directionLabel}</span>
                  <span className="chip chip-new">
                    {t("quiz.eligible", { n: eligible.length })}
                  </span>
                </div>
                <div className="study-actions">
                  <button
                    type="button"
                    className="btn btn-primary btn-lg"
                    onClick={() => start(direction)}
                  >
                    {t("quiz.start")}
                    <Icon name="arrow-right" size={17} />
                  </button>
                </div>
                <p className="tiny muted">{t("quiz.keyboardHint")}</p>
              </div>
            ) : (
              <div className="card">
                <EmptyState
                  icon="quiz"
                  title={t("quiz.noWords")}
                  text={t("quiz.noWordsHint")}
                  action={
                    <button
                      type="button"
                      className="btn btn-primary"
                      onClick={() => router.navigate("words")}
                    >
                      <Icon name="plus" size={16} />
                      {t("words.addWord")}
                    </button>
                  }
                />
              </div>
            )}
          </div>
          {sidePanel}
        </div>
      ) : phase === "active" && current && progress ? (
        <div className="study-split">
          <div className="study-main">
            <div className="study-bar">
              <div className="study-bar-row">
                <span className="study-bar-label mono">{questionLabel}</span>
                <span className="chip chip-tag">{directionLabel}</span>
                <span className="spacer" />
                <span className="chip chip-mastered mono">
                  {t("quiz.score")} {score}
                </span>
              </div>
              <ProgressBar value={progress.index} max={total} thick />
            </div>

            <div className="card quiz-prompt rise">
              <div className="row-flex">
                <span className="fc-face-label">
                  {direction === "termToDef"
                    ? t("flashcards.front")
                    : t("flashcards.back")}
                </span>
                <span className="spacer" />
                {canSpeak && wordById.get(current.wordId) && (
                  <button
                    type="button"
                    className="btn btn-quiet btn-icon btn-sm"
                    title={t("flashcards.autoPlay")}
                    aria-label={t("flashcards.autoPlay")}
                    onClick={() => {
                      const target = wordById.get(current.wordId);
                      if (target) play(target);
                    }}
                  >
                    <Icon name="volume" size={16} />
                  </button>
                )}
              </div>
              <div
                className={cx(
                  "quiz-prompt-text",
                  direction === "termToDef" ? "is-term" : "is-def",
                )}
              >
                {current.prompt}
              </div>
            </div>

            <div className="quiz-options">
              {current.options.map((option, optionIndex) => {
                const isAnswer = optionIndex === current.answerIndex;
                const isPicked = selected === optionIndex;
                const state = !answered
                  ? ""
                  : isAnswer
                    ? "is-correct"
                    : isPicked
                      ? "is-wrong"
                      : "is-dim";
                return (
                  <button
                    key={`${current.wordId}-${optionIndex}`}
                    type="button"
                    className={cx("btn", "quiz-option", state)}
                    onClick={() => choose(optionIndex)}
                    disabled={answered}
                  >
                    <span className="quiz-key">{LETTERS[optionIndex]}</span>
                    <span className="quiz-opt-text">{option}</span>
                    {answered && isAnswer && (
                      <span className="quiz-opt-ico t-ok">
                        <Icon name="check" size={16} />
                      </span>
                    )}
                    {answered && isPicked && !isAnswer && (
                      <span className="quiz-opt-ico t-bad">
                        <Icon name="x" size={16} />
                      </span>
                    )}
                  </button>
                );
              })}
            </div>

            <div className="quiz-foot">
              {answered ? (
                <>
                  <div
                    className={cx(
                      "notice",
                      selected === current.answerIndex ? "is-ok" : "is-bad",
                    )}
                  >
                    <span className="notice-ico">
                      <Icon
                        name={selected === current.answerIndex ? "check" : "x"}
                        size={15}
                      />
                    </span>
                    <span>
                      {selected === current.answerIndex
                        ? t("quiz.correct")
                        : `${t("quiz.wrong")} · ${t("quiz.correctAnswer")}：${
                            current.options[current.answerIndex]
                          }`}
                    </span>
                  </div>
                  <button
                    type="button"
                    className="btn btn-primary"
                    onClick={goNext}
                  >
                    {progress.done ? t("quiz.finish") : t("quiz.next")}
                    <span className="kbd">Enter</span>
                  </button>
                </>
              ) : (
                <p className="tiny muted">
                  <span className="kbd">A</span> <span className="kbd">B</span>{" "}
                  <span className="kbd">C</span> <span className="kbd">D</span> /{" "}
                  <span className="kbd">1</span> <span className="kbd">2</span>{" "}
                  <span className="kbd">3</span> <span className="kbd">4</span>{" "}
                  {t("quiz.chooseHintSuffix")}
                </p>
              )}
            </div>
          </div>
          {sidePanel}
        </div>
      ) : (
        <div className="study-split">
          <div className="study-main">
            <SessionResult
              accuracy={accuracy}
              ringValue={score}
              ringMax={Math.max(answeredCount, 1)}
              ringSize={140}
              accuracyLabel={t("quiz.accuracy")}
              title={
                perfect
                  ? t("quiz.perfect")
                  : endedEarly
                    ? t("quiz.endedEarly")
                    : t("quiz.keepGoing")
              }
              text={t("quiz.result")}
              leftStat={
                <StatTile
                  label={t("quiz.score")}
                  value={`${score} / ${answeredCount}`}
                  sub={
                    answeredCount < questions.length
                      ? t("quiz.answeredCount", {
                          n: answeredCount,
                          total: questions.length,
                        })
                      : undefined
                  }
                />
              }
              rightStat={
                <StatTile
                  label={t("quiz.timeSpent")}
                  value={formatDuration(elapsed)}
                />
              }
              actions={
                <>
                  <button
                    type="button"
                    className="btn btn-primary btn-lg"
                    onClick={() => start(direction)}
                  >
                    {t("quiz.again")}
                    <Icon name="refresh" size={16} />
                  </button>
                  <button
                    type="button"
                    className="btn btn-quiet"
                    onClick={() => {
                      sessionRef.current = null;
                      setPhase("idle");
                      setQuestions([]);
                      setAnswers([]);
                      setSelected(null);
                      setProgress(null);
                    }}
                  >
                    {t("quiz.exit")}
                  </button>
                </>
              }
            />

            {mistakes.length > 0 && (
              <div className="card card-flush">
                <div className="card-head">
                  <span className="card-title">{t("quiz.missed")}</span>
                  <span className="card-sub">{mistakes.length}</span>
                </div>
                <div className="quiz-mistakes">
                  {mistakes.map((item) => {
                    const target = wordById.get(item.question.wordId);
                    return (
                      <div className="quiz-mistake" key={item.key}>
                        <div className="quiz-mistake-main">
                          <div className="quiz-mistake-term">
                            {item.question.prompt}
                          </div>
                          <div className="quiz-mistake-ans">
                            <span>
                              {t("quiz.yourAnswer")}：
                              <b
                                className={
                                  item.answer === null ? undefined : "t-bad"
                                }
                              >
                                {item.answer === null
                                  ? t("quiz.unanswered")
                                  : item.question.options[item.answer]}
                              </b>
                            </span>
                            <span>·</span>
                            <span>
                              {t("quiz.correctAnswer")}：
                              <b className="t-ok">
                                {item.question.options[item.question.answerIndex]}
                              </b>
                            </span>
                          </div>
                        </div>
                        {canSpeak && target && (
                          <button
                            type="button"
                            className="btn btn-quiet btn-icon btn-sm"
                            title={t("flashcards.autoPlay")}
                            aria-label={t("flashcards.autoPlay")}
                            onClick={() => play(target)}
                          >
                            <Icon name="volume" size={16} />
                          </button>
                        )}
                      </div>
                    );
                  })}
                </div>
              </div>
            )}
          </div>
          {sidePanel}
        </div>
      )}
      <ConfirmDialog
        open={confirmFinish}
        title={t("quiz.exitTitle")}
        body={t("quiz.exitConfirm")}
        confirmLabel={t("quiz.exit")}
        cancelLabel={t("common.cancel")}
        danger={false}
        onConfirm={finish}
        onCancel={() => setConfirmFinish(false)}
      />
    </PageShell>
  );
}
