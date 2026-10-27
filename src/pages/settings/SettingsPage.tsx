import { useEffect, useRef, useState, useSyncExternalStore, type ChangeEvent } from "react";
import { Icon } from "@/components/Icon";
import { ConfirmDialog, Modal, PageShell, Segmented, ShortcutRow, useToast } from "@/components/ui";
import { useT } from "@/i18n";
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
import { SHORTCUT_HELP } from "@/lib/shortcuts";
import {
  getSyncStatus,
  isSignedIn,
  signOut,
  subscribeSyncStatus,
} from "@/lib/sync";
import { clamp, dayKey, downloadText } from "@/lib/utils";
import "@/styles/insights.css";

import { Row, Section, Switch, useIsMobile } from "./parts";
import { SyncSection, syncStatusLabel } from "./SyncSection";

/* ------------------------------------------------------------------ */
/* Page                                                                */
/* ------------------------------------------------------------------ */

export function SettingsPage() {
  const t = useT();
  const toast = useToast();
  const data = useAppData();
  const settings = data.settings;

  const listId = data.lists[0]?.id ?? DEFAULT_LIST_ID;
  const studyLang = data.lists[0]?.sourceLang ?? "en";
  const supported = speechSupported();

  const mobile = useIsMobile();
  const status = useSyncExternalStore(subscribeSyncStatus, getSyncStatus, getSyncStatus);
  const signedIn = isSignedIn();
  // On a phone the sidebar's sync chip is gone, so this strip is the only
  // ambient sync signal; on desktop it appears only when something needs a look.
  const showSyncStrip = signedIn && (mobile || status.state === "error" || status.pending > 0);
  // The confirm used to promise "无法恢复" while the server copy quietly came
  // back on the next sign-in — say what actually happens instead.
  const wipeBody = signedIn
    ? t("settings.wipeConfirmBodySignedIn")
    : t("settings.wipeConfirmBody");
  const scrollToSync = () =>
    document.getElementById("set-sync")?.scrollIntoView({ block: "start" });

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
    toast(t("settings.exportJsonDone"), "ok");
  };

  const handleExportCsv = () => {
    downloadText(
      `lexumo-words-${dayKey(Date.now())}.csv`,
      exportCsv(data.words),
      "text/csv;charset=utf-8",
    );
    toast(t("settings.exportCsvDone"), "ok");
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
            msg: t("settings.importUnrecognised"),
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
      toast(t("settings.importSkippedDuplicates", { n: duplicated }), "info");
    }
    if (added === 0 && duplicated === 0) {
      toast(t("settings.importFailed", { msg: t("settings.importNothing") }), "err");
    }
  };

  /* ---------------------------------------------------------------- */
  /* Danger + voice                                                   */
  /* ---------------------------------------------------------------- */

  const handleWipe = async () => {
    setWipeOpen(false);
    // Sign out first: while signed in, the next sync round would pull the whole
    // server copy straight back into the freshly emptied local store.
    const wasSignedIn = isSignedIn();
    if (wasSignedIn) await signOut();
    await wipeAll();
    toast(wasSignedIn ? t("settings.wipeDoneSignedOut") : t("settings.wipeDone"), "ok");
  };

  const testVoice = () => {
    if (!supported) {
      toast(t("settings.noVoice"), "err");
      return;
    }
    const sample =
      data.words[0]?.term ?? t("settings.voiceSample");
    speak(sample, {
      lang: studyLang,
      rate: settings.ttsRate,
      voiceURI: settings.ttsVoiceURI || undefined,
    });
  };

  const formatLabel = (format: ImportResult["format"]) =>
    format === "json"
      ? t("settings.formatJson")
      : format === "csv"
        ? "CSV"
        : format === "anki"
          ? "Anki TXT"
          : t("settings.formatUnknown");

  return (
    <PageShell title={t("settings.title")} subtitle={t("settings.subtitle")}>
      <div className="set-page">
        {showSyncStrip && (
          <div className={`notice${status.state === "error" ? " notice-danger" : ""}`}>
            <span className="notice-ico">
              <Icon name={status.state === "error" ? "alert" : "cloud"} size={16} />
            </span>
            <div>
              <div className="notice-title">{syncStatusLabel(t, status, signedIn)}</div>
              {status.state === "error" && (
                <p className="notice-body">{t("settings.syncTopHint")}</p>
              )}
              <div className="danger-actions">
                <button type="button" className="btn btn-sm" onClick={scrollToSync}>
                  {t("settings.syncGoTo")}
                </button>
              </div>
            </div>
          </div>
        )}
        <div className="card">
          {/* 外观 ------------------------------------------------------ */}
          <Section icon="sun" title={t("settings.appearance")}>
            <Row
              label={t("settings.theme")}
              hint={t("settings.themeHint")}
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
              hint={t("settings.languageHint")}
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
              hint={t("settings.dailyGoalHint")}
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
              hint={t("settings.newCardsHint")}
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
              hint={t("settings.orderHint")}
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
              hint={t("settings.voiceHint")}
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
              hint={t("settings.rateHint")}
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
              hint={t("settings.autoPlayHint")}
            >
              <Switch
                checked={settings.autoPlayAudio}
                label={t("settings.autoPlay")}
                onChange={(autoPlayAudio) => updateSettings({ autoPlayAudio })}
              />
            </Row>
            <Row
              label={t("settings.audioFirst")}
              hint={t("settings.audioFirstHint")}
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
            note={t("settings.autoLookupNote")}
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

          {/* 同步 ------------------------------------------------------ */}
          <SyncSection />

          <hr className="divider" />

          {/* 数据 ------------------------------------------------------ */}
          <Section
            icon="layers"
            title={t("settings.data")}
            note={t("settings.dataNote", { words: data.words.length, logs: data.logs.length })}
          >
            <Row
              label={t("settings.exportJson")}
              hint={t("settings.exportJsonHint")}
            >
              <button type="button" className="btn btn-sm" onClick={handleExportJson}>
                {t("common.export")}
              </button>
            </Row>
            <Row
              label={t("settings.exportCsv")}
              hint={t("settings.exportCsvHint")}
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
                {busy ? t("common.loading") : t("settings.chooseFile")}
              </button>
            </Row>

            <div className="notice notice-danger">
              <span className="notice-ico">
                <Icon name="alert" size={16} />
              </span>
              <div>
                <div className="notice-title">{t("settings.wipeData")}</div>
                <p className="notice-body">{wipeBody}</p>
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
              <div className="card-sub">Lexumo 词砚</div>
            </div>
          </div>
          <div className="card-pad about-body">
            <div className="about-meta">
              <span className="chip chip-tag">{t("settings.version")} 0.1.0</span>
              <span className="tiny muted">Tauri 2、React 19、TypeScript</span>
            </div>
            <p className="about-desc">{t("settings.madeWith")}</p>
            {/* AGPL-3.0 §7(b) additional term: this attribution must stay visible. */}
            <div className="about-credit">
              <span className="about-credit-name">Lingueez, created by Yurii Lysak</span>
              <span className="tiny muted">{t("settings.licenseNote")}</span>
            </div>
            <hr className="divider" />
            <div>
              <div className="label" style={{ marginBottom: "var(--sp-2)" }}>
                {t("settings.shortcuts")}
              </div>
              <div className="shortcuts">
                {SHORTCUT_HELP.map((shortcut) => (
                  <ShortcutRow
                    key={shortcut.id}
                    keys={shortcut.keys}
                    label={t(shortcut.labelKey)}
                  />
                ))}
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
        title={t("settings.importPreviewTitle")}
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
                {t("settings.importWordsCount", { n: preview.result.words.length })}
              </span>
              {preview.result.skipped > 0 && (
                <span className="chip chip-tag">
                  {t("settings.importRowsSkipped", { n: preview.result.skipped })}
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
                {t("settings.importMore", { n: preview.result.words.length - 8 })}
              </div>
            )}
          </div>
        )}
      </Modal>

      <ConfirmDialog
        open={wipeOpen}
        title={t("settings.wipeConfirm")}
        body={wipeBody}
        confirmLabel={t("settings.wipeData")}
        cancelLabel={t("common.cancel")}
        onConfirm={handleWipe}
        onCancel={() => setWipeOpen(false)}
      />
    </PageShell>
  );
}
