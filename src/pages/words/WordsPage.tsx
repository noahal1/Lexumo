/**
 * 词库页：词库切换、搜索、状态/标签筛选、排序、增删改、发音与收藏。
 */
import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Icon } from "@/components/Icon";
import {
  ConfirmDialog,
  EmptyState,
  Modal,
  PageShell,
  Segmented,
  StatusChip,
  useToast,
} from "@/components/ui";
import { useLang, useT } from "@/i18n";
import { LANGUAGES, langName } from "@/lib/languages";
import {
  bumpListen,
  createList,
  deleteList,
  deleteWord,
  dueWords,
  renameList,
  toggleFavorite,
  useAppData,
  useSettings,
  wordsOfList,
} from "@/lib/store";
import { speak } from "@/lib/tts";
import {
  STATUS_LABEL_KEY,
  STATUS_ORDER,
  type AppData,
  type Word,
  type WordList,
  type WordStatus,
} from "@/lib/types";
import { cx, relativeDay } from "@/lib/utils";
import { WordEditor } from "./WordEditor";

type StatusFilter = "all" | WordStatus;
type SortKey = "recent" | "alpha" | "due" | "status";

const STATUS_RANK: Record<WordStatus, number> = {
  new: 0,
  reviewing: 1,
  learning: 2,
  mastered: 3,
};

/** Wraps every case-insensitive match of `q` in a <mark> so hits are scannable. */
function highlight(text: string, q: string): ReactNode {
  if (!q) return text;
  const lower = text.toLocaleLowerCase();
  const needle = q.toLocaleLowerCase();
  const out: ReactNode[] = [];
  let from = 0;
  let at = lower.indexOf(needle);
  let key = 0;
  while (at !== -1) {
    if (at > from) out.push(text.slice(from, at));
    out.push(<mark key={key++}>{text.slice(at, at + needle.length)}</mark>);
    from = at + needle.length;
    at = lower.indexOf(needle, from);
  }
  if (from < text.length) out.push(text.slice(from));
  return out;
}

export function WordsPage() {
  const t = useT();
  const lang = useLang();
  const toast = useToast();
  const data = useAppData();
  const settings = useSettings();

  const [listId, setListId] = useState<string>(data.lists[0]?.id ?? "");
  const [query, setQuery] = useState("");
  const [statusFilter, setStatusFilter] = useState<StatusFilter>("all");
  const [tagFilter, setTagFilter] = useState("all");
  const [sort, setSort] = useState<SortKey>("recent");
  const [favOnly, setFavOnly] = useState(false);

  const [editorOpen, setEditorOpen] = useState(false);
  const [editing, setEditing] = useState<Word | null>(null);
  const [pendingDelete, setPendingDelete] = useState<Word | null>(null);
  const [listMgrOpen, setListMgrOpen] = useState(false);

  const searchRef = useRef<HTMLInputElement>(null);

  // Keep the selection valid if the active list disappears.
  useEffect(() => {
    if (data.lists.length === 0) return;
    if (!data.lists.some((l) => l.id === listId)) setListId(data.lists[0].id);
  }, [data.lists, listId]);

  const listWords = useMemo(() => wordsOfList(data, listId), [data, listId]);

  const counts = useMemo(() => {
    const base: Record<StatusFilter, number> = {
      all: listWords.length,
      new: 0,
      reviewing: 0,
      learning: 0,
      mastered: 0,
    };
    for (const w of listWords) base[w.status] += 1;
    return base;
  }, [listWords]);

  const tags = useMemo(() => {
    const set = new Map<string, number>();
    for (const w of data.words) {
      for (const tag of w.tags) set.set(tag, (set.get(tag) ?? 0) + 1);
    }
    return [...set.entries()].sort((a, b) => b[1] - a[1]).map(([tag]) => tag);
  }, [data.words]);

  const trimmedQuery = query.trim();

  const filtered = useMemo(() => {
    const q = trimmedQuery.toLocaleLowerCase();
    let out = listWords;
    if (q) {
      out = out.filter(
        (w) =>
          w.term.toLocaleLowerCase().includes(q) ||
          w.definition.toLocaleLowerCase().includes(q) ||
          w.definition2.toLocaleLowerCase().includes(q) ||
          w.note.toLocaleLowerCase().includes(q) ||
          w.tags.some((tag) => tag.toLocaleLowerCase().includes(q)),
      );
    }
    if (statusFilter !== "all") out = out.filter((w) => w.status === statusFilter);
    if (tagFilter !== "all") out = out.filter((w) => w.tags.includes(tagFilter));
    if (favOnly) out = out.filter((w) => w.favorite);

    const sorted = out.slice();
    switch (sort) {
      case "alpha":
        sorted.sort((a, b) => a.term.localeCompare(b.term, lang));
        break;
      case "due":
        sorted.sort((a, b) => {
          const da = a.srs?.dueAt ?? 0;
          const db = b.srs?.dueAt ?? 0;
          return da - db || STATUS_RANK[a.status] - STATUS_RANK[b.status];
        });
        break;
      case "status":
        sorted.sort(
          (a, b) =>
            STATUS_RANK[a.status] - STATUS_RANK[b.status] ||
            a.term.localeCompare(b.term, lang),
        );
        break;
      default:
        sorted.sort((a, b) => b.createdAt - a.createdAt);
        break;
    }
    return sorted;
  }, [listWords, trimmedQuery, statusFilter, tagFilter, favOnly, sort, lang]);

  const dueCount = useMemo(() => dueWords(data).length, [data]);
  const filtersActive =
    Boolean(trimmedQuery) || statusFilter !== "all" || tagFilter !== "all" || favOnly;

  const resetFilters = () => {
    setQuery("");
    setStatusFilter("all");
    setTagFilter("all");
    setFavOnly(false);
  };

  const openCreate = () => {
    setEditing(null);
    setEditorOpen(true);
  };

  const openEdit = (word: Word) => {
    setEditing(word);
    setEditorOpen(true);
  };

  const play = (word: Word) => {
    speak(word.term, {
      lang: word.sourceLang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI,
    });
    bumpListen(word.id);
  };

  // Keyboard: "/" focuses search, "n" creates a word.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null;
      const typing =
        el &&
        (el.tagName === "INPUT" ||
          el.tagName === "TEXTAREA" ||
          el.tagName === "SELECT" ||
          el.isContentEditable);
      if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
      if (editorOpen || listMgrOpen || pendingDelete) return;
      if (e.key === "/") {
        e.preventDefault();
        searchRef.current?.focus();
      } else if (e.key === "n" || e.key === "N") {
        e.preventDefault();
        openCreate();
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [editorOpen, listMgrOpen, pendingDelete]);

  const statusOptions: Array<{ value: StatusFilter; label: string; count: number }> = [
    { value: "all", label: t("common.all"), count: counts.all },
    ...STATUS_ORDER.map((s) => ({
      value: s as StatusFilter,
      label: t(STATUS_LABEL_KEY[s]),
      count: counts[s],
    })),
  ];

  return (
    <PageShell
      title={t("words.title")}
      subtitle={`${listWords.length} ${t("common.words")} · ${t("words.dueToday")} ${dueCount}`}
      actions={
        <>
          <button
            className="btn btn-ghost btn-sm"
            type="button"
            onClick={() => setListMgrOpen(true)}
          >
            <Icon name="layers" size={15} />
            {t("common.list")}
          </button>
          <button className="btn btn-primary" type="button" onClick={openCreate}>
            <Icon name="plus" size={16} />
            {t("words.addWord")}
          </button>
        </>
      }
    >
      {/* List tabs */}
      <div className="list-tabs" style={{ marginBottom: "var(--sp-4)" }}>
        {data.lists.map((l) => {
          const active = l.id === listId;
          return (
            <button
              key={l.id}
              type="button"
              onClick={() => setListId(l.id)}
              className={cx("list-tab", active && "active")}
              aria-pressed={active}
            >
              {l.name}
              <span className="count">{wordsOfList(data, l.id).length}</span>
            </button>
          );
        })}
        <button
          type="button"
          className="list-tab-add"
          onClick={() => setListMgrOpen(true)}
          title={t("words.newList")}
          aria-label={t("words.newList")}
        >
          <Icon name="plus" size={14} />
        </button>
      </div>

      {/* Toolbar */}
      <div className="toolbar" style={{ marginBottom: "var(--sp-4)" }}>
        <div className="search">
          <span className="search-icon">
            <Icon name="search" size={15} />
          </span>
          <input
            ref={searchRef}
            className="input"
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t("words.searchPlaceholder")}
            aria-label={t("common.search")}
            onKeyDown={(e) => {
              if (e.key === "Escape" && query) {
                e.preventDefault();
                setQuery("");
              }
            }}
          />
          {query && (
            <button
              className="search-clear"
              type="button"
              onClick={() => {
                setQuery("");
                searchRef.current?.focus();
              }}
              aria-label={t("common.clear")}
            >
              <Icon name="x" size={13} />
            </button>
          )}
        </div>

        <Segmented
          value={statusFilter}
          options={statusOptions}
          onChange={setStatusFilter}
          ariaLabel={t("words.filterStatus")}
        />

        <select
          className="select"
          value={tagFilter}
          onChange={(e) => setTagFilter(e.target.value)}
          aria-label={t("words.filterTag")}
          style={{ minWidth: 118 }}
        >
          <option value="all">{t("common.all")}</option>
          {tags.map((tag) => (
            <option key={tag} value={tag}>
              #{tag}
            </option>
          ))}
        </select>

        <select
          className="select"
          value={sort}
          onChange={(e) => setSort(e.target.value as SortKey)}
          aria-label={t("common.sort")}
          style={{ minWidth: 128 }}
        >
          <option value="recent">{t("words.sortRecent")}</option>
          <option value="alpha">{t("words.sortAlpha")}</option>
          <option value="due">{t("words.sortDue")}</option>
          <option value="status">{t("words.sortStatus")}</option>
        </select>

        <button
          type="button"
          className={cx("btn btn-icon", favOnly && "btn-primary")}
          onClick={() => setFavOnly((v) => !v)}
          title={t("words.filterFavorites")}
          aria-pressed={favOnly}
        >
          <Icon name={favOnly ? "star-filled" : "star"} size={16} />
        </button>

        {filtersActive && (
          <button type="button" className="btn btn-quiet btn-sm" onClick={resetFilters}>
            <Icon name="x" size={14} />
            {t("common.reset")}
          </button>
        )}
      </div>

      {/* Word list */}
      {listWords.length === 0 ? (
        <EmptyState
          icon="words"
          title={t("words.noWords")}
          text={t("words.noWordsHint")}
          action={
            <button className="btn btn-primary" type="button" onClick={openCreate}>
              <Icon name="plus" size={16} />
              {t("words.addFirst")}
            </button>
          }
        />
      ) : filtered.length === 0 ? (
        <EmptyState
          icon="search"
          title={t("words.noResults")}
          text={t("words.noResultsHint")}
          action={
            <button className="btn" type="button" onClick={resetFilters}>
              {t("common.reset")}
            </button>
          }
        />
      ) : (
        <div className="card card-flush rise">
          <div className="list">
            <div className="row row-words row-head">
              <span>{t("words.term")}</span>
              <span className="row-col-def">{t("common.definition")}</span>
              <span className="row-col-status">{t("common.status")}</span>
              <span style={{ textAlign: "right" }}>{t("common.actions")}</span>
            </div>
            {filtered.map((w) => (
              <div
                key={w.id}
                className="row row-words"
                onClick={() => openEdit(w)}
                role="button"
                tabIndex={0}
                onKeyDown={(e) => {
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    openEdit(w);
                  }
                }}
              >
                <div className="row-flex" style={{ minWidth: 0, gap: 7 }}>
                  {w.favorite && (
                    <span className="row-fav" aria-hidden="true">
                      <Icon name="star-filled" size={13} />
                    </span>
                  )}
                  <span className="row-term">{highlight(w.term, trimmedQuery)}</span>
                </div>

                <div className="row-col-def" style={{ minWidth: 0 }}>
                  <div className="row-def">
                    {w.definition
                      ? highlight(w.definition, trimmedQuery)
                      : t("words.noDefinition")}
                  </div>
                  {w.tags.length > 0 && (
                    <div className="row-tags">
                      {w.tags.map((tag) => `#${tag}`).join("  ")}
                    </div>
                  )}
                </div>

                <div
                  className="row-col-status"
                  style={{ display: "flex", flexDirection: "column", gap: 3, minWidth: 0 }}
                >
                  <StatusChip status={w.status} label={t(STATUS_LABEL_KEY[w.status])} />
                  <span className="tiny muted">
                    {w.srs ? relativeDay(w.srs.dueAt, lang) : t("words.neverReviewed")}
                  </span>
                </div>

                <div className="row-actions" onClick={(e) => e.stopPropagation()}>
                  <button
                    className="btn btn-icon btn-sm"
                    type="button"
                    title={t("common.favorite")}
                    aria-label={t("common.favorite")}
                    aria-pressed={w.favorite}
                    onClick={() => toggleFavorite(w.id)}
                  >
                    <Icon name={w.favorite ? "star-filled" : "star"} size={15} />
                  </button>
                  <button
                    className="btn btn-icon btn-sm"
                    type="button"
                    title={t("words.listens", { n: w.listenCount })}
                    aria-label={t("common.play")}
                    onClick={() => play(w)}
                  >
                    <Icon name="volume" size={15} />
                  </button>
                  <button
                    className="btn btn-icon btn-sm"
                    type="button"
                    title={t("common.edit")}
                    aria-label={t("common.edit")}
                    onClick={() => openEdit(w)}
                  >
                    <Icon name="edit" size={15} />
                  </button>
                  <button
                    className="btn btn-icon btn-sm"
                    type="button"
                    title={t("common.delete")}
                    aria-label={t("common.delete")}
                    onClick={() => setPendingDelete(w)}
                  >
                    <Icon name="trash" size={15} />
                  </button>
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      {filtered.length > 0 && (
        <div className="row-flex tiny muted" style={{ marginTop: "var(--sp-4)", gap: 6 }}>
          <span>
            {t("common.total")} {filtered.length}
            {filtered.length !== listWords.length ? ` / ${listWords.length}` : ""}
          </span>
          <span aria-hidden="true">·</span>
          <span>
            <span className="kbd">/</span> {t("common.search")}
          </span>
          <span>
            <span className="kbd">n</span> {t("words.addWord")}
          </span>
        </div>
      )}

      <WordEditor
        open={editorOpen}
        word={editing}
        defaultListId={listId}
        onClose={() => setEditorOpen(false)}
        onDelete={(word) => setPendingDelete(word)}
      />

      <ConfirmDialog
        open={Boolean(pendingDelete)}
        title={t("words.deleteConfirm")}
        body={
          pendingDelete
            ? t("words.deleteConfirmBody", { term: pendingDelete.term })
            : undefined
        }
        confirmLabel={t("common.delete")}
        cancelLabel={t("common.cancel")}
        onCancel={() => setPendingDelete(null)}
        onConfirm={() => {
          if (pendingDelete) {
            deleteWord(pendingDelete.id);
            toast(t("words.wordDeleted"), "ok");
          }
          setPendingDelete(null);
        }}
      />

      <ListManagerModal
        open={listMgrOpen}
        onClose={() => setListMgrOpen(false)}
        data={data}
        activeId={listId}
        onSelect={setListId}
      />
    </PageShell>
  );
}

/* ------------------------------------------------------------------ */
/* 词库管理                                                            */
/* ------------------------------------------------------------------ */
function ListManagerModal({
  open,
  onClose,
  data,
  activeId,
  onSelect,
}: {
  open: boolean;
  onClose: () => void;
  data: AppData;
  activeId: string;
  onSelect: (id: string) => void;
}) {
  const t = useT();
  const toast = useToast();
  const [creating, setCreating] = useState(false);
  const [name, setName] = useState("");
  const [sourceLang, setSourceLang] = useState("en");
  const [targetLang, setTargetLang] = useState("zh-CN");
  const [renamingId, setRenamingId] = useState<string | null>(null);
  const [renameDraft, setRenameDraft] = useState("");
  const [pendingDelete, setPendingDelete] = useState<WordList | null>(null);

  useEffect(() => {
    if (!open) {
      setCreating(false);
      setName("");
      setRenamingId(null);
    }
  }, [open]);

  const submitCreate = () => {
    const trimmed = name.trim();
    if (!trimmed) return;
    const list = createList({ name: trimmed, sourceLang, targetLang });
    onSelect(list.id);
    setName("");
    setCreating(false);
    toast(t("words.newList"), "ok");
  };

  return (
    <Modal
      open={open}
      onClose={onClose}
      width={560}
      title={t("common.list")}
      subtitle={`${data.lists.length} 个词库`}
      footer={
        <>
          <button className="btn" type="button" onClick={onClose}>
            {t("common.close")}
          </button>
          <button className="btn btn-primary" type="button" onClick={() => setCreating((v) => !v)}>
            <Icon name="plus" size={15} />
            {t("words.newList")}
          </button>
        </>
      }
    >
      <div className="stack" style={{ gap: "var(--sp-4)" }}>
        {creating && (
          <div className="card card-pad rise" style={{ background: "var(--surface-2)" }}>
            <div className="stack" style={{ gap: "var(--sp-3)" }}>
              <div className="field">
                <label className="label" htmlFor="new-list-name">
                  {t("words.listName")}
                </label>
                <input
                  id="new-list-name"
                  className="input"
                  value={name}
                  onChange={(e) => setName(e.target.value)}
                  placeholder={t("words.listName")}
                  onKeyDown={(e) => {
                    if (e.key === "Enter") submitCreate();
                  }}
                  autoFocus
                />
              </div>
              <div className="field-row">
                <div className="field">
                  <span className="label">{t("words.sourceLang")}</span>
                  <select
                    className="select"
                    value={sourceLang}
                    onChange={(e) => setSourceLang(e.target.value)}
                  >
                    {LANGUAGES.map((l) => (
                      <option key={l.code} value={l.code}>
                        {langName(l.code, "zh-CN")}
                      </option>
                    ))}
                  </select>
                </div>
                <div className="field">
                  <span className="label">{t("words.targetLang")}</span>
                  <select
                    className="select"
                    value={targetLang}
                    onChange={(e) => setTargetLang(e.target.value)}
                  >
                    {LANGUAGES.map((l) => (
                      <option key={l.code} value={l.code}>
                        {langName(l.code, "zh-CN")}
                      </option>
                    ))}
                  </select>
                </div>
              </div>
              <div className="row-flex" style={{ justifyContent: "flex-end" }}>
                <button className="btn btn-sm" type="button" onClick={() => setCreating(false)}>
                  {t("common.cancel")}
                </button>
                <button
                  className="btn btn-primary btn-sm"
                  type="button"
                  onClick={submitCreate}
                  disabled={!name.trim()}
                >
                  {t("common.create")}
                </button>
              </div>
            </div>
          </div>
        )}

        <div className="list">
          {data.lists.map((l) => {
            const count = data.words.filter((w) => w.listId === l.id).length;
            const active = l.id === activeId;
            const renaming = renamingId === l.id;
            return (
              <div
                key={l.id}
                className="row row-pair"
                onClick={() => {
                  onSelect(l.id);
                  onClose();
                }}
              >
                <div style={{ minWidth: 0 }}>
                  {renaming ? (
                    <input
                      className="input"
                      value={renameDraft}
                      autoFocus
                      onClick={(e) => e.stopPropagation()}
                      onChange={(e) => setRenameDraft(e.target.value)}
                      onKeyDown={(e) => {
                        e.stopPropagation();
                        if (e.key === "Enter") {
                          renameList(l.id, renameDraft);
                          setRenamingId(null);
                        } else if (e.key === "Escape") {
                          setRenamingId(null);
                        }
                      }}
                      onBlur={() => {
                        renameList(l.id, renameDraft);
                        setRenamingId(null);
                      }}
                    />
                  ) : (
                    <div className="row-flex" style={{ gap: 8, minWidth: 0 }}>
                      <span
                        className="row-term"
                        style={{
                          fontSize: "var(--fs-md)",
                          color: active ? "var(--jade-ink)" : undefined,
                        }}
                      >
                        {l.name}
                      </span>
                      <span className="tiny muted">
                        {count} {t("common.words")} · {langName(l.sourceLang, "zh-CN")} →{" "}
                        {langName(l.targetLang, "zh-CN")}
                      </span>
                    </div>
                  )}
                </div>
                <div className="row-actions" onClick={(e) => e.stopPropagation()}>
                  <button
                    className="btn btn-icon btn-sm"
                    type="button"
                    title={t("common.rename")}
                    aria-label={t("common.rename")}
                    onClick={() => {
                      setRenamingId(l.id);
                      setRenameDraft(l.name);
                    }}
                  >
                    <Icon name="edit" size={15} />
                  </button>
                  <button
                    className="btn btn-icon btn-sm"
                    type="button"
                    title={t("common.delete")}
                    aria-label={t("common.delete")}
                    disabled={data.lists.length <= 1}
                    onClick={() => setPendingDelete(l)}
                  >
                    <Icon name="trash" size={15} />
                  </button>
                </div>
              </div>
            );
          })}
        </div>
      </div>

      <ConfirmDialog
        open={Boolean(pendingDelete)}
        title={t("common.delete")}
        body={
          pendingDelete
            ? `删除词库「${pendingDelete.name}」及其中的 ${data.words.filter((w) => w.listId === pendingDelete.id).length} 个词语？此操作无法撤销。`
            : undefined
        }
        confirmLabel={t("common.delete")}
        cancelLabel={t("common.cancel")}
        onCancel={() => setPendingDelete(null)}
        onConfirm={() => {
          if (pendingDelete) {
            deleteList(pendingDelete.id);
            toast(t("words.wordDeleted"), "ok");
          }
          setPendingDelete(null);
        }}
      />
    </Modal>
  );
}
