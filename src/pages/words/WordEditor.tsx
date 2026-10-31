/** Add / edit a single word. Owns its draft state; commits through the store. */
import { useCallback, useEffect, useRef, useState } from "react";
import { Icon } from "@/components/Icon";
import { Modal, useToast } from "@/components/ui";
import { useT } from "@/i18n";
import { langName } from "@/lib/languages";
import { addWord, findDuplicate, updateWord, useAppData } from "@/lib/store";
import {
  LookupError,
  alternativeMeaning,
  lookupTerm,
  posTags,
  primaryMeaning,
  type LookupFailure,
} from "@/lib/translate";
import { STATUS_LABEL_KEY, STATUS_ORDER, type Word, type WordStatus } from "@/lib/types";

export interface WordEditorProps {
  open: boolean;
  /** null → create mode. */
  word: Word | null;
  defaultListId: string;
  onClose: () => void;
  /** Ask the parent to confirm deletion (editor closes itself first). */
  onDelete: (word: Word) => void;
}

type LookupState = "idle" | "loading" | "error";

export function WordEditor({ open, word, defaultListId, onClose, onDelete }: WordEditorProps) {
  const t = useT();
  const toast = useToast();
  const data = useAppData();

  const [term, setTerm] = useState("");
  const [pos, setPos] = useState("");
  const [definition, setDefinition] = useState("");
  const [definition2, setDefinition2] = useState("");
  const [example, setExample] = useState("");
  const [exampleZh, setExampleZh] = useState("");
  const [note, setNote] = useState("");
  const [listId, setListId] = useState(defaultListId);
  const [status, setStatus] = useState<WordStatus>("new");
  const [favorite, setFavorite] = useState(false);
  const [error, setError] = useState("");
  const [dismissOpen, setDismissOpen] = useState(false);

  const [lookupState, setLookupState] = useState<LookupState>("idle");
  const [lookupError, setLookupError] = useState<LookupFailure | null>(null);
  const [phonetic, setPhonetic] = useState("");
  const abortRef = useRef<AbortController | null>(null);
  // The reverse direction (meaning → word) runs on its own controller: typing a
  // meaning must not cancel an in-flight forward lookup, and vice versa.
  const [reverseState, setReverseState] = useState<LookupState>("idle");
  const [reverseError, setReverseError] = useState<LookupFailure | null>(null);
  const reverseAbortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (!open) {
      abortRef.current?.abort();
      reverseAbortRef.current?.abort();
      return;
    }
    setError("");
    setDismissOpen(false);
    setLookupState("idle");
    setLookupError(null);
    setReverseState("idle");
    setReverseError(null);
    setPhonetic(word?.phonetic ?? "");
    if (word) {
      setTerm(word.term);
      setPos(word.pos ?? "");
      setDefinition(word.definition);
      setDefinition2(word.definition2);
      setExample(word.example);
      setExampleZh(word.exampleZh ?? "");
      setNote(word.note);
      setListId(word.listId);
      setStatus(word.status);
      setFavorite(word.favorite);
    } else {
      setTerm("");
      setPos("");
      setDefinition("");
      setDefinition2("");
      setExample("");
      setExampleZh("");
      setNote("");
      setListId(defaultListId);
      setStatus("new");
      setFavorite(false);
    }
  }, [open, word, defaultListId]);

  // Drop any in-flight request when the dialog unmounts.
  useEffect(
    () => () => {
      abortRef.current?.abort();
      reverseAbortRef.current?.abort();
    },
    [],
  );

  const list = data.lists.find((l) => l.id === listId) ?? data.lists[0];
  const fromLang = list?.sourceLang ?? "en";
  const toLang = list?.targetLang ?? "zh-CN";
  // The wordbook's own pair is what translation defaults to; surfacing it next
  // to the button is what makes that visible instead of implied.
  const uiLang = data.settings.uiLang;
  const pairLabel = `${langName(fromLang, uiLang)} → ${langName(toLang, uiLang)}`;

  const trimmed = term.trim();
  const duplicate = trimmed ? findDuplicate(data, trimmed, listId) : undefined;
  const showDuplicate = Boolean(duplicate && duplicate.id !== word?.id);

  // A draft is dirty when any field differs from what was loaded. The create
  // baseline is all-empty, so a word filled in by the "翻译" button counts too —
  // closing after a lookup must not throw the result away without asking.
  const dirty =
    term !== (word?.term ?? "") ||
    phonetic !== (word?.phonetic ?? "") ||
    pos !== (word?.pos ?? "") ||
    definition !== (word?.definition ?? "") ||
    definition2 !== (word?.definition2 ?? "") ||
    example !== (word?.example ?? "") ||
    exampleZh !== (word?.exampleZh ?? "") ||
    note !== (word?.note ?? "") ||
    listId !== (word?.listId ?? defaultListId) ||
    status !== (word?.status ?? "new") ||
    favorite !== (word?.favorite ?? false);

  /**
   * Esc, a backdrop click and × all land here. A dirty draft asks first —
   * inline in the footer, so no second dialog stacks on top of this one.
   */
  const requestClose = () => {
    if (dismissOpen) {
      setDismissOpen(false);
      return;
    }
    if (dirty) {
      setDismissOpen(true);
      return;
    }
    onClose();
  };

  /**
   * Look the term up and fill the meaning fields.
   *
   * Only the "翻译" button calls this. Nothing runs on blur or on typing: a
   * lookup costs a network request and rewrites fields the user may be
   * mid-way through, so it waits until they ask for it. That makes every call
   * an explicit overwrite, and `force` (bypass the local cache) is the right
   * default for it — a click is also how a stale cached entry gets refreshed.
   */
  const runLookup = useCallback(
    async () => {
      const value = term.trim();
      if (!value) return;
      abortRef.current?.abort();
      const controller = new AbortController();
      abortRef.current = controller;

      setLookupState("loading");
      setLookupError(null);
      try {
        const result = await lookupTerm(value, {
          from: fromLang,
          to: toLang,
          force: true,
          signal: controller.signal,
        });
        if (controller.signal.aborted) return;

        const primary = primaryMeaning(result);
        const secondary = alternativeMeaning(result);
        // Part of speech goes into its own field, never into the definition:
        // "n. 类比，比拟" is a dictionary line, but the gloss the user reads on
        // a card should just be "类比，比拟" with "n." shown beside it.
        const posText = posTags(result).join(" ");
        if (posText) setPos(posText);
        if (primary) setDefinition(primary);
        if (secondary) setDefinition2(secondary);
        // The dictionary payload carries the example both ways when the target
        // language is Chinese. Both halves go in: the sentence is what you read
        // in the deck, the translation is what makes an unknown word usable.
        //
        // They go in together or not at all. The translation only means
        // something under the sentence it came with, so it is written only in
        // the same step that writes that sentence — never attached to a
        // sentence the user typed, which would put two unrelated lines on one
        // card.
        const sampleEn = result.examples[0]?.en ?? "";
        const sampleZh = result.examples[0]?.zh ?? "";
        if (sampleEn) {
          setExample(sampleEn);
          if (sampleZh) setExampleZh(sampleZh);
        }
        setPhonetic(result.phonetic);
        setLookupState("idle");
        if (!result.fromCache) toast(t("words.translationApplied"), "ok");
      } catch (e) {
        if (controller.signal.aborted) return;
        setLookupState("error");
        setLookupError(e instanceof LookupError ? e.reason : "offline");
      }
    },
    // The example fields are only written now, never read, so they are not
    // dependencies — a click always replaces both halves together.
    [term, fromLang, toLang, t, toast],
  );

  const translateLabel =
    lookupState === "loading"
      ? t("words.translating")
      : lookupState === "error"
        ? t("words.retranslate")
        : t("words.translate");

  /**
   * The reverse direction: a gloss the user typed becomes the query, and the
   * word comes back.
   *
   * This is what makes a Japanese wordbook usable the way people actually fill
   * one in — you know "苹果" and you want "りんご", so typing the meaning first
   * is the natural order. The pair is simply swapped: meaning language → the
   * list's learning language.
   *
   * It runs only when asked. A word already typed is the user's decision, but
   * because nothing calls this in the background any more, a click is
   * unambiguously an instruction to overwrite it with what the dictionary found.
   */
  const runReverse = useCallback(
    async () => {
      const query = definition.trim();
      if (!query) return;
      reverseAbortRef.current?.abort();
      const controller = new AbortController();
      reverseAbortRef.current = controller;

      setReverseState("loading");
      setReverseError(null);
      try {
        // Swapped on purpose: the gloss is written in the list's *meaning*
        // language, and the word we want is in its *learning* language.
        //
        // The chain order matters here in a way it does not for the forward
        // pass. Youdao translates *out of* Chinese as machine translation and
        // renders a bare noun as a polite sentence — `苹果` comes back
        // `りんごです`, which is not a word anyone would add to a wordbook.
        // Google returns the lemma (`りんご`) and MyMemory returns `リンゴ`;
        // both are usable, so Youdao is pushed behind them.
        const result = await lookupTerm(query, {
          from: toLang,
          to: fromLang,
          force: true,
          prefer: ["google", "mymemory"],
          signal: controller.signal,
        });
        if (controller.signal.aborted) return;

        const found = primaryMeaning(result).trim();
        if (!found) {
          setReverseState("idle");
          return;
        }
        setTerm(found);
        setError("");
        setLookupState("idle");
        setLookupError(null);
        setReverseState("idle");
        if (!result.fromCache) toast(t("words.reverseApplied"), "ok");
      } catch (e) {
        if (controller.signal.aborted) return;
        setReverseState("error");
        setReverseError(e instanceof LookupError ? e.reason : "offline");
      }
    },
    [definition, fromLang, toLang, t, toast],
  );

  const reverseLabel =
    reverseState === "loading" ? t("words.translating") : t("words.reverseTranslate");

  const reverseErrorText =
    reverseError === "rate-limited"
      ? t("words.translationRateLimited")
      : reverseError === "offline"
        ? t("words.translationOffline")
        : reverseError === "not-found"
          ? t("words.translationNotFound")
          : t("words.translationFailed");

  const errorText =
    lookupError === "rate-limited"
      ? t("words.translationRateLimited")
      : lookupError === "offline"
        ? t("words.translationOffline")
        : lookupError === "not-found"
          ? t("words.translationNotFound")
          : t("words.translationFailed");

  const save = () => {
    abortRef.current?.abort();
    if (!trimmed) {
      setError(t("words.termRequired"));
      return;
    }
    if (word) {
      updateWord(word.id, {
        term: trimmed,
        phonetic: phonetic.trim(),
        pos: pos.trim() || undefined,
        definition: definition.trim(),
        definition2: definition2.trim(),
        example: example.trim(),
        exampleZh: exampleZh.trim(),
        note: note.trim(),
        listId,
        status,
        favorite,
      });
      toast(t("words.wordUpdated"), "ok");
    } else {
      addWord({
        term: trimmed,
        phonetic: phonetic.trim(),
        pos: pos.trim() || undefined,
        definition,
        definition2,
        example,
        exampleZh,
        note,
        listId,
        status,
      });
      toast(t("words.wordAdded", { term: trimmed }), "ok");
    }
    onClose();
  };

  // Cmd/Ctrl+Enter saves from anywhere in the dialog.
  const onKeyDown = (e: React.KeyboardEvent) => {
    if ((e.metaKey || e.ctrlKey) && e.key === "Enter") {
      e.preventDefault();
      save();
    }
  };

  return (
    <Modal
      open={open}
      onClose={requestClose}
      width={620}
      title={word ? t("words.editWord") : t("words.addWord")}
      subtitle={word ? word.term : t("words.subtitle")}
      footer={
        dismissOpen ? (
          <>
            <span className="tiny muted" style={{ marginRight: "auto" }}>
              {t("words.discardConfirm")}
            </span>
            <button
              className="btn btn-sm"
              type="button"
              onClick={() => setDismissOpen(false)}
            >
              {t("words.keepEditing")}
            </button>
            <button
              className="btn btn-danger btn-sm"
              type="button"
              onClick={() => {
                setDismissOpen(false);
                onClose();
              }}
            >
              {t("words.discardChanges")}
            </button>
          </>
        ) : (
          <>
            {word && (
              <button
                className={favorite ? "btn btn-sm" : "btn btn-sm btn-quiet"}
                type="button"
                aria-pressed={favorite}
                onClick={() => setFavorite((v) => !v)}
                title={t("common.favorite")}
              >
                <Icon name={favorite ? "star-filled" : "star"} size={14} />
                {t("common.favorite")}
              </button>
            )}
            {word && (
              <button
                className="btn btn-danger btn-sm"
                type="button"
                onClick={() => {
                  onClose();
                  onDelete(word);
                }}
                style={{ marginRight: "auto" }}
              >
                <Icon name="trash" size={14} />
                {t("common.delete")}
              </button>
            )}
            <button className="btn" type="button" onClick={requestClose}>
              {t("common.cancel")}
            </button>
            <button className="btn btn-primary" type="button" onClick={save}>
              <Icon name="check" size={15} />
              {t("common.save")}
            </button>
          </>
        )
      }
    >
      <div className="stack" style={{ gap: "var(--sp-4)" }} onKeyDown={onKeyDown}>
        <div className="field">
          <div
            className="row-flex"
            style={{ justifyContent: "space-between", gap: "var(--sp-2)", alignItems: "center" }}
          >
            <label className="label" htmlFor="word-term">
              {t("words.term")}
            </label>
            {/* The other half of the pair. Sits on the term field because that
                is the field it fills, and stays disabled until there is a
                meaning to search with. */}
            <button
              className="btn btn-quiet btn-sm"
              type="button"
              onClick={() => void runReverse()}
              disabled={reverseState === "loading" || !definition.trim()}
              title={t("words.reverseHint")}
            >
              <Icon name={reverseState === "loading" ? "refresh" : "undo"} size={13} />
              {reverseLabel}
            </button>
          </div>
          <input
            id="word-term"
            className="input"
            style={{ fontSize: "var(--fs-md)" }}
            value={term}
            onChange={(e) => {
              setTerm(e.target.value);
              setError("");
              setLookupState("idle");
              setLookupError(null);
              setPhonetic("");
            }}
            onKeyDown={(e) => {
              // Enter moves on to the meaning instead of saving. Ctrl/⌘+Enter
              // still saves from anywhere.
              if (e.key === "Enter" && !e.metaKey && !e.ctrlKey) {
                e.preventDefault();
                if (!trimmed) {
                  save();
                  return;
                }
                document.getElementById("word-def")?.focus();
              }
            }}
            placeholder={t("words.termPlaceholder")}
            autoComplete="off"
            spellCheck={false}
            autoFocus
          />
          {phonetic && (
            <span className="hint mono">
              /{phonetic}/ {t("words.phonetic")}
            </span>
          )}
          {error && (
            <span className="hint" style={{ color: "var(--danger)" }}>
              {error}
            </span>
          )}
        </div>

        <div className="field-row">
          <div className="field">
            <div className="row-flex" style={{ justifyContent: "space-between", gap: "var(--sp-2)" }}>
              <label className="label" htmlFor="word-def">
                {t("common.definition")}
              </label>
              <div className="row-flex" style={{ gap: "var(--sp-2)", alignItems: "center" }}>
                <span className="hint" title={t("words.translateHint")}>
                  {pairLabel}
                </span>
                <button
                  className="btn btn-quiet btn-sm"
                  type="button"
                  onClick={() => void runLookup()}
                  disabled={lookupState === "loading" || !trimmed}
                  title={t("words.translateHint")}
                >
                  <Icon name={lookupState === "loading" ? "refresh" : "sparkles"} size={13} />
                  {translateLabel}
                </button>
              </div>
            </div>
            <div className="row-flex" style={{ gap: "var(--sp-2)", alignItems: "flex-start" }}>
              {/*
                The tag sits to the left of the gloss because that is how it is
                read on a card and in the list — a label, not part of the text.
                Keeping it in its own field is what stops "adj." from ending up
                inside the definition the user has to type around.
              */}
              <input
                id="word-pos"
                className="input pos-input"
                value={pos}
                onChange={(e) => setPos(e.target.value)}
                placeholder={t("words.posPlaceholder")}
                aria-label={t("common.pos")}
                autoComplete="off"
                spellCheck={false}
              />
              <input
                id="word-def"
                className="input"
                style={{ flex: 1, minWidth: 0 }}
                value={definition}
                onChange={(e) => {
                  setDefinition(e.target.value);
                  setReverseState("idle");
                  setReverseError(null);
                }}
                placeholder={t("words.definitionPlaceholder")}
              />
            </div>
            {lookupState === "error" && (
              <span className="hint" style={{ color: "var(--warn)" }}>
                {errorText}
              </span>
            )}
            {reverseState === "error" && (
              <span className="hint" style={{ color: "var(--warn)" }}>
                {reverseErrorText}
              </span>
            )}
          </div>

          <div className="field">
            <label className="label" htmlFor="word-def2">
              {t("common.definition2")}
              <span className="muted tiny" style={{ marginLeft: "var(--sp-2)", fontWeight: 400 }}>
                {t("common.optional")}
              </span>
            </label>
            <input
              id="word-def2"
              className="input"
              value={definition2}
              onChange={(e) => setDefinition2(e.target.value)}
              placeholder={t("words.definition2Placeholder")}
            />
          </div>
        </div>

        {showDuplicate && (
          <div className="notice">
            <span className="notice-ico">
              <Icon name="alert" size={15} />
            </span>
            <span>{t("words.duplicate")}</span>
          </div>
        )}

        <div className="field">
          <label className="label" htmlFor="word-example">
            {t("common.example")}
            <span className="muted tiny" style={{ marginLeft: "var(--sp-2)", fontWeight: 400 }}>
              {t("common.optional")}
            </span>
          </label>
          <textarea
            id="word-example"
            className="textarea"
            rows={2}
            value={example}
            onChange={(e) => setExample(e.target.value)}
            placeholder={t("words.examplePlaceholder")}
          />
          {/*
            Only offered once there is a sentence to translate. Keyed off the
            typed value rather than the stored one so pasting a sentence
            immediately reveals the field.
          */}
          {example.trim() !== "" && (
            <input
              id="word-example-zh"
              className="input"
              style={{ marginTop: "var(--sp-2)" }}
              value={exampleZh}
              onChange={(e) => setExampleZh(e.target.value)}
              placeholder={t("words.exampleZhPlaceholder")}
            />
          )}
        </div>

        <div className="field">
          <label className="label" htmlFor="word-note">
            {t("common.notes")}
            <span className="muted tiny" style={{ marginLeft: "var(--sp-2)", fontWeight: 400 }}>
              {t("common.optional")}
            </span>
          </label>
          <textarea
            id="word-note"
            className="textarea"
            rows={2}
            value={note}
            onChange={(e) => setNote(e.target.value)}
            placeholder={t("words.notePlaceholder")}
          />
        </div>

        <div className="field-row">
          <div className="field">
            <label className="label" htmlFor="word-list">
              {t("common.list")}
            </label>
            <select
              id="word-list"
              className="select"
              value={listId}
              onChange={(e) => setListId(e.target.value)}
            >
              {data.lists.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label className="label" htmlFor="word-status">
              {t("common.status")}
            </label>
            <select
              id="word-status"
              className="select"
              value={status}
              onChange={(e) => setStatus(e.target.value as WordStatus)}
            >
              {STATUS_ORDER.map((s) => (
                <option key={s} value={s}>
                  {t(STATUS_LABEL_KEY[s])}
                </option>
              ))}
            </select>
          </div>
        </div>

        <div className="tiny muted">
          <span className="kbd">Enter</span> {t("words.enterNext")}，
          <span className="kbd">Ctrl</span>+<span className="kbd">Enter</span>{" "}
          {t("words.saveAnywhere")}，<span className="kbd">Esc</span> {t("common.cancel")}
        </div>
      </div>
    </Modal>
  );
}
