/**
 * 词库页：词库切换、搜索、状态/标签筛选、排序、增删改、发音与收藏。
 */
import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { Icon } from "@/components/Icon";
import {
  ConfirmDialog,
  EmptyState,
  Modal,
  PageShell,
  Segmented,
  StatusChip,
  TagInput,
  useToast,
} from "@/components/ui";
import { useLang, useT } from "@/i18n";
import { LANGUAGES, langName } from "@/lib/languages";
import {
  bumpListen,
  createList,
  deleteList,
  deleteWord,
  deleteWords,
  renameList,
  restoreWord,
  toggleFavorite,
  updateWord,
  useAppData,
  useSettings,
} from "@/lib/store";
import { speak } from "@/lib/tts";
import {
  STATUS_LABEL_KEY,
  STATUS_ORDER,
  type AppData,
  type Word,
  type WordList,
} from "@/lib/types";
import { cx, relativeDay } from "@/lib/utils";
import { SHORTCUTS, useShortcutScope, type KeyEventLike, type ShortcutBinding } from "@/lib/shortcuts";
import {
  buildWordIndex,
  queryWords,
  type SortKey,
  type StatusFilter,
  type WordQuery,
} from "@/lib/wordIndex";
import { WordEditor } from "./WordEditor";

/** Fallbacks for a list id the index has no bucket for yet (no words / no lists). */
const EMPTY_COUNTS: Record<StatusFilter, number> = {
  all: 0,
  new: 0,
  reviewing: 0,
  learning: 0,
  mastered: 0,
};
const NO_TAGS: string[] = [];

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

/* ------------------------------------------------------------------ */
/* Remembered view state                                               */
/* ------------------------------------------------------------------ */
const VIEW_STORAGE_KEY = "lexumo.words.view.v1";
const STATUS_VALUES: readonly StatusFilter[] = [
  "all",
  "new",
  "reviewing",
  "learning",
  "mastered",
];
const SORT_VALUES: readonly SortKey[] = ["recent", "alpha", "due", "status"];

interface SavedView {
  listId?: string;
  status?: StatusFilter;
  sort?: SortKey;
  favoriteOnly?: boolean;
}

/**
 * The list/filter/sort the user last looked at. Reopening the page used to snap
 * back to the first list and "recent", so a one-list-per-topic setup felt like
 * it forgot everything on every visit.
 */
function readSavedView(): SavedView {
  try {
    const raw = localStorage.getItem(VIEW_STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as SavedView;
    return {
      listId: typeof parsed.listId === "string" ? parsed.listId : undefined,
      status:
        parsed.status && STATUS_VALUES.includes(parsed.status) ? parsed.status : undefined,
      sort: parsed.sort && SORT_VALUES.includes(parsed.sort) ? parsed.sort : undefined,
      favoriteOnly:
        typeof parsed.favoriteOnly === "boolean" ? parsed.favoriteOnly : undefined,
    };
  } catch {
    // Private mode / corrupted value: just start from the default view.
    return {};
  }
}

export function WordsPage() {
  const t = useT();
  const lang = useLang();
  const toast = useToast();
  const data = useAppData();
  const settings = useSettings();

  // One filter atom for the whole toolbar; listId lives here too so switching
  // lists and resetting filters share the same update path. The last view is
  // restored on open, with the saved list dropped if it no longer exists.
  const [filters, setFilters] = useState<WordQuery>(() => {
    const saved = readSavedView();
    const savedListExists =
      Boolean(saved.listId) && data.lists.some((l) => l.id === saved.listId);
    return {
      listId: savedListExists ? saved.listId! : (data.lists[0]?.id ?? ""),
      sort: saved.sort ?? "recent",
      status: saved.status ?? "all",
      favoriteOnly: saved.favoriteOnly ?? false,
    };
  });

  const [editorOpen, setEditorOpen] = useState(false);
  const [editing, setEditing] = useState<Word | null>(null);
  const [pendingDelete, setPendingDelete] = useState<Word | null>(null);
  const [listMgrOpen, setListMgrOpen] = useState(false);

  // Select mode: a quiet, reversible way to act on several words at once.
  const [selectMode, setSelectMode] = useState(false);
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [bulkDeleteOpen, setBulkDeleteOpen] = useState(false);
  const [tagDialogOpen, setTagDialogOpen] = useState(false);
  const [bulkTags, setBulkTags] = useState<string[]>([]);

  const searchRef = useRef<HTMLInputElement>(null);

  // Persist the view shape only — never the search text, because reopening the
  // page with a stale query would look like the list had lost its words.
  useEffect(() => {
    try {
      localStorage.setItem(
        VIEW_STORAGE_KEY,
        JSON.stringify({
          listId: filters.listId,
          status: filters.status ?? "all",
          sort: filters.sort ?? "recent",
          favoriteOnly: Boolean(filters.favoriteOnly),
        }),
      );
    } catch {
      // Storage unavailable — the view simply will not be remembered.
    }
  }, [filters.listId, filters.status, filters.sort, filters.favoriteOnly]);

  // Keep the selection valid if the active list disappears.
  useEffect(() => {
    if (data.lists.length === 0) return;
    setFilters((f) =>
      data.lists.some((l) => l.id === f.listId)
        ? f
        : { ...f, listId: data.lists[0].id, tag: undefined },
    );
  }, [data.lists]);

  // One index feeds the header counts, the status/tag controls and the list.
  // Rebuilt only when the snapshot changes (like the old due-count memo), so a
  // plain render cannot shift the due buckets under the user.
  const index = useMemo(() => buildWordIndex(data), [data]);
  const listId = filters.listId;
  const listCount = index.byList.get(listId)?.length ?? 0;
  const counts = index.countsByList.get(listId) ?? EMPTY_COUNTS;
  const tags = index.tagsByList.get(listId) ?? NO_TAGS;
  // List-scoped: the header must describe the list it sits above. The sidebar
  // badge stays global (App.tsx owns that one).
  const dueCount = index.dueByList.get(listId)?.length ?? 0;

  const trimmedQuery = (filters.query ?? "").trim();

  // A tag can vanish from the active list (deleted/edited word). The dropdown
  // only lists this list's tags, so derive the effective tag here: a stale one
  // can never filter the list down to nothing.
  const activeTag = filters.tag && tags.includes(filters.tag) ? filters.tag : undefined;

  const filtered = useMemo(
    () => queryWords(index, { ...filters, tag: activeTag, lang }),
    [index, filters, activeTag, lang],
  );
  const filtersActive =
    Boolean(trimmedQuery) ||
    (filters.status ?? "all") !== "all" ||
    Boolean(activeTag) ||
    Boolean(filters.favoriteOnly);

  const setQuery = (query: string) => setFilters((f) => ({ ...f, query }));
  const setStatusFilter = (status: StatusFilter) => setFilters((f) => ({ ...f, status }));
  const setTagFilter = (tag: string) =>
    setFilters((f) => ({ ...f, tag: tag === "all" ? undefined : tag }));
  const setSort = (sort: SortKey) => setFilters((f) => ({ ...f, sort }));
  const resetFilters = () => setFilters((f) => ({ listId: f.listId, sort: f.sort }));

  // Switching lists clears the tag: the dropdown only ever offers the active
  // list's tags, so keeping a foreign tag would silently empty the list.
  const selectList = (id: string) =>
    setFilters((f) => ({ ...f, listId: id, tag: undefined }));

  const openCreate = useCallback(() => {
    setEditing(null);
    setEditorOpen(true);
  }, []);

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

  // Page-scope shortcuts, all of them declared here as data:
  //   normal mode — "/" focuses search, "n" creates a word
  //   select mode — Esc leaves, Ctrl/⌘+A selects the filtered rows
  // The dialogs suspend the normal pair (the old listeners returned early
  // too). Select mode's keys are opt-in: Ctrl+A has to work even though focus
  // may sit in a field, and both are suspended while one of its dialogs is up.
  const pageShortcuts = useMemo<ShortcutBinding[]>(() => {
    if (selectMode) {
      if (tagDialogOpen || bulkDeleteOpen) return [];
      return [
        {
          id: "words.exitSelect",
          keys: ["Esc"],
          labelKey: "shortcuts.closeModal",
          scope: "page",
          showInHelp: false,
          allowWhenTyping: true,
          match: (event) => event.key === "Escape",
          run: () => exitSelect(),
        },
        {
          id: "words.selectAll",
          keys: ["Ctrl", "A"],
          labelKey: "words.select",
          scope: "page",
          showInHelp: false,
          allowWhenTyping: true,
          match: (event) =>
            Boolean(event.metaKey || event.ctrlKey) &&
            (event.key === "a" || event.key === "A"),
          run: () => setSelected(new Set(filtered.map((w) => w.id))),
        },
      ];
    }
    if (editorOpen || listMgrOpen || pendingDelete) return [];
    const unmodified = (event: KeyEventLike) =>
      !event.metaKey && !event.ctrlKey && !event.altKey;
    return [
      {
        ...SHORTCUTS.search,
        match: (event) => unmodified(event) && event.key === "/",
        run: () => searchRef.current?.focus(),
      },
      {
        ...SHORTCUTS.addWord,
        match: (event) => unmodified(event) && (event.key === "n" || event.key === "N"),
        run: () => openCreate(),
      },
    ];
  }, [
    editorOpen,
    listMgrOpen,
    pendingDelete,
    selectMode,
    tagDialogOpen,
    bulkDeleteOpen,
    filtered,
    openCreate,
  ]);
  useShortcutScope("page", pageShortcuts);

  /* ---- select mode -------------------------------------------------- */
  const selectedWords = useMemo(
    () => data.words.filter((w) => selected.has(w.id)),
    [data.words, selected],
  );

  const exitSelect = () => {
    setSelectMode(false);
    setSelected(new Set());
  };

  const toggleSelected = (id: string) =>
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  // "Select all" means what is on screen: the filtered rows, not the library.
  const selectAllFiltered = () => setSelected(new Set(filtered.map((w) => w.id)));

  const confirmBulkDelete = () => {
    // Snapshot words + their review logs before the cascade removes both, so
    // undo puts the scheduling history back, not just the bare terms.
    const victims = selectedWords.map((word) => ({
      word,
      logs: data.logs.filter((l) => l.wordId === word.id),
    }));
    deleteWords(victims.map((v) => v.word.id));
    setBulkDeleteOpen(false);
    exitSelect();
    toast(t("words.bulkDeleted", { n: victims.length }), "ok", {
      action: {
        label: t("common.undo"),
        onClick: () => victims.forEach((v) => restoreWord(v.word, v.logs)),
      },
      duration: 8000,
    });
  };

  const favoriteSelected = () => {
    selectedWords.forEach((w) => {
      if (!w.favorite) updateWord(w.id, { favorite: true });
    });
    toast(t("words.favoritedCount", { n: selectedWords.length }), "ok");
  };

  const applyBulkTags = () => {
    if (bulkTags.length === 0) return;
    selectedWords.forEach((w) => updateWord(w.id, { tags: [...w.tags, ...bulkTags] }));
    setBulkTags([]);
    setTagDialogOpen(false);
    toast(t("words.tagsAdded", { n: selectedWords.length }), "ok");
  };

  // Select mode is not a dialog, so it owns its two keys (Esc leaves, Ctrl/⌘+A
  // selects the filtered rows) — declared in `pageShortcuts` above with the
  // rest, so there is no second keydown listener and no second typing guard.

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
      subtitle={`${listCount} ${t("common.words")} · ${t("words.dueToday")} ${dueCount}`}
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
      <div className="list-tabs">
        {data.lists.map((l) => {
          const active = l.id === listId;
          return (
            <button
              key={l.id}
              type="button"
              onClick={() => selectList(l.id)}
              className={cx("list-tab", active && "active")}
              aria-pressed={active}
            >
              {l.name}
              <span className="count">{index.byList.get(l.id)?.length ?? 0}</span>
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
      <div className="toolbar">
        <div className="search">
          <span className="search-icon">
            <Icon name="search" size={15} />
          </span>
          <input
            ref={searchRef}
            className="input"
            value={filters.query ?? ""}
            onChange={(e) => setQuery(e.target.value)}
            placeholder={t("words.searchPlaceholder")}
            aria-label={t("common.search")}
            onKeyDown={(e) => {
              if (e.key === "Escape" && filters.query) {
                e.preventDefault();
                setQuery("");
              }
            }}
          />
          {filters.query && (
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
          value={filters.status ?? "all"}
          options={statusOptions}
          onChange={setStatusFilter}
          ariaLabel={t("words.filterStatus")}
        />

        <select
          className="select"
          value={activeTag ?? "all"}
          onChange={(e) => setTagFilter(e.target.value)}
          aria-label={t("words.filterTag")}
          style={{ minWidth: 120 }}
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
          value={filters.sort ?? "recent"}
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
          className={cx("btn btn-icon", filters.favoriteOnly && "btn-primary")}
          onClick={() => setFilters((f) => ({ ...f, favoriteOnly: !f.favoriteOnly }))}
          title={t("words.filterFavorites")}
          aria-pressed={Boolean(filters.favoriteOnly)}
        >
          <Icon name={filters.favoriteOnly ? "star-filled" : "star"} size={16} />
        </button>

        <button
          type="button"
          className={cx("btn btn-sm", selectMode ? "btn-primary" : "btn-quiet")}
          onClick={() => (selectMode ? exitSelect() : setSelectMode(true))}
          aria-pressed={selectMode}
        >
          <Icon name={selectMode ? "check" : "list"} size={14} />
          {selectMode ? t("common.done") : t("words.select")}
        </button>

        {filtersActive && (
          <button type="button" className="btn btn-quiet btn-sm" onClick={resetFilters}>
            <Icon name="x" size={14} />
            {t("common.reset")}
          </button>
        )}
      </div>

      {/* Word list */}
      {listCount === 0 ? (
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
            <div className={cx("row row-words row-head", selectMode && "selecting")}>
              {selectMode && <span aria-hidden="true" />}
              <span>{t("words.term")}</span>
              <span className="row-col-def">{t("common.definition")}</span>
              <span className="row-col-status">{t("common.status")}</span>
              <span style={{ textAlign: "right" }}>{t("common.actions")}</span>
            </div>
            {filtered.map((w, index) => {
              const picked = selected.has(w.id);
              return (
              <div
                key={w.id}
                className={cx("row row-words", selectMode && "selecting", picked && "is-picked")}
                /* Rows settle in one after another. Capped at 8 so a newly
                   filtered row never waits more than ~130ms to appear. */
                style={{ animationDelay: `${Math.min(index, 8) * 16}ms` }}
                aria-selected={selectMode ? picked : undefined}
                onClick={() => (selectMode ? toggleSelected(w.id) : openEdit(w))}
                role={selectMode ? "checkbox" : "button"}
                tabIndex={0}
                onKeyDown={(e) => {
                  // Only the row itself reacts — Enter on the nested delete /
                  // play / favourite buttons must not open the editor.
                  if (e.target !== e.currentTarget) return;
                  if (e.key === "Enter" || e.key === " ") {
                    e.preventDefault();
                    if (selectMode) toggleSelected(w.id);
                    else openEdit(w);
                  }
                }}
              >
                {selectMode && (
                  <span
                    className={cx("check", picked && "on")}
                    aria-hidden="true"
                    style={{ pointerEvents: "none" }}
                  >
                    {picked && <Icon name="check" size={12} />}
                  </span>
                )}
                <div className="row-flex" style={{ minWidth: 0, gap: "var(--sp-2)" }}>
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

                <div className="row-col-status">
                  <StatusChip status={w.status} label={t(STATUS_LABEL_KEY[w.status])} />
                  <span className="tiny muted">
                    {w.srs ? relativeDay(w.srs.dueAt, lang) : t("words.neverReviewed")}
                  </span>
                </div>

                <div
                  className="row-actions"
                  onClick={(e) => e.stopPropagation()}
                  style={selectMode ? { display: "none" } : undefined}
                >
                  <button
                    className="btn btn-icon btn-sm row-act-fav"
                    type="button"
                    title={t("common.favorite")}
                    aria-label={t("common.favorite")}
                    aria-pressed={w.favorite}
                    onClick={() => toggleFavorite(w.id)}
                  >
                    <Icon name={w.favorite ? "star-filled" : "star"} size={15} />
                  </button>
                  <button
                    className="btn btn-icon btn-sm row-act-play"
                    type="button"
                    title={t("words.listens", { n: w.listenCount })}
                    aria-label={t("common.play")}
                    onClick={() => play(w)}
                  >
                    <Icon name="volume" size={15} />
                  </button>
                  <button
                    className="btn btn-icon btn-sm row-act-edit"
                    type="button"
                    title={t("common.edit")}
                    aria-label={t("common.edit")}
                    onClick={() => openEdit(w)}
                  >
                    <Icon name="edit" size={15} />
                  </button>
                  <button
                    className="btn btn-icon btn-sm row-act-del"
                    type="button"
                    title={t("common.delete")}
                    aria-label={t("common.delete")}
                    onClick={() => setPendingDelete(w)}
                  >
                    <Icon name="trash" size={15} />
                  </button>
                </div>
              </div>
              );
            })}
          </div>
        </div>
      )}

      {selectMode && (
        <div className="bulk-bar" role="region" aria-label={t("words.bulkTitle")}>
          <span className="bulk-count" aria-live="polite">
            {t("words.selected", { n: selected.size })}
          </span>
          <button
            type="button"
            className="btn btn-quiet btn-sm"
            onClick={selectAllFiltered}
            disabled={selected.size === filtered.length}
          >
            <Icon name="check" size={14} />
            {t("words.selectAll")}
          </button>
          <button
            type="button"
            className="btn btn-quiet btn-sm"
            onClick={favoriteSelected}
            disabled={selected.size === 0}
          >
            <Icon name="star" size={14} />
            {t("words.favoriteSelected")}
          </button>
          <button
            type="button"
            className="btn btn-quiet btn-sm"
            onClick={() => setTagDialogOpen(true)}
            disabled={selected.size === 0}
          >
            <Icon name="tag" size={14} />
            {t("words.tagSelected")}
          </button>
          <button
            type="button"
            className="btn btn-quiet btn-sm bulk-danger"
            onClick={() => setBulkDeleteOpen(true)}
            disabled={selected.size === 0}
          >
            <Icon name="trash" size={14} />
            {t("words.deleteSelected")}
          </button>
          <button
            type="button"
            className="btn btn-quiet btn-sm"
            onClick={exitSelect}
            style={{ marginLeft: "auto" }}
          >
            <Icon name="x" size={14} />
            {t("common.cancel")}
          </button>
        </div>
      )}

      {filtered.length > 0 && !selectMode && (
        <div className="row-flex tiny muted" style={{ marginTop: "var(--sp-4)", gap: "var(--sp-2)" }}>
          <span>
            {t("common.total")} {filtered.length} {t("common.words")}
            {filtered.length !== listCount ? ` / ${listCount}` : ""}
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
            // Restore the word *and* its review logs, so undo is a real undo.
            const logs = data.logs.filter((l) => l.wordId === pendingDelete.id);
            deleteWord(pendingDelete.id);
            toast(t("words.wordDeleted"), "ok", {
              action: {
                label: t("common.undo"),
                onClick: () => restoreWord(pendingDelete, logs),
              },
              duration: 8000,
            });
          }
          setPendingDelete(null);
        }}
      />

      <ConfirmDialog
        open={bulkDeleteOpen}
        title={t("words.bulkDeleteConfirm", { n: selected.size })}
        body={t("words.bulkDeleteBody")}
        confirmLabel={t("words.deleteSelected")}
        cancelLabel={t("common.cancel")}
        onCancel={() => setBulkDeleteOpen(false)}
        onConfirm={confirmBulkDelete}
      />

      <Modal
        open={tagDialogOpen}
        onClose={() => setTagDialogOpen(false)}
        title={t("words.tagSelected")}
        width={420}
        footer={
          <>
            <button
              type="button"
              className="btn btn-ghost"
              onClick={() => setTagDialogOpen(false)}
            >
              {t("common.cancel")}
            </button>
            <button
              type="button"
              className="btn btn-primary"
              onClick={applyBulkTags}
              disabled={bulkTags.length === 0}
            >
              {t("common.save")}
            </button>
          </>
        }
      >
        <TagInput
          value={bulkTags}
          onChange={setBulkTags}
          placeholder={t("words.tagsPlaceholder")}
          hint={t("words.bulkTagsHint", { n: selected.size })}
        />
      </Modal>

      <ListManagerModal
        open={listMgrOpen}
        onClose={() => setListMgrOpen(false)}
        data={data}
        activeId={listId}
        onSelect={selectList}
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
      subtitle={t("words.listsSubtitle", { n: data.lists.length })}
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
                          color: active ? "var(--accent-ink)" : undefined,
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
            ? t("words.deleteListConfirm", {
                name: pendingDelete.name,
                n: data.words.filter((w) => w.listId === pendingDelete.id).length,
              })
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
