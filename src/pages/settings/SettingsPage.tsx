import {
  useEffect,
  useRef,
  useState,
  type ChangeEvent,
  type ReactNode,
} from "react";
import { useT } from "@/i18n";
import {
  PageShell,
  Segmented,
  Modal,
  ConfirmDialog,
  useToast,
} from "@/components/ui";
import { Icon, type IconName } from "@/components/Icon";
import {
  useAppData,
  updateSettings,
  addWord,
  getData,
  findDuplicate,
  wipeAll,
  DEFAULT_LIST_ID,
} from "@/lib/store";
import {
  exportJson,
  exportCsv,
  parseImport,
  type ImportResult,
} from "@/lib/transfer";
import { downloadText, clamp, dayKey } from "@/lib/utils";
import {
  speak,
  voicesFor,
  onVoicesChanged,
  speechSupported,
  type VoiceInfo,
} from "@/lib/tts";
import type { ThemeMode, UiLang } from "@/lib/types";

function SectionCard({
  icon,
  title,
  children,
}: {
  icon: IconName;
  title: string;
  children: ReactNode;
}) {
  return (
    <section className="card">
      <div className="card-head">
        <span style={{ display: "grid", placeItems: "center", color: "var(--ink-3)" }}>
          <Icon name={icon} size={17} />
        </span>
        <div className="card-title">{title}</div>
      </div>
      <div
        className="card-pad"
        style={{ display: "flex", flexDirection: "column", gap: "var(--sp-4)" }}
      >
        {children}
      </div>
    </section>
  );
}

function Toggle({
  checked,
  onChange,
  label,
}: {
  checked: boolean;
  onChange: (next: boolean) => void;
  label: string;
}) {
  return (
    <button
      type="button"
      role="switch"
      aria-checked={checked}
      aria-label={label}
      onClick={() => onChange(!checked)}
      style={{
        width: 40,
        height: 23,
        flex: "0 0 auto",
        borderRadius: 999,
        border: `1px solid ${checked ? "transparent" : "var(--line-strong)"}`,
        background: checked ? "var(--jade)" : "var(--surface-2)",
        padding: 2,
        cursor: "pointer",
        display: "flex",
        alignItems: "center",
        justifyContent: checked ? "flex-end" : "flex-start",
        transition: "background 160ms var(--ease)",
      }}
    >
      <span
        style={{
          width: 17,
          height: 17,
          borderRadius: "50%",
          background: checked ? "#fff" : "var(--ink-4)",
          boxShadow: "var(--shadow-xs)",
          transition: "background 160ms var(--ease)",
        }}
      />
    </button>
  );
}

function SettingToggle({
  label,
  hint,
  checked,
  onChange,
}: {
  label: string;
  hint?: string;
  checked: boolean;
  onChange: (next: boolean) => void;
}) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: "var(--sp-4)" }}>
      <div style={{ minWidth: 0 }}>
        <div className="label" style={{ marginBottom: 2 }}>
          {label}
        </div>
        {hint !== undefined && <div className="hint">{hint}</div>}
      </div>
      <div style={{ marginLeft: "auto" }}>
        <Toggle checked={checked} onChange={onChange} label={label} />
      </div>
    </div>
  );
}

function Kbd({ children }: { children: ReactNode }) {
  return <span className="kbd">{children}</span>;
}

function Shortcut({ label, keys }: { label: string; keys: ReactNode }) {
  return (
    <>
      <span className="tiny" style={{ color: "var(--ink-2)" }}>
        {label}
      </span>
      <span className="row-flex" style={{ gap: 4, justifyContent: "flex-end" }}>
        {keys}
      </span>
    </>
  );
}

function formatLabel(format: ImportResult["format"]): string {
  switch (format) {
    case "json":
      return "Lexilo JSON 备份";
    case "csv":
      return "CSV 表格";
    case "anki":
      return "Anki TXT";
    default:
      return "未知格式";
  }
}

export function SettingsPage() {
  const t = useT();
  const toast = useToast();
  const data = useAppData();
  const settings = data.settings;
  const listId = data.lists[0]?.id ?? DEFAULT_LIST_ID;
  const lang = data.lists[0]?.sourceLang ?? "en";

  const [voices, setVoices] = useState<VoiceInfo[]>(() => voicesFor(lang));
  const [wipeOpen, setWipeOpen] = useState(false);
  const [preview, setPreview] = useState<{
    result: ImportResult;
    fileName: string;
  } | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => onVoicesChanged(() => setVoices(voicesFor(lang))), [lang]);

  const sample =
    data.words[0]?.term ??
    (lang.toLowerCase().startsWith("zh")
      ? "你好，欢迎使用词屿。"
      : "Hello, welcome to Lexilo.");

  const testVoice = () => {
    if (!speechSupported()) {
      toast(t("settings.noVoice"), "err");
      return;
    }
    speak(sample, {
      lang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI || undefined,
    });
  };

  const handleExportJson = () => {
    downloadText(
      `lexilo-backup-${dayKey(Date.now())}.json`,
      exportJson(data),
      "application/json;charset=utf-8",
    );
    toast(t("common.success"), "ok");
  };

  const handleExportCsv = () => {
    downloadText(
      `lexilo-words-${dayKey(Date.now())}.csv`,
      exportCsv(data.words),
      "text/csv;charset=utf-8",
    );
    toast(t("common.success"), "ok");
  };

  const handlePickFile = async (event: ChangeEvent<HTMLInputElement>) => {
    const file = event.target.files?.[0];
    event.target.value = "";
    if (!file) return;
    try {
      const text = await file.text();
      const result = parseImport(text, listId);
      if (result.format === "unknown" || result.words.length === 0) {
        toast(
          t("settings.importFailed", { msg: "无法识别文件格式或没有可导入的词语" }),
          "err",
        );
        return;
      }
      setPreview({ result, fileName: file.name });
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      toast(t("settings.importFailed", { msg }), "err");
    }
  };

  const confirmImport = () => {
    if (!preview) return;
    let added = 0;
    let duplicated = 0;
    for (const word of preview.result.words) {
      if (findDuplicate(getData(), word.term, listId)) {
        duplicated += 1;
        continue;
      }
      addWord(word);
      added += 1;
    }
    setPreview(null);
    toast(t("settings.importSuccess", { n: added }), "ok");
    if (duplicated > 0) toast(`已跳过 ${duplicated} 个重复词语`, "info");
  };

  return (
    <PageShell title={t("settings.title")} subtitle={t("settings.subtitle")}>
      <div
        style={{
          display: "grid",
          gridTemplateColumns: "repeat(auto-fit, minmax(340px, 1fr))",
          gap: "var(--sp-5)",
          alignItems: "start",
        }}
      >
        {/* 外观 */}
        <SectionCard icon="sparkles" title={t("settings.appearance")}>
          <div className="field">
            <span className="label">{t("settings.theme")}</span>
            <Segmented<ThemeMode>
              value={settings.theme}
              options={[
                { value: "light", label: t("common.light") },
                { value: "dark", label: t("common.dark") },
                { value: "system", label: t("common.system") },
              ]}
              onChange={(theme) => updateSettings({ theme })}
              ariaLabel={t("settings.theme")}
            />
          </div>
          <div className="field">
            <span className="label">{t("settings.language")}</span>
            <Segmented<UiLang>
              value={settings.uiLang}
              options={[
                { value: "zh-CN", label: "中文" },
                { value: "en", label: "English" },
              ]}
              onChange={(uiLang) => updateSettings({ uiLang })}
              ariaLabel={t("settings.language")}
            />
          </div>
        </SectionCard>

        {/* 学习 */}
        <SectionCard icon="target" title={t("settings.study")}>
          <div
            style={{
              display: "grid",
              gridTemplateColumns: "1fr 1fr",
              gap: "var(--sp-4)",
            }}
          >
            <div className="field">
              <label className="label" htmlFor="daily-goal">
                {t("settings.dailyGoal")}
              </label>
              <input
                id="daily-goal"
                className="input mono"
                type="number"
                min={1}
                max={200}
                value={settings.dailyGoal}
                onChange={(event) =>
                  updateSettings({
                    dailyGoal: clamp(
                      Math.round(Number(event.target.value) || 0),
                      1,
                      200,
                    ),
                  })
                }
              />
            </div>
            <div className="field">
              <label className="label" htmlFor="new-cards">
                {t("settings.newCardsPerDay")}
              </label>
              <input
                id="new-cards"
                className="input mono"
                type="number"
                min={0}
                max={100}
                value={settings.newCardsPerDay}
                onChange={(event) =>
                  updateSettings({
                    newCardsPerDay: clamp(
                      Math.round(Number(event.target.value) || 0),
                      0,
                      100,
                    ),
                  })
                }
              />
            </div>
          </div>
          <div className="field">
            <span className="label">{t("settings.reviewOrder")}</span>
            <Segmented<"due" | "random">
              value={settings.reviewOrder}
              options={[
                { value: "due", label: t("settings.orderDue") },
                { value: "random", label: t("settings.orderRandom") },
              ]}
              onChange={(reviewOrder) => updateSettings({ reviewOrder })}
              ariaLabel={t("settings.reviewOrder")}
            />
          </div>
          <SettingToggle
            label={t("settings.autoPlay")}
            checked={settings.autoPlayAudio}
            onChange={(autoPlayAudio) => updateSettings({ autoPlayAudio })}
          />
          <div className="field">
            <div
              style={{
                display: "flex",
                alignItems: "center",
                justifyContent: "space-between",
              }}
            >
              <label className="label" htmlFor="tts-rate">
                {t("settings.ttsRate")}
              </label>
              <span className="tiny mono muted">{settings.ttsRate.toFixed(2)}×</span>
            </div>
            <input
              id="tts-rate"
              type="range"
              min={0.5}
              max={1.5}
              step={0.05}
              value={settings.ttsRate}
              onChange={(event) =>
                updateSettings({
                  ttsRate: clamp(Number(event.target.value), 0.5, 1.5),
                })
              }
              style={{ width: "100%", accentColor: "var(--jade)" }}
            />
          </div>
        </SectionCard>

        {/* 发音 */}
        <SectionCard icon="volume" title={t("settings.audio")}>
          <div className="field">
            <label className="label" htmlFor="tts-voice">
              {t("settings.ttsVoice")}
            </label>
            <select
              id="tts-voice"
              className="select"
              value={settings.ttsVoiceURI}
              onChange={(event) =>
                updateSettings({ ttsVoiceURI: event.target.value })
              }
            >
              <option value="">{t("settings.ttsVoiceAuto")}</option>
              {voices.map((voice) => (
                <option key={voice.uri} value={voice.uri}>
                  {voice.name} · {voice.lang}
                </option>
              ))}
            </select>
            {voices.length === 0 && (
              <span className="hint">{t("settings.noVoice")}</span>
            )}
          </div>
          <button
            className="btn"
            type="button"
            onClick={testVoice}
            disabled={!speechSupported()}
            style={{ alignSelf: "flex-start" }}
          >
            <Icon name="volume" size={16} />
            {t("settings.testVoice")}
          </button>
          <SettingToggle
            label={t("settings.audioFirst")}
            checked={settings.audioFirst}
            onChange={(audioFirst) => updateSettings({ audioFirst })}
          />
        </SectionCard>

        {/* 数据 */}
        <SectionCard icon="download" title={t("settings.data")}>
          <div style={{ display: "flex", flexDirection: "column", gap: "var(--sp-2)" }}>
            <button
              className="btn"
              type="button"
              onClick={handleExportJson}
              style={{ justifyContent: "flex-start" }}
            >
              <Icon name="download" size={16} />
              {t("settings.exportJson")}
            </button>
            <button
              className="btn"
              type="button"
              onClick={handleExportCsv}
              style={{ justifyContent: "flex-start" }}
            >
              <Icon name="download" size={16} />
              {t("settings.exportCsv")}
            </button>
          </div>
          <div className="divider" />
          <div className="field">
            <input
              ref={fileRef}
              type="file"
              accept=".json,.csv,.txt,application/json,text/csv,text/plain"
              onChange={handlePickFile}
              style={{ display: "none" }}
            />
            <button
              className="btn"
              type="button"
              onClick={() => fileRef.current?.click()}
              style={{ justifyContent: "flex-start" }}
            >
              <Icon name="upload" size={16} />
              {t("settings.importData")}
            </button>
            <span className="hint">{t("settings.importHint")}</span>
          </div>
          <div className="divider" />
          <button
            className="btn btn-danger"
            type="button"
            onClick={() => setWipeOpen(true)}
            style={{ justifyContent: "flex-start" }}
          >
            <Icon name="trash" size={16} />
            {t("settings.wipeData")}
          </button>
        </SectionCard>

        {/* 关于 */}
        <div style={{ gridColumn: "1 / -1" }}>
          <SectionCard icon="info" title={t("settings.about")}>
            <div style={{ display: "flex", flexDirection: "column", gap: "var(--sp-3)" }}>
              <div className="row-flex" style={{ gap: "var(--sp-2)" }}>
                <span className="label">{t("settings.version")}</span>
                <span className="mono">0.1.0</span>
                <span
                  className="chip chip-mastered"
                  style={{ marginLeft: "auto" }}
                >
                  Lexilo · 词屿
                </span>
              </div>
              <p className="muted" style={{ fontSize: "var(--fs-sm)", margin: 0 }}>
                {t("settings.madeWith")}
              </p>
              {/* AGPL-3.0 §7(b) additional term: this attribution must stay visible. */}
              <div
                style={{
                  borderLeft: "2px solid var(--line)",
                  paddingLeft: "var(--sp-3)",
                  display: "flex",
                  flexDirection: "column",
                  gap: 4,
                }}
              >
                <span style={{ fontSize: "var(--fs-sm)" }}>
                  Lingueez — created by Yurii Lysak
                </span>
                <span className="tiny muted">{t("settings.licenseNote")}</span>
              </div>
              <div className="divider" />
              <div className="row-flex" style={{ gap: 8 }}>
                <Icon name="keyboard" size={16} />
                <span className="label">{t("settings.shortcuts")}</span>
              </div>
              <div
                style={{
                  display: "grid",
                  gridTemplateColumns: "1fr auto",
                  rowGap: 8,
                  columnGap: "var(--sp-6)",
                  alignItems: "center",
                }}
              >
                <Shortcut
                  label={t("settings.shortcutAdd")}
                  keys={
                    <>
                      <Kbd>Ctrl</Kbd> + <Kbd>N</Kbd>
                    </>
                  }
                />
                <Shortcut
                  label={t("settings.shortcutSearch")}
                  keys={
                    <>
                      <Kbd>Ctrl</Kbd> + <Kbd>F</Kbd>
                    </>
                  }
                />
                <Shortcut label={t("settings.shortcutFlip")} keys={<Kbd>Space</Kbd>} />
                <Shortcut
                  label={`${t("flashcards.gradeHard")} / ${t("flashcards.gradeGood")} / ${t("flashcards.gradeEasy")}`}
                  keys={
                    <>
                      <Kbd>1</Kbd> <Kbd>2</Kbd> <Kbd>3</Kbd>
                    </>
                  }
                />
              </div>
            </div>
          </SectionCard>
        </div>
      </div>

      {/* 导入预览 */}
      <Modal
        open={preview !== null}
        onClose={() => setPreview(null)}
        title={t("settings.importData")}
        subtitle={preview?.fileName}
        width={520}
        footer={
          <>
            <button className="btn" type="button" onClick={() => setPreview(null)}>
              {t("common.cancel")}
            </button>
            <button className="btn btn-primary" type="button" onClick={confirmImport}>
              {t("common.import")}
            </button>
          </>
        }
      >
        {preview && (
          <div className="stack" style={{ gap: "var(--sp-3)" }}>
            <div className="row-flex wrap" style={{ gap: 8 }}>
              <span className="chip chip-mastered">
                {formatLabel(preview.result.format)}
              </span>
              <span className="chip chip-tag">
                {preview.result.words.length} 个词语
              </span>
              {preview.result.skipped > 0 && (
                <span className="chip chip-learning">
                  跳过 {preview.result.skipped} 行
                </span>
              )}
            </div>
            <div
              className="card"
              style={{ maxHeight: 200, overflow: "auto", boxShadow: "none" }}
            >
              <div className="list">
                {preview.result.words.slice(0, 8).map((word, index) => (
                  <div
                    key={`${word.term}-${index}`}
                    className="row"
                    style={{
                      gridTemplateColumns: "minmax(0, 1fr) minmax(0, 1.4fr)",
                      cursor: "default",
                      padding: "8px 14px",
                    }}
                  >
                    <div className="row-term" style={{ fontSize: "var(--fs-base)" }}>
                      {word.term}
                    </div>
                    <div className="row-def">{word.definition || "—"}</div>
                  </div>
                ))}
              </div>
            </div>
            {preview.result.words.length > 8 && (
              <div className="hint">
                还有 {preview.result.words.length - 8} 个词语未展示…
              </div>
            )}
          </div>
        )}
      </Modal>

      {/* 清空确认 */}
      <ConfirmDialog
        open={wipeOpen}
        title={t("settings.wipeConfirm")}
        body={t("settings.wipeConfirmBody")}
        confirmLabel={t("settings.wipeData")}
        cancelLabel={t("common.cancel")}
        onCancel={() => setWipeOpen(false)}
        onConfirm={() => {
          setWipeOpen(false);
          void wipeAll().then(() => toast(t("common.success"), "ok"));
        }}
      />
    </PageShell>
  );
}
