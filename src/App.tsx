/** App shell: sidebar, theme application, page switching. */
import { useEffect } from "react";
import { Icon, type IconName } from "@/components/Icon";
import { useT } from "@/i18n";
import { useAppData, reviewsToday, streakDays, dueWords } from "@/lib/store";
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

export function App() {
  const t = useT();
  const { page, navigate } = useRouter();
  const data = useAppData();
  useTheme();

  const due = dueWords(data).length;
  const streak = streakDays(data);
  const today = reviewsToday(data);

  return (
    <div className="app">
      <aside className="sidebar">
        <div className="brand">
          <div className="brand-mark">L</div>
          <div>
            <div className="brand-name">{t("common.appName")}</div>
            <div className="brand-sub">词屿</div>
          </div>
        </div>

        <nav className="nav" aria-label="main">
          {NAV.map((item) => (
            <button
              key={item.id}
              type="button"
              className={cx("nav-item", page === item.id && "active")}
              onClick={() => navigate(item.id)}
              aria-current={page === item.id ? "page" : undefined}
            >
              <span className="nav-icon">
                <Icon name={item.icon} size={18} />
              </span>
              {t(item.labelKey)}
              {item.id === "flashcards" && due > 0 && <span className="nav-count">{due}</span>}
            </button>
          ))}
        </nav>

        <div className="sidebar-foot">
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
          <div className="tiny muted" style={{ padding: "0 8px" }}>
            {t("common.appTagline")}
          </div>
        </div>
      </aside>

      <main className="main">
        {page === "words" && <WordsPage />}
        {page === "flashcards" && <FlashcardsPage />}
        {page === "quiz" && <QuizPage />}
        {page === "stats" && <StatsPage />}
        {page === "settings" && <SettingsPage />}
      </main>
    </div>
  );
}
