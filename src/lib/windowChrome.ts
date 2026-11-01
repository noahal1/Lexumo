/**
 * Window chrome, kept behind one seam.
 *
 * The app also runs as a plain web page (`npm run dev` in a browser, and every
 * headless probe in `.shots/`). There is no window to minimize there, so the
 * title bar renders nothing at all rather than three buttons that do nothing.
 * The check is a property of the shell, not of the build, which is why it lives
 * here instead of behind `import.meta.env`.
 *
 * Three shells, not two: browser, desktop window, and the Android/iOS build.
 * Mobile is also a Tauri shell — `__TAURI_INTERNALS__` is there too — but it is
 * not a *window*: there is no decorated frame to drag, nothing to minimize, and
 * the system draws its own status bar and back affordance. So the desktop check
 * is "Tauri AND not mobile", and the UA is the only signal the webview gives us
 * without pulling in the OS plugin for one boolean.
 *
 * `@tauri-apps/api` is imported dynamically so the browser bundle never pulls
 * it in and a jsdom test never touches it.
 *
 * Every call is guarded: the window manager belongs to the shell, and if it
 * refuses (a window already gone, a shell that exposes only part of the API)
 * there is nothing to tell the user that they could act on, so nothing is
 * surfaced and no rejection escapes.
 */

type WindowAction = "minimize" | "maximize" | "close";

/** True inside any Tauri shell — desktop or mobile. */
function isTauriShell(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

/**
 * True on a phone/tablet build. Android's WebView always puts "Android" in the
 * UA and iOS puts "iPhone"/"iPad"/"iPod"; a desktop browser never does, so this
 * cannot misfire on a narrow desktop window (which gets the rail layout, not
 * the phone one — see `useMobile` in App.tsx).
 */
export function isMobileShell(): boolean {
  if (!isTauriShell()) return false;
  const ua = typeof navigator === "undefined" ? "" : navigator.userAgent;
  return /Android|iPhone|iPad|iPod/i.test(ua);
}

/** True only inside the Tauri shell on a desktop OS, where a real window exists. */
export function isDesktopShell(): boolean {
  return isTauriShell() && !isMobileShell();
}

async function currentWindow() {
  const { getCurrentWindow } = await import("@tauri-apps/api/window");
  return getCurrentWindow();
}

export async function windowAction(action: WindowAction): Promise<void> {
  if (!isDesktopShell()) return;
  try {
    const win = await currentWindow();
    if (action === "minimize") await win.minimize();
    else if (action === "close") await win.close();
    else await win.toggleMaximize();
  } catch {
    /* Nothing the user could do about it; see the note above. */
  }
}

/**
 * Calls `listener` whenever the window is resized, and immediately once, so the
 * maximize/restore glyph is right on first paint. Returns an unsubscribe that is
 * safe to call before the async subscription has finished.
 */
export function watchMaximized(listener: (maximized: boolean) => void): () => void {
  if (!isDesktopShell()) return () => {};

  let alive = true;
  let unlisten: (() => void) | undefined;

  void (async () => {
    try {
      const win = await currentWindow();
      const publish = async () => {
        const maximized = await win.isMaximized();
        if (alive) listener(maximized);
      };
      await publish();
      const stop = await win.onResized(() => {
        void publish();
      });
      if (alive) unlisten = stop;
      else stop();
    } catch {
      /* No window events available; the glyph simply stays on "maximize". */
    }
  })();

  return () => {
    alive = false;
    unlisten?.();
  };
}
