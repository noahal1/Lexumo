/**
 * Motion preferences, in one place.
 *
 * CSS handles almost every animation in this app: a single
 * `@media (prefers-reduced-motion: reduce)` block at the end of `global.css`
 * collapses all durations to ~0. That covers anything declared in CSS.
 *
 * A few interactions are staged in JS instead — most importantly the flashcard
 * turn, which swaps the front face for the back face halfway through a 3D
 * rotation. CSS alone cannot swap DOM at the right instant, so the turn runs on
 * two timers. When the OS asks for reduced motion those timers must not run at
 * all: the answer should appear immediately, not 130ms later.
 */

/** Whether the OS asks for reduced motion. Safe outside a browser. */
export function prefersReducedMotion(): boolean {
  if (typeof window === "undefined" || typeof window.matchMedia !== "function") {
    return false;
  }
  try {
    return window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  } catch {
    return false;
  }
}
