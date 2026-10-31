# Lexumo 词砚 — design system

Locked by the Hallmark-led redesign (app scope, full depth). Every later change
defers to this file. Token values live in `src/styles/tokens.css`; this sheet
records the decisions those values encode.

## System

- **Genre** — app screen. A tool someone works in, not a page someone lands on.
- **Shape** — two materials, one shell. A stone frame (`--frame`, dark in both
  themes) holds the navigation; a paper sheet (`--bg`, light in both themes) is
  every working screen. The frame never changes colour with the theme because it
  is not a surface you read; it is the desk the paper sits on.
- **Theme** — custom. Inkstone stone, unbleached paper, azurite accent, cinnabar
  reserved for destruction. Not a catalog theme: their display faces carry no
  CJK and their materials are marketing materials.
- **Axes** — paper: light, low chroma. Ink: near-black, green cast. Accent: one
  hue only (azurite, `--accent`), chroma .10 — deliberately quieter than a brand
  blue so it can mark state without shouting. Posture: **Restrained**. The accent
  covers well under 5% of any viewport; a second neutral (the stone) carries all
  the chrome.
- **The signature object** — the practice square: the flashcard, the quiz prompt,
  the word row's headword. It is the one thing set in the serif face, and the one
  place a display size is allowed.

## Tokens

- Surface roles — `--bg` paper, `--surface` card, `--surface-2` tinted well,
  `--surface-sunken` recess. Frame roles — `--frame`, `--frame-2`, `--frame-3`,
  `--frame-line`, `--frame-ink`, `--frame-ink-2`, `--frame-ink-3`,
  `--frame-accent`.
- Ink — `--ink` body, `--ink-2` secondary, `--ink-3` label/caption,
  `--ink-4` decoration only (never text). Contrast: body 15.1:1, secondary 8.4:1,
  label 4.8:1.
- Lines — `--line` hairline, `--line-strong` table head, `--line-control` field
  edge (3.3:1 — the only edge that must clear 3:1).
- Accent — `--accent` 7.1:1 on paper, `--accent-soft` wash, `--accent-ink` text
  on the wash, `--on-accent` text on the fill. `--danger` is cinnabar and means
  destruction only; `--warn` ochre, `--ok` pine, `--info` slate-blue (chart
  series only).
- Faces — `--font-display` IBM Plex Serif (headword, page title, figures),
  `--font-ui` IBM Plex Sans (everything else), `--font-mono` IBM Plex Mono
  (keycaps, measurements). Three weights in use: 400, 500, 600. CJK falls back
  to PingFang SC / Microsoft YaHei UI / Songti SC; the webfonts are latin-only
  and self-hosted (128 KB total, `public/fonts/`).
- Scale — 12 / 13 / 15 / 16 / 19 / 24 / 30 / 38, ratio 1.2. Line height
  `--lh-tight` 1.2 for display, `--lh-snug` 1.4, `--lh-body` 1.6.
- Radii — 2 / 3 / 4 / 6 / 8 / 10. Nothing is a pill except a switch track.
- Elevation — one overlay shadow, one pop shadow. Cards carry a hairline and no
  shadow; only a floating thing (modal, toast, bulk bar) lifts.
- Spacing — 4 / 8 / 12 / 16 / 20 / 24 / 28 / 32 / 40 / 48 / 64. Every value is a
  multiple of 4.

## Window frame

The desktop window runs undecorated (`"decorations": false` in
`src-tauri/tauri.conf.json`), so the app draws its own strip. It is **the frame,
not a screen**: stone in both themes, 36px (`--frame-bar-h`), a hairline
`--frame-line` along its bottom edge, and it belongs to the same material as the
sidebar — the two are one frame around the paper.

- It carries the seal (the app icon at 16px), the name in the serif, the subtitle
  in `--frame-ink-3`, and the three system buttons at the far right.
- The buttons are 46px wide and full height, the Windows convention: the target
  is impossible to miss and close bleeds into the corner where a hand looks for
  it. Close is the only one that answers in cinnabar (`--danger` / `--on-danger`);
  the other two answer in stone (`--frame-3`). The focus ring on this strip is
  `--frame-accent`, like every other control on stone.
- The whole strip is one drag region (`data-tauri-drag-region="deep"`), so the
  name and the gaps between buttons drag the window too. Double-click to
  maximize comes from Tauri's own script, not from a handler here.
- The seal heads the navigation, so it stays on the nav's own axis at every
  width: 20px from the edge when the sidebar is full (level with the nav icons),
  dead centre of the 64px column in the rail, and back to the page margin when
  the sidebar becomes a tab bar. In the rail the wordmark drops, exactly as the
  nav labels do there — the strip never becomes the only place a label survives.
- **A browser tab has no window**, so the strip renders nothing at all rather
  than three buttons that would do nothing (`isDesktopShell()` in
  `src/lib/windowChrome.ts`). This is a property of the shell, not the build.
- The shell is a 2×2 grid: the strip spans both columns on row 1; the sidebar
  and the paper share row 2. When the strip renders nothing its row collapses to
  zero and the layout is exactly what it was. No wrapper element, because a
  wrapper would have to exist in the browser too.
- Resizing and the Windows 11 rounded corners come free: `decorations: false`
  with the default `shadow: true` makes tao hit-test the edges itself and Wry
  attach its resize borders.

## Controls

- Primary: filled `--accent`, `--on-accent` text, radius 4, height 36.
- Secondary: 1px `--line-control` outline, same radius, same height.
- Small: height 32, padding 8. Large: height 40, padding 20.
- Fields: height 36, 1px `--line-control`, focus ring is an `outline` that
  appears instantly — never a border-width change, never a fade.
- Rows are a table: sentence-case heads that do not wrap, horizontal rules only,
  no outer border, actions appear on hover and focus.
- Disabled is `opacity .55` + `cursor: not-allowed` + the native attribute, never
  opacity alone.
- One filled primary per screen or dialog.

## Motion

Quiet and causal. Entrances decelerate (`--ease-out`), exits accelerate
(`--ease-in`), nothing overshoots. Durations 120 / 180 / 260 / 420 / 620 ms.
Only transform and opacity animate. The one orchestrated moment is the flashcard
turn: a two-phase rotation, JS-timed, skipped entirely when
`prefers-reduced-motion` is set (`src/lib/motion.ts`). Everything else is a
receipt for an action — a row arriving, a bar filling, a toast leaving.

## Exports

- `src/styles/tokens.css` — the token block (stamp + critique line at the top).
- `src/styles/fonts.css` — generated by `.shots/fetch-fonts.mjs`; re-run it to
  refresh the faces, never hand-edit.
- `src/styles/global.css` — primitives. `study.css` — flashcards & quiz.
  `insights.css` — stats & settings. Page-specific shapes only; no primitive is
  redefined below `global.css`.
- `index.html` — pre-bundle boot skeleton with its own `--b-*` literals, because
  the token sheet has not loaded yet. Keep it in step with `tokens.css` by hand.

## Finish review amendments

- The stats dash carries one primary figure (`--fs-2xl`); the other tiles are
  supporting (`--fs-xl`). Tiles carry no icon and no accent colour.
- Charts use a single-hue azurite ramp for both word status and grades.
  Cinnabar (`--danger`) never appears in a chart; it means destruction only.
- `font-synthesis: weight` is on: the serif CJK faces Windows ships are
  regular-only, and a page title that renders at 400 is not a title.
- The row headword is `font-weight: 500` in a real self-hosted Plex Serif 500.
- Dark `--accent` is `#66adc5`: the same azurite hue as light, lifted only in
  lightness, so one accent stays one colour in both themes.

## Closing the last three gaps

- **One leading scale.** `--lh-none 1`, `--lh-display 1.05`, `--lh-title 1.15`,
  `--lh-tight 1.2`, `--lh-snug 1.4`, `--lh-body 1.6`, `--lh-loose 1.7`. Every
  `line-height` in the sheet is one of these. The three remaining `px` values
  (`.seg-count`, `.tab-badge`, the chart x-label) size a fixed-height box, so
  they belong with the size rather than with the scale.
- **Dark separates the materials with an edge, not with luminance.** Both
  surfaces are near-black, so the stone drops to `#050706`, the paper lifts to
  `#1d231f`, and the seam is carried by a lit line (`--frame-line #39443e`)
  plus a 2px inset edge on the paper (`--edge`, dark only). In light theme
  `--edge` is transparent, because there the two materials are already far
  apart.
- **Failure is a state, so it has a surface.** A render crash is caught at the
  root and replaced by the `.crash` card: what happened, that the words are
  still on the device, and one action. A snapshot that cannot be persisted
  (IndexedDB and localStorage both refusing) surfaces as an error toast naming
  the next step instead of failing silently. Both publish through
  `src/lib/errors.ts`, which keeps the persistence adapter free of React.
- **A query strip carries one field language and one action language.** Above a
  table, only the controls that hold data are boxes: the search field and the
  sort keep the 3:1 control edge and the ring-shadow focus, because an edge is
  the only thing that says "you can type here". Everything that merely changes
  state (a status filter, a favourite toggle, select mode) is text with an
  icon, and says it is on with the accent tint plus a word, never with a colour
  swap alone. Filters that are on grow a second line inside the same strip
  (count, removable tags, reset), so turning one on never adds a bar to the
  page and an empty result can always explain itself where the query was made.
- **The header sits in the content column, not on the window edge.** A header
  carrying only horizontal padding looks right at 1280 and wrong at 1920, where
  the content column is capped and centred and the title is not: the title ends
  up a couple of hundred pixels left of the thing it titles, and the rule under
  it belongs to a different layout. So `.topbar` wraps its contents in
  `.topbar-inner`, capped to `--content-max` and centred exactly like
  `.page-inner`, and the `wide` variant widens both together. The rule itself
  stays full-bleed, because it is the window's edge between chrome and sheet;
  only the text inside it is capped. Actions are centred against the title
  block rather than aligned to its baseline, so a two-line title and a 36px
  button agree instead of the button hanging below. The header is a flex
  sibling of the scrolling page, never a sticky element inside it, so it cannot
  be scrolled away and needs no shadow to fake separation.

## Touch

- **A thumb is not a cursor, so the floor is 44px on every control.** `--tap`
  is 44 and it is the only number touch sizing uses; 36 and 32 remain the
  *desktop* control heights and are never applied on a coarse pointer. This is
  not a preference — a 38px button is a miss waiting to happen, and the failure
  is invisible to every test that runs at 1280 wide.
- **Grow the hit box, not the shape.** Two controls keep their visual size and
  extend their target with a pseudo-element instead: `.qbar-clear` (32×32 icon
  inside a 44px-tall strip) and `.switch` (a 51×31 track, the platform-standard
  switch shape, where 44px tall would stop reading as a switch). The pseudo-box
  is part of the control, so the probe measures the union of the element and its
  `::after` — a target is as big as what it actually catches.
- **The keyboard is a viewport fact, not a CSS unit.** Android WebView does not
  resize the layout viewport for the IME: `innerHeight`, `100vh`, `100svh`,
  `100lvh` and `100dvh` all stay at the full height while `visualViewport`
  shrinks and pans. So no viewport unit can keep a fixed footer visible.
  `src/lib/keyboard.ts` publishes the visual viewport as `--vv-top` and `--vv-h`
  and toggles `.kb-open`; anything pinned to the bottom edge — a sheet, the toast
  stack — positions against those two values. Defaults describe "no keyboard",
  so nothing has to be initialised before the first frame.
- **Back is a place, not an exit.** On Android the hardware/gesture back button
  is owned by the shell and, left alone, ends the Activity from any screen that
  did not push history — which is every screen with an open dialog. The app
  claims the button through a stack (`src/lib/backButton.ts`): the topmost
  surface that wants it handles it, and only an unclaimed press at the root
  leaves. A non-dismissible dialog still claims the press without closing, so
  the user cannot fall out of the app through a modal that was only meant to be
  answered.

### The same floor in Flutter

`flutter/` shares these tokens but not these mechanisms, so the three rules
above land differently. What stays identical is the numbers and the reasons.

- **`Layout.tap` is 44dp and `context.controlH` is how you get it.** Reading
  `Layout.controlH` (36) directly is a desktop decision leaking onto a phone.
  `flutter/lib/ui/density.dart` adds `isTouchPlatform()`, an extension with
  `controlH` / `controlHSm` / `iconTarget`, and a `TapTarget` wrapper. It
  decides by **platform, not width**: a narrowed desktop window is still driven
  by a mouse, and a landscape tablet is still driven by a thumb. `Layout.tap`
  existed for months with exactly one caller — *a token nobody wires up is not a
  rule, it is a comment.*
- **`TapTarget` grows the hit box and must sit inside the `GestureDetector`.**
  A recogniser only receives events within its own box, so wrapping from the
  outside moves pixels without moving the target. The outer detector also needs
  `HitTestBehavior.opaque`, because a bare `SizedBox` is not hittable itself and
  the surrounding ring would be dead. This is the same "extend the target, not
  the shape" rule as above, expressed in Flutter's terms.
- **A control's height is a layout budget, and a border spends it.** The
  `Segmented` track paints its outline with `foregroundDecoration` rather than
  `decoration`, because a real 1dp border inside a 44dp track leaves 42dp for
  the chip — and the chip is the thing that has to be 44.
- **Measure with a widget test, not a screenshot.** On a phone, geometry claims
  are made by `flutter/test/mobile_layout_test.dart` (three budgets: no layout
  exception at 411dp, every `GestureDetector` ≥ 44dp on both axes, first-screen
  budget of header ≤ 84, first row ≤ 320, query bar ≤ 120). Budgets are the
  largest value the design tolerates rather than the value a run happened to
  produce, so a half-pixel font-metric drift does not turn them into tripwires.
  `flutter/test/density_test.dart` taps 19dp from centre instead of measuring
  boxes — when `TapTarget` was wired on the wrong side of the detector, both
  sizes measured "correct" and only a tap outside the old ring exposed it.

