import { useEffect, useState, useSyncExternalStore } from "react";
import { Icon } from "@/components/Icon";
import { useLang, useT, type MessageKey, type TFunc } from "@/i18n";
import { useAppData, updateSettings } from "@/lib/store";
import {
  DEFAULT_SERVER,
  getSyncStatus,
  isSignedIn,
  login,
  refreshSyncStatus,
  register,
  signOut,
  subscribeSyncStatus,
  syncNow,
  testConnection,
  type SyncError,
  type SyncStatus,
} from "@/lib/sync";
import { relativeDay } from "@/lib/utils";
import { Row, Section, Switch } from "./parts";

const ERROR_KEY: Record<SyncError, MessageKey> = {
  offline: "settings.syncErrorOffline",
  unauthorized: "settings.syncErrorUnauthorized",
  server: "settings.syncErrorServer",
  bad_credentials: "settings.syncErrorBadCredentials",
  email_taken: "settings.syncErrorEmailTaken",
  weak_password: "settings.syncErrorWeakPassword",
  invalid_email: "settings.syncErrorInvalidEmail",
};

/** i18n key for a failure kind, shared with the shell's error toast. */
export function syncErrorKey(err: SyncError): MessageKey {
  return ERROR_KEY[err] ?? "settings.syncErrorServer";
}

/**
 * One wording for every surface that shows sync state (sidebar chip, settings
 * strip, sync section) — three copies used to drift apart.
 */
export function syncStatusLabel(t: TFunc, status: SyncStatus, signedIn: boolean): string {
  if (!signedIn) return t("settings.syncStatusSignedOut");
  if (status.state === "error") return t("settings.syncStatusError");
  if (status.state === "syncing") return t("settings.syncStatusSyncing");
  // "已同步" would be a lie while edits are still queued, so the pending count
  // wins over the idle wording.
  if (status.pending > 0) return t("settings.syncPendingHint", { n: status.pending });
  return t("settings.syncStatusIdle");
}

/** One tone for every surface that shows sync state. */
export function syncStatusTone(
  status: SyncStatus,
  signedIn: boolean,
): "ok" | "busy" | "danger" | "muted" {
  if (!signedIn) return "muted";
  if (status.state === "error") return "danger";
  if (status.state === "syncing" || status.pending > 0) return "busy";
  return "ok";
}

export function SyncSection() {
  const t = useT();
  const lang = useLang();
  const data = useAppData();
  const status = useSyncExternalStore(subscribeSyncStatus, getSyncStatus, getSyncStatus);
  const signedIn = isSignedIn();

  const [server, setServer] = useState(status.server || DEFAULT_SERVER);
  const [email, setEmail] = useState(status.email);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState<"signin" | "signup" | "test" | "sync" | null>(null);
  const [formError, setFormError] = useState<SyncError | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  // Keep the pending counter honest when the user lands on this page.
  useEffect(() => {
    refreshSyncStatus();
  }, []);

  const describe = (err: SyncError | null): string | null =>
    err ? t(syncErrorKey(err)) : null;

  const handleAuth = async (mode: "signin" | "signup") => {
    setFormError(null);
    setNotice(null);
    if (!email.trim() || !password) {
      setFormError("bad_credentials");
      return;
    }
    setBusy(mode);
    try {
      if (mode === "signup") await register(server, email.trim(), password);
      else await login(server, email.trim(), password);
      setPassword("");
      setNotice(t("settings.syncDone"));
      void syncNow();
    } catch (err) {
      setFormError((err as { kind?: SyncError }).kind ?? "offline");
    } finally {
      setBusy(null);
    }
  };

  const handleTest = async () => {
    setBusy("test");
    setFormError(null);
    const ok = await testConnection(server);
    setNotice(ok ? t("settings.syncTestOk") : null);
    if (!ok) setFormError("offline");
    setBusy(null);
  };

  const handleSyncNow = async () => {
    setBusy("sync");
    const ok = await syncNow();
    setBusy(null);
    if (ok) setNotice(t("settings.syncDone"));
  };

  const handleSignOut = async () => {
    await signOut();
    setPassword("");
    setNotice(t("settings.syncSignedOut"));
  };

  // "已同步" would be a lie while edits are still queued, so the pending count
  // wins over the idle wording.
  const statusLabel = syncStatusLabel(t, status, signedIn);
  const statusTone = syncStatusTone(status, signedIn);

  return (
    <Section id="set-sync" icon="cloud" title={t("settings.sync")} note={signedIn ? status.email : undefined}>
      <p className="set-intro">{t("settings.syncIntro")}</p>

      {!signedIn ? (
        <>
          <Row label={t("settings.syncServer")} hint={t("settings.syncServerHint")}>
            <input
              className="input input-sm"
              value={server}
              onChange={(e) => setServer(e.currentTarget.value)}
              placeholder={DEFAULT_SERVER}
              spellCheck={false}
              autoComplete="off"
            />
          </Row>
          <Row label={t("settings.syncEmail")}>
            <input
              className="input input-sm"
              type="email"
              value={email}
              onChange={(e) => setEmail(e.currentTarget.value)}
              placeholder="you@example.com"
              autoComplete="username"
              spellCheck={false}
            />
          </Row>
          <Row label={t("settings.syncPassword")} hint={t("settings.syncPasswordHint")}>
            <input
              className="input input-sm"
              type="password"
              value={password}
              onChange={(e) => setPassword(e.currentTarget.value)}
              autoComplete="current-password"
              onKeyDown={(e) => {
                if (e.key === "Enter") void handleAuth("signin");
              }}
            />
          </Row>

          <div className="set-actions">
            <button
              type="button"
              className="btn btn-primary btn-sm"
              onClick={() => void handleAuth("signin")}
              disabled={busy !== null}
            >
              {busy === "signin" ? t("common.loading") : t("settings.syncSignIn")}
            </button>
            <button
              type="button"
              className="btn btn-sm"
              onClick={() => void handleAuth("signup")}
              disabled={busy !== null}
            >
              {busy === "signup" ? t("common.loading") : t("settings.syncSignUp")}
            </button>
            <button
              type="button"
              className="btn btn-quiet btn-sm"
              onClick={() => void handleTest()}
              disabled={busy !== null}
            >
              {busy === "test" ? t("common.loading") : t("settings.syncTest")}
            </button>
          </div>
        </>
      ) : (
        <>
          <Row label={t("settings.syncStatus")}>
            <div className="sync-status">
              <span className={`sync-dot sync-dot-${statusTone}`} />
              <span className="sync-status-text">{statusLabel}</span>
              {status.state === "error" && status.error && (
                <span className="sync-status-err">{describe(status.error)}</span>
              )}
            </div>
          </Row>
          <Row
            label={t("settings.syncPending")}
            hint={
              status.pending > 0 ? t("settings.syncPendingHint", { n: status.pending }) : undefined
            }
          >
            <span className="mono tiny">{status.pending}</span>
          </Row>
          <Row label={t("settings.syncLastSync")}>
            <span className="tiny muted">
              {status.lastSyncAt ? relativeDay(status.lastSyncAt, lang) : t("settings.syncNever")}
            </span>
          </Row>
          <Row label={t("settings.syncAuto")} hint={t("settings.syncAutoHint")}>
            <Switch
              checked={data.settings.autoSync}
              onChange={(next) => updateSettings({ autoSync: next })}
              label={t("settings.syncAuto")}
            />
          </Row>

          <div className="set-actions">
            <button
              type="button"
              className="btn btn-primary btn-sm"
              onClick={() => void handleSyncNow()}
              disabled={busy !== null || status.state === "syncing"}
            >
              <Icon name="refresh" size={14} />
              {status.state === "syncing" ? t("settings.syncStatusSyncing") : t("settings.syncNow")}
            </button>
            <button
              type="button"
              className="btn btn-quiet btn-sm"
              onClick={() => void handleSignOut()}
              disabled={busy !== null}
            >
              {t("settings.syncSignOut")}
            </button>
          </div>
        </>
      )}

      {formError && (
        <p className="set-error">
          <Icon name="alert" size={14} />
          {describe(formError)}
        </p>
      )}
      {notice && !formError && <p className="set-notice">{notice}</p>}
    </Section>
  );
}
