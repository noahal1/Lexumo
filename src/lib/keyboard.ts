/**
 * The soft keyboard, kept behind one seam.
 *
 * On Android the keyboard does not resize the layout viewport. Chrome keeps
 * `innerHeight`, `100vh` and `100dvh` at the full window height and instead
 * shrinks and *pans* the visual viewport: with a keyboard up on the reference
 * phone, `innerHeight` stays 914 while `visualViewport` becomes 578 tall and
 * reports `offsetTop: 299`. Every `position: fixed` box is laid out against the
 * layout viewport, so it stays where it was — which is why a bottom sheet ended
 * up half above the screen and half under the keyboard, with its title off the
 * top and its save button under the keys.
 *
 * There is no CSS unit that follows the keyboard (`100dvh` was measured at the
 * full 914 with the keyboard open), so the visual viewport has to be published
 * as custom properties and the layout written against those. Two numbers, both
 * in layout-viewport pixels:
 *
 *   --vv-top   where the visible band starts (0 with no keyboard)
 *   --vv-h     how tall the visible band is
 *
 * With a keyboard open the band is `[offsetTop, offsetTop + height]`; a fixed
 * element pinned to `top: var(--vv-top); height: var(--vv-h)` then lands
 * exactly on the part of the screen a thumb can still reach, because layout
 * coordinates are what the pan offset is subtracted from.
 *
 * `kb-open` on the root element lets the stylesheet treat the keyboard as a
 * state rather than guess from a size. The threshold only has to separate "a
 * keyboard" from "a browser toolbar": no keyboard is under 80px and no IME is.
 */
const KEYBOARD_MIN_PX = 80;

export function startKeyboardTracking(): () => void {
  if (typeof window === "undefined" || !window.visualViewport) return () => {};

  const root = document.documentElement;
  const vv = window.visualViewport;
  let frame = 0;

  const apply = () => {
    frame = 0;
    // Rounded: the raw values are fractional on a phone and a sub-pixel
    // custom property makes every dependent box blurry at 2.625 dpr.
    const top = Math.round(vv.offsetTop);
    const height = Math.round(vv.height);
    root.style.setProperty("--vv-top", `${top}px`);
    root.style.setProperty("--vv-h", `${height}px`);
    root.classList.toggle("kb-open", window.innerHeight - height >= KEYBOARD_MIN_PX);
  };

  // `resize` fires when the keyboard opens or closes, `scroll` on every frame
  // of the pan that follows the caret. Both arrive many times per gesture, so
  // they are coalesced into one write per frame.
  const schedule = () => {
    if (!frame) frame = window.requestAnimationFrame(apply);
  };

  apply();
  vv.addEventListener("resize", schedule);
  vv.addEventListener("scroll", schedule);

  return () => {
    if (frame) window.cancelAnimationFrame(frame);
    vv.removeEventListener("resize", schedule);
    vv.removeEventListener("scroll", schedule);
    root.style.removeProperty("--vv-top");
    root.style.removeProperty("--vv-h");
    root.classList.remove("kb-open");
  };
}
