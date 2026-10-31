/** App shell: sidebar, theme application, page switching, global shortcuts. */
import {
  useCallback,
  useEffect,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
} from "react";
import { Icon, type IconName } from "@/components/Icon";
import { Modal, ShortcutRow, useToast } from "@/components/ui";
import { TitleBar } from "@/components/TitleBar";
import { useT, type MessageKey } from "@/i18n";
import {
  useAppData,
  reviewsToday,
  streakDays,
  dueWords,
  updateSettings,
} from "@/lib/store";
import {
  SHORTCUTS,
  SHORTCUT_HELP,
  useShortcutScope,
  type ShortcutBinding,
} from "@/lib/shortcuts";
import { getSyncStatus, subscribeSyncStatus, type SyncError } from "@/lib/sync";
import { useRouter, type PageId } from "@/app/router";
import { cx } from "@/lib/utils";
import { onError } from "@/lib/errors";
import { warmNativeTts } from "@/lib/tts";
import { WordsPage } from "@/pages/words/WordsPage";
import { FlashcardsPage } from "@/pages/study/FlashcardsPage";
import { QuizPage } from "@/pages/study/QuizPage";
import { StatsPage } from "@/pages/stats/StatsPage";
import { SettingsPage } from "@/pages/settings/SettingsPage";
import {
  syncErrorKey,
  syncStatusLabel,
  syncStatusTone,
} from "@/pages/settings/SyncSection";

const NAV: Array<{ id: PageId; icon: IconName; labelKey: MessageKey }> = [
  { id: "words", icon: "words", labelKey: "nav.words" },
  { id: "flashcards", icon: "cards", labelKey: "nav.flashcards" },
  { id: "quiz", icon: "quiz", labelKey: "nav.quiz" },
  { id: "stats", icon: "stats", labelKey: "nav.stats" },
  { id: "settings", icon: "settings", labelKey: "nav.settings" },
];

const RAIL_KEY = "lexumo.rail";

function useTheme() {
  const { settings } = useAppData();
  useEffect(() => {
    const root = document.documentElement;
    const apply = () => {
      const dark =
        settings.theme === "dark" ||
        (settings.theme === "system" &&
          window.matchMedia("(prefers-color-scheme: dark)").matches);
      root.dataset.theme = dark ? "dark" : "light";
    };
    apply();
    if (settings.theme !== "system") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    mq.addEventListener("change", apply);
    return () => mq.removeEventListener("change", apply);
  }, [settings.theme]);
}

/** Sidebar collapses to an icon rail: auto on narrow windows, or by user choice. */
function useRail() {
  const [pref, setPref] = useState<boolean | null>(() => {
    try {
      const raw = localStorage.getItem(RAIL_KEY);
      return raw === null ? null : raw === "1";
    } catch {
      return null;
    }
  });
  const [narrow, setNarrow] = useState(
    () => typeof window !== "undefined" && window.innerWidth < 1000,
  );

  useEffect(() => {
    const mq = window.matchMedia("(max-width: 1000px)");
    const sync = () => setNarrow(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  const rail = pref ?? narrow;
  const toggle = useCallback(() => {
    const next = !rail;
    setPref(next);
    try {
      localStorage.setItem(RAIL_KEY, next ? "1" : "0");
    } catch {
      /* storage may be unavailable; the visual state still updates */
    }
  }, [rail]);

  return { rail, toggle };
}

/** Phone layout: the sidebar gives way to a bottom tab bar. */
function useMobile() {
  const [mobile, setMobile] = useState(
    () => typeof window !== "undefined" && window.innerWidth <= 720,
  );

  useEffect(() => {
    const mq = window.matchMedia("(max-width: 720px)");
    const sync = () => setMobile(mq.matches);
    sync();
    mq.addEventListener("change", sync);
    return () => mq.removeEventListener("change", sync);
  }, []);

  return mobile;
}

export function App() {
  const t = useT();
  const { page, navigate } = useRouter();
  const data = useAppData();
  const { rail, toggle } = useRail();
  const mobile = useMobile();
  const [helpOpen, setHelpOpen] = useState(false);
  const toast = useToast();
  useTheme();

  // A snapshot that fell through both IndexedDB and localStorage is alive in
  // memory only. Nothing on screen can show that by itself, so the adapter
  // reports it and the shell says one sentence with the next step in it.
  useEffect(
    () =>
      onError((kind) => {
        if (kind === "store-write") toast(t("errors.storeWrite"), "err");
      }),
    [toast, t],
  );

  const pendingAnchor = useRef<string | null>(null);

  /** Jump to the sync section — from the sidebar chip or the error toast. */
  const openSync = useCallback(() => {
    if (page === "settings") {
      document.getElementById("set-sync")?.scrollIntoView({ block: "start" });
      return;
    }
    pendingAnchor.current = "set-sync";
    navigate("settings");
  }, [page, navigate]);

  // Switching pages should start at the top — instantly, since the page
  // container no longer animates scrolling (a smooth reset reads as a jump).
  useEffect(() => {
    const anchor = pendingAnchor.current;
    pendingAnchor.current = null;
    const target = anchor ? document.getElementById(anchor) : null;
    if (target) {
      target.scrollIntoView({ block: "start" });
      return;
    }
    const scroller = document.querySelector<HTMLElement>(".page");
    if (!scroller) return;
    // `scrollTo` on an element is not implemented everywhere a DOM exists
    // (jsdom, older WebViews), so fall back to assigning `scrollTop`.
    if (typeof scroller.scrollTo === "function") {
      scroller.scrollTo({ top: 0, behavior: "instant" as ScrollBehavior });
    } else {
      scroller.scrollTop = 0;
    }
  }, [page]);

  // Warm the native speech engine once, on the shells that have no Web Speech.
  // Android's engine initialises asynchronously and reports no voices until it
  // is ready, so the settings voice picker would otherwise stay empty forever.
  // On desktop this is a no-op: `speechSynthesis` already exists.
  useEffect(() => {
    void warmNativeTts();
  }, []);

  const due = dueWords(data).length;
  const streak = streakDays(data);
  const today = reviewsToday(data);
  const dark = data.settings.theme === "dark";
  const syncStatus = useSyncExternalStore(subscribeSyncStatus, getSyncStatus, getSyncStatus);
  const signedIn = syncStatus.state !== "signed-out";
  const syncTone = syncStatusTone(syncStatus, signedIn);
  const syncLabel = syncStatusLabel(t, syncStatus, signedIn);

  // Background sync failures used to be a 6px dot in the sidebar; say it once,
  // with a way to jump straight to the section that explains it.
  const lastSyncError = useRef<SyncError | null>(null);
  useEffect(() => {
    const error = syncStatus.error;
    if (error && error !== lastSyncError.current) {
      toast(t(syncErrorKey(error)), "err", {
        action: { label: t("settings.syncGoTo"), onClick: openSync },
        duration: 8000,
      });
    }
    lastSyncError.current = error;
  }, [syncStatus.error, toast, t, openSync]);

  // App-scope shortcuts: Cmd/Ctrl+1..5 switch pages, "?" opens this sheet.
  // Neither may fire while a field has focus or a dialog is open: switching
  // pages mid-edit used to unmount the editor and silently drop the draft.
  const appShortcuts = useMemo<ShortcutBinding[]>(
    () => [
      {
        ...SHORTCUTS.pageSwitch,
        match: (event) => {
          if (!(event.metaKey || event.ctrlKey) || event.altKey) return false;
          const index = Number(event.key);
          return Number.isInteger(index) && index >= 1 && index <= NAV.length;
        },
        when: () => document.querySelector('[role="dialog"]') === null,
        run: (event) => navigate(NAV[Number(event.key) - 1].id),
      },
      {
        ...SHORTCUTS.help,
        match: (event) =>
          event.key === "?" || (event.shiftKey === true && event.key === "/"),
        // "?" still closes the sheet it opened; it just never stacks on top of
        // another dialog.
        when: () => helpOpen || document.querySelector('[role="dialog"]') === null,
        run: () => setHelpOpen((open) => !open),
      },
    ],
    [navigate, helpOpen],
  );
  useShortcutScope("app", appShortcuts);

  return (
    <div className={cx("app", rail && "rail", mobile && "mobile")}>
      <a className="skip-link" href="#main-content">
        {t("shell.skipToContent")}
      </a>

      <TitleBar />

      <aside className="sidebar">
        <nav className="nav" aria-label={t("nav.main")}>
          {NAV.map((item, i) => (
            <button
              key={item.id}
              type="button"
              className={cx("nav-item", page === item.id && "active")}
              onClick={() => navigate(item.id)}
              aria-current={page === item.id ? "page" : undefined}
              title={`${t(item.labelKey)}  (Ctrl+${i + 1})`}
            >
              <span className="nav-icon">
                <Icon name={item.icon} size={18} />
              </span>
              <span className="nav-label">{t(item.labelKey)}</span>
              {item.id === "flashcards" && due > 0 && <span className="nav-count">{due}</span>}
            </button>
          ))}
        </nav>

        <div className="sidebar-foot">
          {syncStatus.state !== "signed-out" && (
            <button
              type="button"
              className="sync-chip"
              onClick={openSync}
              title={syncStatus.email ? `${syncLabel}，${syncStatus.email}` : syncLabel}
            >
              <span className={`sync-dot sync-dot-${syncTone}`} aria-hidden="true" />
              <span className="sync-chip-text">{syncLabel}</span>
            </button>
          )}
          <div className="streak-card">
            <span className="streak-flame" aria-hidden="true">
              <Icon name="flame" size={18} />
            </span>
            <div style={{ minWidth: 0 }}>
              <div className="streak-num">
                {streak}
                <span className="streak-unit">{t("stats.streakUnit")}</span>
              </div>
              <div className="streak-label">
                {t("stats.reviewsToday")} {today}
              </div>
            </div>
          </div>

          <div className="sidebar-actions">
            <button
              className="btn btn-quiet btn-sm"
              type="button"
              onClick={() => setHelpOpen(true)}
              title={`${t("settings.shortcuts")} (?)`}
              aria-label={t("settings.shortcuts")}
            >
              <Icon name="keyboard" size={16} />
            </button>
            <button
              className="btn btn-quiet btn-sm"
              type="button"
              onClick={() =>
                updateSettings({ theme: dark ? "light" : "dark" })
              }
              title={dark ? t("shell.themeToLight") : t("shell.themeToDark")}
              aria-label={dark ? t("shell.themeToLight") : t("shell.themeToDark")}
            >
              <Icon name={dark ? "sun" : "moon"} size={16} />
            </button>
            <button
              className="rail-toggle"
              type="button"
              onClick={toggle}
              title={rail ? t("shell.expandRail") : t("shell.collapseRail")}
              aria-label={rail ? t("shell.expandRail") : t("shell.collapseRail")}
              aria-expanded={!rail}
            >
              <Icon name="chevron-left" size={16} />
            </button>
          </div>

          <div className="sidebar-tagline">{t("common.appTagline")}</div>
        </div>
      </aside>

      {mobile && (
        <nav className="tabbar" aria-label={t("nav.tabbar")}>
          {NAV.map((item) => (
            <button
              key={item.id}
              type="button"
              className={cx("tab-item", page === item.id && "active")}
              onClick={() => navigate(item.id)}
              aria-current={page === item.id ? "page" : undefined}
            >
              <span className="tab-icon">
                <Icon name={item.icon} size={21} />
                {item.id === "flashcards" && due > 0 && (
                  <span className="tab-badge">{due > 99 ? "99+" : due}</span>
                )}
              </span>
              <span className="tab-label">{t(item.labelKey)}</span>
            </button>
          ))}
        </nav>
      )}

      <main className="main" id="main-content" tabIndex={-1}>
        {page === "words" && <WordsPage />}
        {page === "flashcards" && <FlashcardsPage />}
        {page === "quiz" && <QuizPage />}
        {page === "stats" && <StatsPage />}
        {page === "settings" && <SettingsPage />}
      </main>

      <Modal
        open={helpOpen}
        onClose={() => setHelpOpen(false)}
        title={t("settings.shortcuts")}
        subtitle={t("shell.shortcutsSub")}
        width={560}
        footer={
          <button className="btn btn-primary" type="button" onClick={() => setHelpOpen(false)}>
            {t("common.gotIt")}
          </button>
        }
      >
        <div className="shortcuts">
          {SHORTCUT_HELP.map((shortcut) => (
            <ShortcutRow
              key={shortcut.id}
              keys={shortcut.keys}
              label={t(shortcut.labelKey)}
            />
          ))}
        </div>
        <div className="notice">
          <span className="notice-ico">
            <Icon name="info" size={15} />
          </span>
          <span>{t("shell.shortcutsTypingHint")}</span>
        </div>
      </Modal>
    </div>
  );
}
