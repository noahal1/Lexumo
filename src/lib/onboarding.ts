/**
 * The first-run choice: sign in for sync, or keep everything on this device.
 *
 * Stored in localStorage rather than in the synced snapshot on purpose. It
 * describes *this machine* ("has this one been set up"), not the library.
 * Putting it in `Settings` would sync the answer to a second device, which then
 * would never be asked, and it would make the wire format and every snapshot
 * fixture carry a field no other module reads.
 *
 * `wipeAll()` clears the snapshot and deliberately leaves this alone: erasing
 * the library is a decision made from inside the app, so re-asking whether to
 * set the app up would be answering a question the user already answered.
 */
import { useSyncExternalStore } from "react";

export type OnboardingChoice = "sync" | "local";

const KEY = "lexumo.onboarded.v1";

function read(): OnboardingChoice | null {
  try {
    const raw = localStorage.getItem(KEY);
    return raw === "sync" || raw === "local" ? raw : null;
  } catch {
    /* no storage (private mode, a locked-down WebView): ask again next boot */
    return null;
  }
}

let choice: OnboardingChoice | null = read();
const listeners = new Set<() => void>();

export function getOnboardingChoice(): OnboardingChoice | null {
  return choice;
}

export function isOnboarded(): boolean {
  return choice !== null;
}

export function completeOnboarding(next: OnboardingChoice): void {
  choice = next;
  try {
    localStorage.setItem(KEY, next);
  } catch {
    /* the choice still holds for this session */
  }
  for (const fn of listeners) fn();
}

/** Back to the gate. For tests: a real user has no reason to un-set this. */
export function resetOnboarding(): void {
  choice = null;
  try {
    localStorage.removeItem(KEY);
  } catch {
    /* nothing to undo */
  }
  for (const fn of listeners) fn();
}

export function subscribeOnboarding(fn: () => void): () => void {
  listeners.add(fn);
  return () => {
    listeners.delete(fn);
  };
}

/** True once the gate has been answered on this device. */
export function useOnboarding(): boolean {
  return useSyncExternalStore(subscribeOnboarding, isOnboarded, isOnboarded);
}
