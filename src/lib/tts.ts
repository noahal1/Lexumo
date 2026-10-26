/** Text-to-speech via the Web Speech API (works in WebView2 / Chromium). */

export interface VoiceInfo {
  uri: string;
  name: string;
  lang: string;
  local: boolean;
}

let cachedVoices: SpeechSynthesisVoice[] = [];

export function speechSupported(): boolean {
  return typeof window !== "undefined" && "speechSynthesis" in window;
}

export function getVoices(): VoiceInfo[] {
  if (!speechSupported()) return [];
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

/** Subscribe to the async voice list; returns an unsubscribe function. */
export function onVoicesChanged(cb: () => void): () => void {
  if (!speechSupported()) return () => {};
  const handler = () => cb();
  window.speechSynthesis.addEventListener("voiceschanged", handler);
  // Some engines populate lazily without firing the event.
  const t = setTimeout(handler, 300);
  return () => {
    clearTimeout(t);
    window.speechSynthesis.removeEventListener("voiceschanged", handler);
  };
}

export interface SpeakOptions {
  lang?: string;
  rate?: number;
  voiceURI?: string;
  onEnd?: () => void;
}

let currentUtterance: SpeechSynthesisUtterance | null = null;

export function speak(text: string, opts: SpeakOptions = {}): void {
  if (!speechSupported() || !text.trim()) {
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
  currentUtterance = u;
  synth.speak(u);
}

export function stopSpeaking(): void {
  if (speechSupported()) window.speechSynthesis.cancel();
  currentUtterance = null;
}

export function isSpeaking(): boolean {
  return speechSupported() ? window.speechSynthesis.speaking : false;
}

export { currentUtterance };
