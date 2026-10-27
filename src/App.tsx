/** App shell: sidebar, theme application, page switching, global shortcuts. */
import { useCallback, useEffect, useState, useSyncExternalStore } from "react";
import { Icon, type IconName } from "@/components/Icon";
import { Modal, ShortcutRow } from "@/components/ui";
import { useT } from "@/i18n";
import {
  useAppData,
  reviewsToday,
  streakDays,
  dueWords,
  updateSettings,
} from "@/lib/store";
import { getSyncStatus, subscribeSyncStatus } from "@/lib/sync";
import { useRouter, type PageId } from "@/app/router";
import { cx } from "@/lib/utils";
import { WordsPage } from "@/pages/words/WordsPage";
import { FlashcardsPage } from "@/pages/study/FlashcardsPage";
import { QuizPage } from "@/pages/study/QuizPage";
import { StatsPage } from "@/pages/stats/StatsPage";
import { SettingsPage } from "@/pages/settings/SettingsPage";

const NAV: Array<{ id: PageId; icon: IconName; labelKey: string }> = [
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
  useTheme();

  // Switching pages should start at the top — on a phone the scroll offset of
  // the previous page otherwise carries over and looks like a broken jump.
  useEffect(() => {
    const scroller = document.querySelector(".page");
    if (scroller) scroller.scrollTop = 0;
  }, [page]);

  const due = dueWords(data).length;
  const streak = streakDays(data);
  const today = reviewsToday(data);
  const dark = data.settings.theme === "dark";
  const syncStatus = useSyncExternalStore(subscribeSyncStatus, getSyncStatus, getSyncStatus);
  const syncTone =
    syncStatus.state === "error"
      ? "danger"
      : syncStatus.state === "syncing"
        ? "busy"
        : syncStatus.pending > 0
          ? "busy"
          : "ok";
  const syncLabel =
    syncStatus.state === "error"
      ? t("settings.syncStatusError")
      : syncStatus.state === "syncing"
        ? t("settings.syncStatusSyncing")
        : syncStatus.pending > 0
          ? t("settings.syncPendingHint", { n: syncStatus.pending })
          : t("settings.syncStatusIdle");

  // Global shortcuts: Cmd/Ctrl+1..5 switch pages, "?" opens the shortcut sheet.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "?" || (e.shiftKey && e.key === "/")) {
        const el = e.target as HTMLElement | null;
        const typing =
          el &&
          (el.tagName === "INPUT" ||
            el.tagName === "TEXTAREA" ||
            el.tagName === "SELECT" ||
            el.isContentEditable);
        if (typing) return;
        e.preventDefault();
        setHelpOpen((v) => !v);
        return;
      }
      if (!(e.metaKey || e.ctrlKey) || e.altKey) return;
      const n = Number(e.key);
      if (n >= 1 && n <= NAV.length) {
        e.preventDefault();
        navigate(NAV[n - 1].id);
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [navigate]);

  return (
    <div className={cx("app", rail && "rail", mobile && "mobile")}>
      <a className="skip-link" href="#main-content">
        跳到主要内容
      </a>

      <aside className="sidebar">
        <div className="brand">
          <div className="brand-mark">L</div>
          <div className="brand-text">
            <div className="brand-name">{t("common.appName")}</div>
            <div className="brand-sub">词砚</div>
          </div>
        </div>

        <nav className="nav" aria-label="主导航">
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
              onClick={() => navigate("settings")}
              title={syncStatus.email ? `${syncLabel} · ${syncStatus.email}` : syncLabel}
            >
              <span className={`sync-dot sync-dot-${syncTone}`} />
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
                <span style={{ fontSize: 12, marginLeft: 3, color: "var(--ink-3)" }}>
                  {t("stats.streakUnit")}
                </span>
              </div>
              <div className="streak-label">
                {t("stats.reviewsToday")} · {today}
              </div>
            </div>
          </div>

          <div className="sidebar-actions">
            <button
              className="btn btn-quiet btn-sm"
              type="button"
              onClick={() => setHelpOpen(true)}
              title="快捷键 (?)"
              aria-label="快捷键帮助"
            >
              <Icon name="keyboard" size={16} />
            </button>
            <button
              className="btn btn-quiet btn-sm"
              type="button"
              onClick={() =>
                updateSettings({ theme: dark ? "light" : "dark" })
              }
              title={dark ? "切换到浅色" : "切换到深色"}
              aria-label={dark ? "切换到浅色主题" : "切换到深色主题"}
            >
              <Icon name={dark ? "sun" : "moon"} size={16} />
            </button>
            <button
              className="rail-toggle"
              type="button"
              onClick={toggle}
              title={rail ? "展开侧栏" : "收起侧栏"}
              aria-label={rail ? "展开侧栏" : "收起侧栏"}
              aria-expanded={!rail}
            >
              <Icon name="chevron-left" size={16} />
            </button>
          </div>

          <div className="sidebar-tagline">{t("common.appTagline")}</div>
        </div>
      </aside>

      {mobile && (
        <nav className="tabbar" aria-label={t("nav.main")}>
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
        title="快捷键"
        subtitle="不用鼠标也能把每天的学习做完"
        width={560}
        footer={
          <button className="btn btn-primary" type="button" onClick={() => setHelpOpen(false)}>
            知道了
          </button>
        }
      >
        <div className="shortcuts">
          <ShortcutRow keys={["Ctrl", "1…5"]} label="切换页面" />
          <ShortcutRow keys={["?"]} label="打开这张表" />
          <ShortcutRow keys={["/"]} label="搜索词条" />
          <ShortcutRow keys={["n"]} label="新建词条" />
          <ShortcutRow keys={["空格"]} label="闪卡翻面" />
          <ShortcutRow keys={["1", "2", "3"]} label="评分（难 / 良 / 易）" />
          <ShortcutRow keys={["Ctrl", "Z"]} label="撤销上一次评分" />
          <ShortcutRow keys={["←", "→"]} label="跳过当前卡" />
          <ShortcutRow keys={["Esc"]} label="关闭弹窗" />
        </div>
        <div className="notice">
          <span className="notice-ico">
            <Icon name="info" size={15} />
          </span>
          <span>提示：在输入框里输入时，单键快捷键会自动让位，不会打断打字。</span>
        </div>
      </Modal>
    </div>
  );
}
