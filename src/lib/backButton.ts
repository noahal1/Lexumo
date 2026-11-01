/**
 * The Android back affordance, kept behind one seam.
 *
 * Tauri's default back handling is "let the WebView go back, else finish the
 * activity". That is right for a document, and wrong for an app: this app's
 * router is hash-based and opening a bottom sheet pushes no history entry, so
 * pressing back with the editor open went nowhere, and the *next* press killed
 * the process and dropped the user on the launcher with a half-written word
 * still on screen. Measured on the reference phone: sheet open, `history.length`
 * unchanged, first press left the sheet up, second press took the app down.
 *
 * Registering any `back-button` listener makes Tauri stop deciding for us
 * (`AppPlugin.kt`: a listener present means "trigger the event and do nothing
 * else"), so this seam must reproduce the platform behaviour it replaced, in
 * the order a phone user expects:
 *
 *   1. The topmost thing that can be dismissed is dismissed — a sheet closes.
 *   2. Otherwise, if the WebView has history, go back through it, so back still
 *      means "the page I came from".
 *   3. Otherwise there is nothing left to undo, so the app leaves — which is
 *      what back at the root of an Android app does.
 *
 * Only Android fires this event; iOS and the desktop shells have no such
 * affordance and the listener is never installed there.
 */
import { isMobileShell } from "@/lib/windowChrome";

/** Returns true when it consumed the press, so nothing further should happen. */
type BackClaim = () => boolean;

const claims: BackClaim[] = [];

/**
 * Give the caller first refusal on the next back press. The most recently
 * registered claim wins, which is the topmost overlay, because overlays mount
 * in the order they are opened. Returns an unsubscribe.
 */
export function registerBackClaim(claim: BackClaim): () => void {
  claims.push(claim);
  return () => {
    const at = claims.indexOf(claim);
    if (at >= 0) claims.splice(at, 1);
  };
}

/** Installs the shell listener once. Returns a no-op off the mobile shell. */
export function startBackButton(): () => void {
  if (!isMobileShell()) return () => {};

  let alive = true;
  let unlisten: (() => void) | undefined;

  void (async () => {
    try {
      const { onBackButtonPress, exit } = await import("@tauri-apps/api/app");
      const listener = await onBackButtonPress(() => {
        for (let i = claims.length - 1; i >= 0; i--) {
          if (claims[i]()) return;
        }
        /* Nothing left to undo. Back at the root of an Android app leaves it —
           that is the platform's own meaning, not a shortcut out of a mistake.
           The router decides what "nothing left" means, because `history.length`
           also counts the WebView's initial entry. */
        void exit(0);
      });
      if (alive) unlisten = () => void listener.unregister();
      else void listener.unregister();
    } catch {
      /* Without the listener the shell's own default still applies: the worst
         case is the behaviour this seam was added to improve, never a dead
         back button. */
    }
  })();

  return () => {
    alive = false;
    unlisten?.();
  };
}
