/** Add / edit a single word. Owns its draft state; commits through the store. */
import { useCallback, useEffect, useRef, useState } from "react";
import { Icon } from "@/components/Icon";
import { Modal, TagInput, useToast } from "@/components/ui";
import { useT } from "@/i18n";
import { addWord, findDuplicate, updateWord, useAppData } from "@/lib/store";
import {
  LookupError,
  alternativeMeaning,
  lookupTerm,
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
  const [definition, setDefinition] = useState("");
  const [definition2, setDefinition2] = useState("");
  const [example, setExample] = useState("");
  const [note, setNote] = useState("");
  const [tags, setTags] = useState<string[]>([]);
  const [listId, setListId] = useState(defaultListId);
  const [status, setStatus] = useState<WordStatus>("new");
  const [favorite, setFavorite] = useState(false);
  const [error, setError] = useState("");
  const [dismissOpen, setDismissOpen] = useState(false);

  const [lookupState, setLookupState] = useState<LookupState>("idle");
  const [lookupError, setLookupError] = useState<LookupFailure | null>(null);
  const [phonetic, setPhonetic] = useState("");
  const abortRef = useRef<AbortController | null>(null);

  useEffect(() => {
    if (!open) {
      abortRef.current?.abort();
      return;
    }
    setError("");
    setDismissOpen(false);
    setLookupState("idle");
    setLookupError(null);
    setPhonetic(word?.phonetic ?? "");
    if (word) {
      setTerm(word.term);
      setDefinition(word.definition);
      setDefinition2(word.definition2);
      setExample(word.example);
      setNote(word.note);
      setTags(word.tags);
      setListId(word.listId);
      setStatus(word.status);
      setFavorite(word.favorite);
    } else {
      setTerm("");
      setDefinition("");
      setDefinition2("");
      setExample("");
      setNote("");
      setTags([]);
      setListId(defaultListId);
      setStatus("new");
      setFavorite(false);
    }
  }, [open, word, defaultListId]);

  // Drop any in-flight request when the dialog unmounts.
  useEffect(() => () => abortRef.current?.abort(), []);

  const list = data.lists.find((l) => l.id === listId) ?? data.lists[0];
  const fromLang = list?.sourceLang ?? "en";
  const toLang = list?.targetLang ?? "zh-CN";

  const trimmed = term.trim();
  const duplicate = trimmed ? findDuplicate(data, trimmed, listId) : undefined;
  const showDuplicate = Boolean(duplicate && duplicate.id !== word?.id);

  // A draft is dirty when any field differs from what was loaded. The create
  // baseline is all-empty, so a fetched translation counts too — closing after
  // auto-translate must not throw the word away without asking.
  const dirty =
    term !== (word?.term ?? "") ||
    phonetic !== (word?.phonetic ?? "") ||
    definition !== (word?.definition ?? "") ||
    definition2 !== (word?.definition2 ?? "") ||
    example !== (word?.example ?? "") ||
    note !== (word?.note ?? "") ||
    tags.join("\u0000") !== (word?.tags ?? []).join("\u0000") ||
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
   * Look the term up and fill the empty fields.
   *
   * `force` is the "翻译" button: it overwrites what is already there and
   * bypasses the cache. The automatic pass only ever fills blanks, so a user
   * who typed their own wording never loses it to a background request.
   */
  const runLookup = useCallback(
    async (force: boolean) => {
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
          force,
          signal: controller.signal,
        });
        if (controller.signal.aborted) return;

        const primary = primaryMeaning(result);
        const secondary = alternativeMeaning(result);
        if (primary) {
          setDefinition((prev) => (force || !prev.trim() ? primary : prev));
        }
        if (secondary) {
          setDefinition2((prev) => (force || !prev.trim() ? secondary : prev));
        }
        const firstExample = result.examples[0]?.en;
        if (firstExample) {
          setExample((prev) => (force || !prev.trim() ? firstExample : prev));
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
    [term, fromLang, toLang, t, toast],
  );

  const translateLabel =
    lookupState === "loading"
      ? t("words.translating")
      : lookupState === "error"
        ? t("words.retranslate")
        : t("words.translate");

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
        definition: definition.trim(),
        definition2: definition2.trim(),
        example: example.trim(),
        note: note.trim(),
        tags,
        listId,
        status,
        favorite,
      });
      toast(t("words.wordUpdated"), "ok");
    } else {
      addWord({
        term: trimmed,
        phonetic: phonetic.trim(),
        definition,
        definition2,
        example,
        note,
        tags,
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
          <label className="label" htmlFor="word-term">
            {t("words.term")}
          </label>
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
            onBlur={() => {
              // Automatic pass: only in create mode, only into blank fields.
              if (!word && data.settings.autoTranslate && trimmed && !definition.trim()) {
                void runLookup(false);
              }
            }}
            onKeyDown={(e) => {
              // Enter moves on to the meaning instead of saving. Saving from
              // here used to abort the blur-triggered lookup, so the flagship
              // auto-translate never got to run. Ctrl/⌘+Enter still saves.
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
              /{phonetic}/ · {t("words.phonetic")}
            </span>
          )}
          {error && (
            <span className="hint" style={{ color: "var(--rose)" }}>
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
              <button
                className="btn btn-quiet btn-sm"
                type="button"
                onClick={() => void runLookup(true)}
                disabled={lookupState === "loading" || !trimmed}
                title={t("words.translateHint")}
              >
                <Icon name={lookupState === "loading" ? "refresh" : "sparkles"} size={13} />
                {translateLabel}
              </button>
            </div>
            <input
              id="word-def"
              className="input"
              value={definition}
              onChange={(e) => setDefinition(e.target.value)}
              placeholder={t("words.definitionPlaceholder")}
            />
            {lookupState === "error" && (
              <span className="hint" style={{ color: "var(--amber)" }}>
                {errorText}
              </span>
            )}
          </div>

          <div className="field">
            <label className="label" htmlFor="word-def2">
              {t("common.definition2")}
              <span className="muted tiny" style={{ marginLeft: 6, fontWeight: 400 }}>
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
            <span className="muted tiny" style={{ marginLeft: 6, fontWeight: 400 }}>
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
        </div>

        <div className="field">
          <label className="label" htmlFor="word-note">
            {t("common.notes")}
            <span className="muted tiny" style={{ marginLeft: 6, fontWeight: 400 }}>
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

        <div className="field">
          <span className="label">{t("common.tags")}</span>
          <TagInput
            value={tags}
            onChange={setTags}
            placeholder={t("words.tagsPlaceholder")}
            hint={t("words.tagsHint")}
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
          <span className="kbd">Enter</span> {t("words.enterNext")} ·{" "}
          <span className="kbd">Ctrl</span>+<span className="kbd">Enter</span>{" "}
          {t("words.saveAnywhere")} · <span className="kbd">Esc</span> {t("common.cancel")}
        </div>
      </div>
    </Modal>
  );
}
