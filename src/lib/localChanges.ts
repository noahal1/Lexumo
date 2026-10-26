/**
 * Tiny event bus for "the local snapshot changed".
 *
 * Lives in its own module so both `store.ts` and `sync.ts` can depend on it
 * without importing each other (which would create a cycle).
 */

type Listener = () => void;

const listeners = new Set<Listener>();

export function onLocalChange(fn: Listener): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

export function emitLocalChange(): void {
  for (const fn of listeners) fn();
}
