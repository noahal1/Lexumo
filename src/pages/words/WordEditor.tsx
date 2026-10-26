/** Add / edit a single word. Owns its draft state; commits through the store. */
import { useEffect, useState } from "react";
import { Modal, TagInput, useToast } from "@/components/ui";
import { useT } from "@/i18n";
import { addWord, findDuplicate, getData, updateWord } from "@/lib/store";
import { STATUS_LABEL_KEY, STATUS_ORDER, type Word, type WordStatus } from "@/lib/types";
import { cx } from "@/lib/utils";

export interface WordEditorProps {
  open: boolean;
  /** null → create mode. */
  word: Word | null;
  defaultListId: string;
  onClose: () => void;
  /** Ask the parent to confirm deletion (editor closes itself first). */
  onDelete: (word: Word) => void;
}

export function WordEditor({ open, word, defaultListId, onClose, onDelete }: WordEditorProps) {
  const t = useT();
  const toast = useToast();
  const data = getData();

  const [term, setTerm] = useState("");
  const [definition, setDefinition] = useState("");
  const [definition2, setDefinition2] = useState("");
  const [example, setExample] = useState("");
  const [note, setNote] = useState("");
  const [tags, setTags] = useState<string[]>([]);
  const [listId, setListId] = useState(defaultListId);
  const [status, setStatus] = useState<WordStatus>("new");
  const [error, setError] = useState("");

  useEffect(() => {
    if (!open) return;
    setError("");
    if (word) {
      setTerm(word.term);
      setDefinition(word.definition);
      setDefinition2(word.definition2);
      setExample(word.example);
      setNote(word.note);
      setTags(word.tags);
      setListId(word.listId);
      setStatus(word.status);
    } else {
      setTerm("");
      setDefinition("");
      setDefinition2("");
      setExample("");
      setNote("");
      setTags([]);
      setListId(defaultListId);
      setStatus("new");
    }
  }, [open, word, defaultListId]);

  const trimmed = term.trim();
  const duplicate = trimmed ? findDuplicate(data, trimmed, listId) : undefined;
  const showDuplicate = Boolean(duplicate && duplicate.id !== word?.id);

  const save = () => {
    if (!trimmed) {
      setError(t("words.termRequired"));
      return;
    }
    if (word) {
      updateWord(word.id, {
        term: trimmed,
        definition: definition.trim(),
        definition2: definition2.trim(),
        example: example.trim(),
        note: note.trim(),
        tags,
        listId,
        status,
      });
      toast(t("words.wordUpdated"), "ok");
    } else {
      addWord({
        term: trimmed,
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

  return (
    <Modal
      open={open}
      onClose={onClose}
      width={620}
      title={word ? t("words.editWord") : t("words.addWord")}
      subtitle={word ? word.term : t("words.subtitle")}
      footer={
        <>
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
              {t("common.delete")}
            </button>
          )}
          <button className="btn" type="button" onClick={onClose}>
            {t("common.cancel")}
          </button>
          <button className="btn btn-primary" type="button" onClick={save}>
            {t("common.save")}
          </button>
        </>
      }
    >
      <div className="stack" style={{ gap: "var(--sp-4)" }}>
        <div className="field">
          <label className="label" htmlFor="word-term">
            {t("words.term")}
          </label>
          <input
            id="word-term"
            className="input"
            value={term}
            onChange={(e) => {
              setTerm(e.target.value);
              setError("");
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter") {
                e.preventDefault();
                save();
              }
            }}
            placeholder={t("words.termPlaceholder")}
            autoComplete="off"
            spellCheck={false}
          />
          {error && <span className="hint" style={{ color: "var(--rose)" }}>{error}</span>}
          {!error && showDuplicate && (
            <span className="hint" style={{ color: "var(--amber)" }}>
              {t("words.duplicate")}
            </span>
          )}
        </div>

        <div className="field">
          <label className="label" htmlFor="word-def">
            {t("common.definition")}
          </label>
          <input
            id="word-def"
            className="input"
            value={definition}
            onChange={(e) => setDefinition(e.target.value)}
            placeholder={t("words.definitionPlaceholder")}
          />
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

        <div className="field">
          <label className="label" htmlFor="word-example">
            {t("common.example")}
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

        <div
          style={{
            display: "grid",
            gridTemplateColumns: "1fr 1fr",
            gap: "var(--sp-4)",
          }}
        >
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
              className={cx("select")}
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
      </div>
    </Modal>
  );
}
