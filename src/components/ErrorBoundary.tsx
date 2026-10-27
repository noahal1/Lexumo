/**
 * The last line of defence for a render crash.
 *
 * Without this, a thrown render error unmounts the whole tree and leaves a
 * blank window — the worst possible outcome for a local-first app, because the
 * data is still there and the user has no way to tell that from data loss.
 *
 * The fallback therefore says three things and nothing else: what happened,
 * that the words are safe, and the one action that recovers. It is translated
 * through the same dictionary as the rest of the shell, so the boundary sits
 * inside `I18nProvider`.
 */
import { Component, type ErrorInfo, type ReactNode } from "react";
import { useT, type TFunc } from "@/i18n";
import { reportError } from "@/lib/errors";

type Props = { children: ReactNode; t: TFunc };
type State = { failed: boolean };

class Boundary extends Component<Props, State> {
  state: State = { failed: false };

  static getDerivedStateFromError(): State {
    return { failed: true };
  }

  componentDidCatch(error: Error, info: ErrorInfo): void {
    reportError("render", { error, componentStack: info.componentStack });
  }

  render(): ReactNode {
    if (!this.state.failed) return this.props.children;
    const { t } = this.props;
    return (
      <div className="crash" role="alert">
        <div className="crash-card">
          <h1 className="crash-title">{t("errors.crashTitle")}</h1>
          <p className="crash-body">{t("errors.crashBody")}</p>
          <button
            className="btn btn-primary"
            type="button"
            onClick={() => window.location.reload()}
          >
            {t("errors.reload")}
          </button>
        </div>
      </div>
    );
  }
}

export function ErrorBoundary({ children }: { children: ReactNode }) {
  const t = useT();
  return <Boundary t={t}>{children}</Boundary>;
}
