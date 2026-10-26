import { useEffect, useRef, useState, type ChangeEvent, type ReactNode } from "react";
import { Icon, type IconName } from "@/components/Icon";
import { ConfirmDialog, Modal, PageShell, Segmented, ShortcutRow, useToast } from "@/components/ui";
import { useLang, useT } from "@/i18n";
import {
  DEFAULT_LIST_ID,
  addWord,
  findDuplicate,
  getData,
  updateSettings,
  useAppData,
  wipeAll,
} from "@/lib/store";
import { onVoicesChanged, speak, speechSupported, voicesFor, type VoiceInfo } from "@/lib/tts";
import { clearLookupCache, lookupCacheSize } from "@/lib/translate";
import { exportCsv, exportJson, parseImport, type ImportResult } from "@/lib/transfer";
import type { ThemeMode, UiLang } from "@/lib/types";
import { clamp, dayKey, downloadText } from "@/lib/utils";
import "@/styles/insights.css";

/* ------------------------------------------------------------------ */
/* Local building blocks                                               */
/* ------------------------------------------------------------------ */

function Section({
  icon,
  title,
  note,
  children,
}: {
  icon: IconName;
  title: string;
  note?: string;
  children: ReactNode;
}) {
  return (
    <section className="set-section">
      <header className="set-section-head">
        <span className="set-section-ico">
          <Icon name={icon} size={14} />
        </span>
        <h2 className="set-section-title">{title}</h2>
        {note && <span className="set-section-note">{note}</span>}
      </header>
      <div className="set-rows">{children}</div>
    </section>
  );
}

function Row({
  label,
  hint,
  children,
}: {
  label: string;
  hint?: string;
  children: ReactNode;
}) {
  return (
    <div className="set-row">
      <div className="set-text">
        <span className="set-label">{label}</span>
        {hint && <span className="set-hint">{hint}</span>}
      </div>
      <div className="set-ctl">{children}</div>
    </div>
  );
}

function Switch({
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
      className="switch"
      onClick={() => onChange(!checked)}
    >
      <span className="switch-knob" />
    </button>
  );
}

/* ------------------------------------------------------------------ */
/* Page                                                                */
/* ------------------------------------------------------------------ */

export function SettingsPage() {
  const t = useT();
  const lang = useLang();
  const zh = lang === "zh-CN";
  const toast = useToast();
  const data = useAppData();
  const settings = data.settings;

  const listId = data.lists[0]?.id ?? DEFAULT_LIST_ID;
  const studyLang = data.lists[0]?.sourceLang ?? "en";
  const supported = speechSupported();

  const [voices, setVoices] = useState<VoiceInfo[]>(() => voicesFor(studyLang));
  const [preview, setPreview] = useState<{ result: ImportResult; fileName: string } | null>(null);
  const [wipeOpen, setWipeOpen] = useState(false);
  const [busy, setBusy] = useState(false);
  const [cacheSize, setCacheSize] = useState(() => lookupCacheSize());
  const fileRef = useRef<HTMLInputElement>(null);

  useEffect(() => onVoicesChanged(() => setVoices(voicesFor(studyLang))), [studyLang]);

  /* ---------------------------------------------------------------- */
  /* Export                                                           */
  /* ---------------------------------------------------------------- */

  const handleExportJson = () => {
    downloadText(
      `lexumo-backup-${dayKey(Date.now())}.json`,
      exportJson(data),
      "application/json;charset=utf-8",
    );
    toast(zh ? "已导出 JSON 备份" : "JSON backup exported", "ok");
  };

  const handleExportCsv = () => {
    downloadText(
      `lexumo-words-${dayKey(Date.now())}.csv`,
      exportCsv(data.words),
      "text/csv;charset=utf-8",
    );
    toast(zh ? "已导出 CSV" : "CSV exported", "ok");
  };

  /* ---------------------------------------------------------------- */
  /* Import                                                           */
  /* ---------------------------------------------------------------- */

  const handlePickFile = async (e: ChangeEvent<HTMLInputElement>) => {
    const file = e.currentTarget.files?.[0];
    if (!file) return;
    setBusy(true);
    try {
      const text = await file.text();
      const result = parseImport(text, listId);
      if (result.format === "unknown" || result.words.length === 0) {
        toast(
          t("settings.importFailed", {
            msg: zh ? "无法识别文件格式，或文件中没有可导入的词语" : "unrecognised format or no words found",
          }),
          "err",
        );
      } else {
        setPreview({ result, fileName: file.name });
      }
    } catch (err) {
      toast(
        t("settings.importFailed", {
          msg: err instanceof Error ? err.message : String(err),
        }),
        "err",
      );
    } finally {
      setBusy(false);
      if (fileRef.current) fileRef.current.value = "";
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
    if (added > 0) toast(t("settings.importSuccess", { n: added }), "ok");
    if (duplicated > 0) {
      toast(zh ? `已跳过 ${duplicated} 个重复词语` : `Skipped ${duplicated} duplicate words`, "info");
    }
    if (added === 0 && duplicated === 0) {
      toast(t("settings.importFailed", { msg: zh ? "没有可导入的词语" : "nothing to import" }), "err");
    }
  };

  /* ---------------------------------------------------------------- */
  /* Danger + voice                                                   */
  /* ---------------------------------------------------------------- */

  const handleWipe = () => {
    setWipeOpen(false);
    void wipeAll().then(() => toast(t("common.success"), "ok"));
  };

  const testVoice = () => {
    if (!supported) {
      toast(t("settings.noVoice"), "err");
      return;
    }
    const sample =
      data.words[0]?.term ?? (zh ? "你好，欢迎使用词砚。" : "Hello, welcome to Lexumo.");
    speak(sample, {
      lang: studyLang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI || undefined,
    });
  };

  const formatLabel = (format: ImportResult["format"]) =>
    format === "json"
      ? zh
        ? "Lexumo JSON 备份"
        : "Lexumo JSON backup"
      : format === "csv"
        ? "CSV"
        : format === "anki"
          ? "Anki TXT"
          : zh
            ? "未知格式"
            : "Unknown";

  return (
    <PageShell title={t("settings.title")} subtitle={t("settings.subtitle")}>
      <div className="set-page">
        <div className="card">
          {/* 外观 ------------------------------------------------------ */}
          <Section icon="sun" title={t("settings.appearance")}>
            <Row
              label={t("settings.theme")}
              hint={zh ? "浅色、深色，或跟随操作系统的外观。" : "Light, dark, or follow the system."}
            >
              <Segmented<ThemeMode>
                value={settings.theme}
                ariaLabel={t("settings.theme")}
                options={[
                  { value: "light", label: t("common.light") },
                  { value: "dark", label: t("common.dark") },
                  { value: "system", label: t("common.system") },
                ]}
                onChange={(theme) => updateSettings({ theme })}
              />
            </Row>
            <Row
              label={t("settings.language")}
              hint={zh ? "界面文字语言，不影响词库内容。" : "UI language only; word data is unchanged."}
            >
              <Segmented<UiLang>
                value={settings.uiLang}
                ariaLabel={t("settings.language")}
                options={[
                  { value: "zh-CN", label: "中文" },
                  { value: "en", label: "English" },
                ]}
                onChange={(uiLang) => updateSettings({ uiLang })}
              />
            </Row>
          </Section>

          <hr className="divider" />

          {/* 学习 ------------------------------------------------------ */}
          <Section icon="target" title={t("settings.study")}>
            <Row
              label={t("settings.dailyGoal")}
              hint={zh ? "统计页的目标环按这个次数计算。" : "Drives the goal ring on the stats page."}
            >
              <input
                className="input set-num"
                type="number"
                min={1}
                max={500}
                value={settings.dailyGoal}
                aria-label={t("settings.dailyGoal")}
                onChange={(e) => {
                  const n = Number.parseInt(e.target.value, 10);
                  if (Number.isFinite(n)) updateSettings({ dailyGoal: clamp(n, 1, 500) });
                }}
              />
            </Row>
            <Row
              label={t("settings.newCardsPerDay")}
              hint={zh ? "每次复习会话最多引入的新卡片数量。" : "How many unseen cards a session may introduce."}
            >
              <input
                className="input set-num"
                type="number"
                min={0}
                max={200}
                value={settings.newCardsPerDay}
                aria-label={t("settings.newCardsPerDay")}
                onChange={(e) => {
                  const n = Number.parseInt(e.target.value, 10);
                  if (Number.isFinite(n)) updateSettings({ newCardsPerDay: clamp(n, 0, 200) });
                }}
              />
            </Row>
            <Row
              label={t("settings.reviewOrder")}
              hint={zh ? "按到期时间最久优先，或随机打散。" : "Earliest due first, or shuffled."}
            >
              <Segmented<"due" | "random">
                value={settings.reviewOrder}
                ariaLabel={t("settings.reviewOrder")}
                options={[
                  { value: "due", label: t("settings.orderDue") },
                  { value: "random", label: t("settings.orderRandom") },
                ]}
                onChange={(reviewOrder) => updateSettings({ reviewOrder })}
              />
            </Row>
          </Section>

          <hr className="divider" />

          {/* 发音 ------------------------------------------------------ */}
          <Section
            icon="volume"
            title={t("settings.audio")}
            note={supported ? undefined : t("settings.noVoice")}
          >
            <Row
              label={t("settings.ttsVoice")}
              hint={zh ? "朗读词语时使用的系统音色。" : "System voice used for pronunciation."}
            >
              <select
                className="select"
                value={settings.ttsVoiceURI}
                aria-label={t("settings.ttsVoice")}
                disabled={!supported}
                onChange={(e) => updateSettings({ ttsVoiceURI: e.target.value })}
              >
                <option value="">{t("settings.ttsVoiceAuto")}</option>
                {voices.map((voice) => (
                  <option key={voice.uri} value={voice.uri}>
                    {voice.name} · {voice.lang}
                  </option>
                ))}
              </select>
              <button
                type="button"
                className="btn btn-sm btn-quiet"
                onClick={testVoice}
                disabled={!supported}
              >
                {t("settings.testVoice")}
              </button>
            </Row>
            <Row
              label={t("settings.ttsRate")}
              hint={zh ? "0.5× 更慢，1.5× 更快。" : "0.5× slower, 1.5× faster."}
            >
              <input
                className="range set-range"
                type="range"
                min={0.5}
                max={1.5}
                step={0.05}
                value={settings.ttsRate}
                aria-label={t("settings.ttsRate")}
                onChange={(e) => updateSettings({ ttsRate: Number(e.target.value) })}
              />
              <span className="set-rate">{settings.ttsRate.toFixed(2)}×</span>
            </Row>
            <Row
              label={t("settings.autoPlay")}
              hint={zh ? "翻开卡片背面后自动朗读词语。" : "Speak the word when a card is revealed."}
            >
              <Switch
                checked={settings.autoPlayAudio}
                label={t("settings.autoPlay")}
                onChange={(autoPlayAudio) => updateSettings({ autoPlayAudio })}
              />
            </Row>
            <Row
              label={t("settings.audioFirst")}
              hint={zh ? "先听发音，再决定是否看释义。" : "Hear the word first, then reveal the meaning."}
            >
              <Switch
                checked={settings.audioFirst}
                label={t("settings.audioFirst")}
                onChange={(audioFirst) => updateSettings({ audioFirst })}
              />
            </Row>
          </Section>

          <hr className="divider" />

          {/* 词典 ------------------------------------------------------ */}
          <Section
            icon="book"
            title={t("settings.dictionary")}
            note={zh ? "自动查词" : "Auto lookup"}
          >
            <Row label={t("settings.autoTranslate")} hint={t("settings.autoTranslateHint")}>
              <Switch
                checked={settings.autoTranslate}
                label={t("settings.autoTranslate")}
                onChange={(autoTranslate) => updateSettings({ autoTranslate })}
              />
            </Row>
            <Row
              label={t("settings.translateCache")}
              hint={t("settings.translateCacheHint", { n: cacheSize })}
            >
              <button
                className="btn btn-sm"
                type="button"
                disabled={cacheSize === 0}
                onClick={() => {
                  clearLookupCache();
                  setCacheSize(0);
                  toast(t("settings.cacheCleared"), "ok");
                }}
              >
                <Icon name="trash" size={13} />
                {t("settings.clearCache")}
              </button>
            </Row>
          </Section>

          <hr className="divider" />

          {/* 数据 ------------------------------------------------------ */}
          <Section
            icon="layers"
            title={t("settings.data")}
            note={zh ? `${data.words.length} 词 · ${data.logs.length} 条记录` : `${data.words.length} words`}
          >
            <Row
              label={t("settings.exportJson")}
              hint={zh ? "包含词库、复习记录与设置的完整快照。" : "Full snapshot: lists, words, logs, settings."}
            >
              <button type="button" className="btn btn-sm" onClick={handleExportJson}>
                {t("common.export")}
              </button>
            </Row>
            <Row
              label={t("settings.exportCsv")}
              hint={zh ? "只导出词语表格，便于在 Excel 中编辑。" : "Words only, handy for spreadsheets."}
            >
              <button type="button" className="btn btn-sm" onClick={handleExportCsv}>
                {t("common.export")}
              </button>
            </Row>
            <Row label={t("settings.importData")} hint={t("settings.importHint")}>
              <button
                type="button"
                className="btn btn-sm"
                onClick={() => fileRef.current?.click()}
                disabled={busy}
              >
                {busy ? t("common.loading") : zh ? "选择文件…" : "Choose file…"}
              </button>
            </Row>

            <div className="notice notice-danger">
              <span className="notice-ico">
                <Icon name="alert" size={16} />
              </span>
              <div>
                <div className="notice-title">{t("settings.wipeData")}</div>
                <p className="notice-body">{t("settings.wipeConfirmBody")}</p>
                <div className="danger-actions">
                  <button
                    type="button"
                    className="btn btn-danger btn-sm"
                    onClick={() => setWipeOpen(true)}
                  >
                    {t("settings.wipeData")}
                  </button>
                </div>
              </div>
            </div>
          </Section>
        </div>

        {/* 关于 -------------------------------------------------------- */}
        <section className="card">
          <div className="card-head">
            <div>
              <div className="card-title">{t("settings.about")}</div>
              <div className="card-sub">Lexumo · 词砚</div>
            </div>
          </div>
          <div className="card-pad about-body">
            <div className="about-meta">
              <span className="chip chip-tag">{t("settings.version")} 0.1.0</span>
              <span className="tiny muted">Tauri 2 · React 19 · TypeScript</span>
            </div>
            <p className="about-desc">{t("settings.madeWith")}</p>
            {/* AGPL-3.0 §7(b) additional term: this attribution must stay visible. */}
            <div className="about-credit">
              <span className="about-credit-name">Lingueez — created by Yurii Lysak</span>
              <span className="tiny muted">{t("settings.licenseNote")}</span>
            </div>
            <hr className="divider" />
            <div>
              <div className="label" style={{ marginBottom: "var(--sp-2)" }}>
                {t("settings.shortcuts")}
              </div>
              <div className="shortcuts">
                <ShortcutRow keys={["Ctrl", "N"]} label={t("settings.shortcutAdd")} />
                <ShortcutRow keys={["Ctrl", "F"]} label={t("settings.shortcutSearch")} />
                <ShortcutRow keys={["Space"]} label={t("settings.shortcutFlip")} />
                <ShortcutRow
                  keys={["1", "2", "3"]}
                  label={zh ? "评分：困难 / 记得 / 简单" : "Grade: hard / good / easy"}
                />
              </div>
            </div>
          </div>
        </section>
      </div>

      {/* Hidden file input + import preview ------------------------- */}
      <input
        ref={fileRef}
        type="file"
        className="sr-only"
        accept=".json,.csv,.txt,application/json,text/csv,text/plain"
        onChange={handlePickFile}
      />

      <Modal
        open={preview !== null}
        onClose={() => setPreview(null)}
        title={zh ? "导入预览" : "Import preview"}
        subtitle={
          preview ? `${preview.fileName} · ${formatLabel(preview.result.format)}` : undefined
        }
        width={520}
        footer={
          <>
            <button type="button" className="btn btn-ghost" onClick={() => setPreview(null)}>
              {t("common.cancel")}
            </button>
            <button type="button" className="btn btn-primary" onClick={confirmImport}>
              {t("common.import")} · {preview?.result.words.length ?? 0}
            </button>
          </>
        }
      >
        {preview && (
          <div className="stack">
            <div className="tag-row">
              <span className="chip chip-tag">{formatLabel(preview.result.format)}</span>
              <span className="chip chip-tag">
                {preview.result.words.length} {zh ? "个词语" : "words"}
              </span>
              {preview.result.skipped > 0 && (
                <span className="chip chip-tag">
                  {zh ? `跳过 ${preview.result.skipped} 行` : `${preview.result.skipped} rows skipped`}
                </span>
              )}
            </div>
            <div className="import-preview">
              {preview.result.words.slice(0, 8).map((word, index) => (
                <div className="row" key={`${word.term}-${index}`}>
                  <div className="row-term">{word.term}</div>
                  <div className="row-def">{word.definition || "—"}</div>
                </div>
              ))}
            </div>
            {preview.result.words.length > 8 && (
              <div className="import-more">
                {zh
                  ? `还有 ${preview.result.words.length - 8} 个词语未展示…`
                  : `…and ${preview.result.words.length - 8} more`}
              </div>
            )}
          </div>
        )}
      </Modal>

      <ConfirmDialog
        open={wipeOpen}
        title={t("settings.wipeConfirm")}
        body={t("settings.wipeConfirmBody")}
        confirmLabel={t("settings.wipeData")}
        cancelLabel={t("common.cancel")}
        onConfirm={handleWipe}
        onCancel={() => setWipeOpen(false)}
      />
    </PageShell>
  );
}
