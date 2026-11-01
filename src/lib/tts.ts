/**
 * Text-to-speech, behind one seam.
 *
 * Two engines, one interface:
 *
 *   • Web Speech (desktop WebView2 / Chromium) — synchronous, voice list
 *     available on the `window.speechSynthesis` object.
 *   • Native TTS (Android) — the WebView exposes no `speechSynthesis` at all,
 *     so speech goes through the `tts` plugin and into the OS engine
 *     (`com.google.android.tts` on a stock device). That engine initialises
 *     asynchronously and reports zero voices until it is ready, which is why
 *     the voice list has to be *loaded* rather than read.
 *
 * Callers keep using the same names; only the module knows which engine is
 * behind them. `speechSupported()` stays synchronous because it gates whether a
 * 发音 button is rendered at all — it answers "could this shell ever speak",
 * not "is the engine warm right now".
 */

export interface VoiceInfo {
  uri: string;
  name: string;
  lang: string;
  local: boolean;
}

let cachedVoices: SpeechSynthesisVoice[] = [];

/** Voices discovered through the native plugin, keyed like the web ones. */
let nativeVoices: VoiceInfo[] = [];
let nativeReady = false;
let nativeProbe: Promise<boolean> | null = null;
/** Voice ids from the plugin are its own; `uri` carries them for the UI. */
const nativeVoiceIds = new Map<string, string>();

function hasWebSpeech(): boolean {
  return typeof window !== "undefined" && "speechSynthesis" in window;
}

/**
 * True inside a Tauri mobile shell, where the `tts` plugin is registered. Read
 * from `window` rather than imported so the browser bundle and jsdom tests
 * never touch the bridge.
 */
function hasNativeTts(): boolean {
  if (typeof window === "undefined") return false;
  if (!("__TAURI_INTERNALS__" in window)) return false;
  const ua = typeof navigator === "undefined" ? "" : navigator.userAgent;
  return /Android|iPhone|iPad|iPod/i.test(ua);
}

/** The plugin API, loaded only when the native path is actually taken. */
async function nativeApi() {
  return import("tauri-plugin-tts-api");
}

/**
 * Warm the native engine once and remember the answer.
 *
 * Mobile engines answer `getVoices()` with `[]` until initialisation finishes,
 * so this polls briefly. A failure is cached too: retrying on every render
 * would be worse than showing the "no voice" note.
 */
export function warmNativeTts(): Promise<boolean> {
  if (nativeProbe) return nativeProbe;
  if (!hasNativeTts()) {
    nativeProbe = Promise.resolve(false);
    return nativeProbe;
  }
  nativeProbe = (async () => {
    try {
      const tts = await nativeApi();
      for (let attempt = 0; attempt < 10; attempt += 1) {
        const state = await tts.isInitialized();
        if (state.initialized && state.voiceCount > 0) {
          await refreshNativeVoices();
          return (nativeReady = true);
        }
        await new Promise((resolve) => setTimeout(resolve, 300));
      }
      // Uninitialised but possibly still usable: speaking early is queued by
      // the plugin, so leave the door open instead of hiding every button.
      await refreshNativeVoices();
      return (nativeReady = true);
    } catch {
      nativeReady = false;
      return false;
    }
  })();
  return nativeProbe;
}

async function refreshNativeVoices(): Promise<void> {
  try {
    const tts = await nativeApi();
    const list = await tts.getVoices();
    nativeVoiceIds.clear();
    nativeVoices = list.map((voice) => {
      // The plugin's ids are opaque strings; the settings page stores whatever
      // sits in `uri`, so keep the mapping both ways.
      const uri = `native:${voice.id}`;
      nativeVoiceIds.set(uri, voice.id);
      return { uri, name: voice.name, lang: voice.language, local: true };
    });
  } catch {
    nativeVoices = [];
  }
}

export function speechSupported(): boolean {
  if (hasWebSpeech()) return true;
  if (!hasNativeTts()) return false;
  // Before the probe has run there is no reason to hide the button — a cold
  // mobile engine comes up in a few hundred milliseconds. Once a probe has
  // failed, stop promising speech that will never arrive.
  return nativeProbe === null ? true : nativeReady;
}

export function getVoices(): VoiceInfo[] {
  if (nativeVoices.length) return nativeVoices;
  if (!hasWebSpeech()) return [];
  const list = window.speechSynthesis.getVoices();
  if (list.length) cachedVoices = list;
  return (cachedVoices.length ? cachedVoices : list).map((v) => ({
    uri: v.voiceURI,
    name: v.name,
    lang: v.lang,
    local: v.localService,
  }));
}

/** Voices matching a BCP-47-ish language tag, best match first. */
export function voicesFor(lang: string): VoiceInfo[] {
  const base = lang.toLowerCase().split("-")[0];
  const all = getVoices();
  return all
    .filter((v) => v.lang.toLowerCase().startsWith(base))
    .sort((a, b) => {
      const aExact = a.lang.toLowerCase() === lang.toLowerCase() ? 0 : 1;
      const bExact = b.lang.toLowerCase() === lang.toLowerCase() ? 0 : 1;
      return aExact - bExact || Number(b.local) - Number(a.local);
    });
}

/**
 * Subscribe to the async voice list; returns an unsubscribe function.
 *
 * On the native path there is no `voiceschanged` event — the list is fetched —
 * so the poll and the callback are wired up here instead.
 */
export function onVoicesChanged(cb: () => void): () => void {
  if (hasNativeTts()) {
    let alive = true;
    void warmNativeTts().then(() => {
      if (alive) cb();
    });
    return () => {
      alive = false;
    };
  }
  if (!hasWebSpeech()) return () => {};
  const handler = () => cb();
  window.speechSynthesis.addEventListener("voiceschanged", handler);
  // Some engines populate lazily without firing the event.
  const t = setTimeout(handler, 300);
  return () => {
    clearTimeout(t);
    window.speechSynthesis.removeEventListener("voiceschanged", handler);
  };
}

interface SpeakOptions {
  lang?: string;
  rate?: number;
  voiceURI?: string;
  onEnd?: () => void;
}

async function speakNative(text: string, opts: SpeakOptions): Promise<void> {
  try {
    const tts = await nativeApi();
    await tts.stop();
    // A stored voice that is not installed would make `speak` fall back and
    // warn; only pass ids this device actually reported.
    const voiceId = opts.voiceURI ? nativeVoiceIds.get(opts.voiceURI) : undefined;
    await tts.speak({
      text,
      language: opts.lang ?? null,
      voiceId: voiceId ?? null,
      rate: clampRate(opts.rate),
    });
    if (opts.onEnd) {
      // `speak()` resolves when speech *starts*; the end of the utterance only
      // arrives as an event, so the caller's callback hangs off it.
      const unlisten = await tts.onSpeechEvent("speech:finish", () => {
        void unlisten();
        opts.onEnd?.();
      });
    }
  } catch {
    // A missing engine, a refused request — there is nothing actionable to
    // surface mid-card, so speech simply does not happen.
    opts.onEnd?.();
  }
}

/** Web Speech's rate scale is roughly 0.5–2 with 1 as normal; the plugin takes 0.1–4. */
function clampRate(rate: number | undefined): number {
  return Math.max(0.1, Math.min(4, rate ?? 1));
}

export function speak(text: string, opts: SpeakOptions = {}): void {
  if (!text.trim()) {
    opts.onEnd?.();
    return;
  }
  if (!hasWebSpeech() && hasNativeTts()) {
    void speakNative(text, opts);
    return;
  }
  if (!hasWebSpeech()) {
    opts.onEnd?.();
    return;
  }
  const synth = window.speechSynthesis;
  synth.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.rate = Math.max(0.5, Math.min(1.6, opts.rate ?? 0.95));
  if (opts.lang) u.lang = opts.lang;
  if (opts.voiceURI) {
    const voice = synth.getVoices().find((v) => v.voiceURI === opts.voiceURI);
    if (voice) {
      u.voice = voice;
      u.lang = voice.lang;
    }
  } else if (opts.lang) {
    const match = voicesFor(opts.lang)[0];
    if (match) {
      const voice = synth.getVoices().find((v) => v.voiceURI === match.uri);
      if (voice) u.voice = voice;
    }
  }
  if (opts.onEnd) u.onend = () => opts.onEnd?.();
  synth.speak(u);
}

export function stopSpeaking(): void {
  if (hasWebSpeech()) {
    window.speechSynthesis.cancel();
    return;
  }
  if (hasNativeTts()) void nativeApi().then((tts) => tts.stop()).catch(() => {});
}
