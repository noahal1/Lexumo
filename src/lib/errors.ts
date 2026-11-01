/**
 * One place for failures that have no natural owner on screen.
 *
 * Two cases need it. A render crash has to be caught above React's tree, so
 * the boundary cannot call a hook or reach a toast. A failed snapshot write
 * happens inside the persistence adapter, several layers below the screen that
 * caused it, and the adapter's job is to keep trying fallbacks rather than to
 * draw anything.
 *
 * So both publish here and the shell subscribes once. Keeping this as a plain
 * listener set rather than a context means the adapter stays free of React —
 * which is what lets `db.ts` be swapped for SQLite later without dragging the
 * UI along.
 */

type ErrorKind = "render" | "store-write";

type Listener = (kind: ErrorKind, detail: unknown) => void;

const listeners = new Set<Listener>();

/** Subscribe to fatal errors. Returns the unsubscribe function. */
export function onError(listener: Listener): () => void {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
}

/**
 * Publish a fatal error. A listener that throws must not take the others (or
 * the caller) down with it — the caller is usually already inside a catch
 * block that exists precisely because something went wrong.
 */
export function reportError(kind: ErrorKind, detail?: unknown): void {
  for (const listener of listeners) {
    try {
      listener(kind, detail);
    } catch {
      /* a reporting failure must never cascade */
    }
  }
}
