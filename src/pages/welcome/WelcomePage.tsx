/**
 * The first-run gate: sign in for sync, or stay on this device.
 *
 * Deliberately not a separate route. It renders inside the app shell's grid,
 * below the window title bar, because the desktop window is undecorated
 * (`decorations: false`): without that bar there is no way to drag, minimize or
 * close the window, and a gate that traps the user in a frameless window is
 * worse than no gate at all.
 *
 * The two choices are presented as two doors of equal legitimacy rather than a
 * form with a "skip" escape hatch, because local-only is the app's default
 * posture (`docs/` calls it offline-first) and not a degraded mode. Everything
 * the sync form does here is the same three calls the settings section makes;
 * this file owns the presentation, `lib/sync.ts` owns the behaviour.
 */
import { useState } from "react";

import { Icon } from "@/components/Icon";
import { useT } from "@/i18n";
import { completeOnboarding } from "@/lib/onboarding";
import {
  DEFAULT_SERVER,
  login,
  register,
  syncNow,
  testConnection,
  type SyncError,
} from "@/lib/sync";
import { syncErrorKey } from "@/pages/settings/SyncSection";

import "@/styles/welcome.css";

export function WelcomePage() {
  const t = useT();

  const [server, setServer] = useState(DEFAULT_SERVER);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState<"signin" | "signup" | "test" | null>(null);
  const [error, setError] = useState<SyncError | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const handleAuth = async (mode: "signin" | "signup") => {
    if (busy) return;
    setError(null);
    setNotice(null);
    if (!email.trim() || !password) {
      setError("bad_credentials");
      return;
    }
    setBusy(mode);
    try {
      if (mode === "signup") await register(server, email.trim(), password);
      else await login(server, email.trim(), password);
      // The gate is answered by a successful sign-in, not by the button press:
      // an unreachable server must leave the user here with a reason, not drop
      // them into an app that will silently never sync.
      completeOnboarding("sync");
      void syncNow();
    } catch (err) {
      setError((err as { kind?: SyncError }).kind ?? "offline");
    } finally {
      setBusy(null);
    }
  };

  const handleTest = async () => {
    if (busy) return;
    setBusy("test");
    setError(null);
    setNotice(null);
    const ok = await testConnection(server);
    if (ok) setNotice(t("settings.syncTestOk"));
    else setError("offline");
    setBusy(null);
  };

  return (
    <div className="welcome">
      <div className="welcome-frame">
        <div className="welcome-brand">
          <img className="welcome-mark" src="/icon.svg" alt="" width={36} height={36} />
          <div className="welcome-brand-text">
            <div className="welcome-name">{t("common.appName")}</div>
            <div className="welcome-sub">{t("shell.brandSub")}</div>
          </div>
        </div>
        <p className="welcome-tagline">{t("common.appTagline")}</p>
      </div>

      <div className="welcome-paper">
        <div className="welcome-inner">
          <header className="welcome-head">
            <h1 className="welcome-title">{t("welcome.title")}</h1>
            <p className="welcome-lead">{t("welcome.lead")}</p>
          </header>

          <form
            className="welcome-form"
            onSubmit={(e) => {
              e.preventDefault();
              void handleAuth("signin");
            }}
          >
            <div className="welcome-field">
              <label className="welcome-label" htmlFor="welcome-email">
                {t("settings.syncEmail")}
              </label>
              <input
                id="welcome-email"
                className="input"
                type="email"
                value={email}
                onChange={(e) => setEmail(e.currentTarget.value)}
                autoComplete="username"
                spellCheck={false}
                disabled={busy !== null}
              />
            </div>

            <div className="welcome-field">
              <label className="welcome-label" htmlFor="welcome-password">
                {t("settings.syncPassword")}
              </label>
              <input
                id="welcome-password"
                className="input"
                type="password"
                value={password}
                onChange={(e) => setPassword(e.currentTarget.value)}
                autoComplete="current-password"
                disabled={busy !== null}
                aria-describedby="welcome-password-hint"
              />
              <span className="welcome-hint" id="welcome-password-hint">
                {t("settings.syncPasswordHint")}
              </span>
            </div>

            <details className="welcome-advanced">
              <summary>
                <span className="welcome-caret">
                  <Icon name="chevron-down" size={14} />
                </span>
                {t("welcome.advanced")}
              </summary>
              <div className="welcome-field welcome-advanced-field">
                <input
                  className="input"
                  value={server}
                  onChange={(e) => setServer(e.currentTarget.value)}
                  placeholder={DEFAULT_SERVER}
                  aria-label={t("welcome.advanced")}
                  spellCheck={false}
                  autoComplete="off"
                  disabled={busy !== null}
                />
                <div className="welcome-advanced-actions">
                  <span className="welcome-hint">{t("settings.syncServerHint")}</span>
                  <button
                    type="button"
                    className="btn btn-quiet btn-sm"
                    onClick={() => void handleTest()}
                    disabled={busy !== null}
                  >
                    {busy === "test" ? t("common.loading") : t("settings.syncTest")}
                  </button>
                </div>
              </div>
            </details>

            {error && (
              <p className="welcome-error" role="alert">
                <Icon name="alert" size={14} />
                {t(syncErrorKey(error))}
              </p>
            )}
            {notice && !error && <p className="welcome-notice">{notice}</p>}

            <div className="welcome-actions">
              <button type="submit" className="btn btn-primary" disabled={busy !== null}>
                {busy === "signin" ? t("welcome.signingIn") : t("settings.syncSignIn")}
              </button>
              <button
                type="button"
                className="btn"
                onClick={() => void handleAuth("signup")}
                disabled={busy !== null}
              >
                {busy === "signup" ? t("welcome.signingUp") : t("settings.syncSignUp")}
              </button>
            </div>
          </form>

          <div className="welcome-or">
            <span>{t("welcome.or")}</span>
          </div>

          <button
            type="button"
            className="welcome-local"
            onClick={() => completeOnboarding("local")}
          >
            <span className="welcome-local-text">
              <span className="welcome-local-title">{t("welcome.localTitle")}</span>
              <span className="welcome-local-body">{t("welcome.localBody")}</span>
            </span>
            <span className="welcome-local-go">
              <Icon name="arrow-right" size={16} />
            </span>
          </button>
        </div>
      </div>
    </div>
  );
}
