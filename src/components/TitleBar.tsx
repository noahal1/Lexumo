/**
 * The window title bar.
 *
 * The desktop window runs undecorated, so this is the only chrome above the
 * app: the seal, the name, and the three system buttons. It is stone, like the
 * sidebar, so the two read as one frame around the paper.
 *
 * Dragging: Tauri's own script listens for `mousedown` and, for a bare
 * `data-tauri-drag-region`, only drags when the *bar itself* is the target —
 * which would leave the name and the gaps dead. `="deep"` makes the whole
 * subtree draggable, and `BUTTON` is in its clickable list, so the three
 * controls stay clickable without opting out. Double-click to maximize comes
 * from the same script, so there is no handler for it here.
 */
import { useEffect, useState } from "react";

import { Icon } from "@/components/Icon";
import { useT } from "@/i18n";
import { isDesktopShell, watchMaximized, windowAction } from "@/lib/windowChrome";

export function TitleBar() {
  const t = useT();
  const desktop = isDesktopShell();
  const [maximized, setMaximized] = useState(false);

  useEffect(() => {
    if (!desktop) return;
    return watchMaximized(setMaximized);
  }, [desktop]);

  if (!desktop) return null;

  const label = maximized ? t("shell.restore") : t("shell.maximize");

  return (
    <header className="frame-bar" data-tauri-drag-region="deep">
      <div className="frame-bar-brand">
        <img className="frame-bar-mark" src="/icon.svg" alt="" width={16} height={16} />
        <span className="frame-bar-name">{t("common.appName")}</span>
        <span className="frame-bar-sub">{t("shell.brandSub")}</span>
      </div>

      <div className="frame-bar-controls">
        <button
          type="button"
          className="wctl"
          onClick={() => void windowAction("minimize")}
          aria-label={t("shell.minimize")}
          title={t("shell.minimize")}
        >
          <Icon name="minimize" size={14} />
        </button>
        <button
          type="button"
          className="wctl"
          onClick={() => void windowAction("maximize")}
          aria-label={label}
          title={label}
        >
          <Icon name={maximized ? "restore" : "maximize"} size={14} />
        </button>
        <button
          type="button"
          className="wctl wctl-close"
          onClick={() => void windowAction("close")}
          aria-label={t("shell.close")}
          title={t("shell.close")}
        >
          <Icon name="x" size={15} />
        </button>
      </div>
    </header>
  );
}
