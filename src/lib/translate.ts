/**
 * Term lookup for the word editor.
 *
 * The app is offline-first, so this module is strictly a convenience layer:
 * every call is best-effort, results are cached aggressively, and a failure
 * never blocks the user from typing a definition by hand.
 *
 * Two transports exist because the same feature has to work in a browser tab
 * and inside the Tauri webview:
 *
 *  - Tauri: `lookup_word` (see `src-tauri/src/lib.rs`) proxies the Youdao
 *    dictionary. That endpoint is public but sends no CORS headers, so a
 *    browser `fetch` is rejected; going through Rust also gives us the full
 *    dictionary payload (phonetic, part-of-speech senses, bilingual examples).
 *  - Browser: only providers that send `Access-Control-Allow-Origin` are
 *    usable, and those are plain machine translation with tighter rate limits.
 *
 * The provider chain is data, not a branch: `createLookup` receives the adapter
 * list plus an injected cache and clock. The app's chain is assembled once by
 * `defaultAdapters()` (the only place `isTauri()` is consulted), while tests
 * build a lookup with fake adapters and a fake clock — no global `fetch`
 * patching, and the desktop path is reachable under plain Node.
 */
import { invoke } from "@tauri-apps/api/core";

export type ProviderId = "youdao" | "youdao-web" | "mymemory" | "google";

interface DictSense {
  /** Part of speech such as "adj." — empty when the provider has no tags. */
  pos: string;
  meaning: string;
}

interface DictExample {
  en: string;
  zh?: string;
}

export interface LookupResult {
  term: string;
  /** IPA without slashes, e.g. "ˈkændɪd". Empty when unknown. */
  phonetic: string;
  senses: DictSense[];
  examples: DictExample[];
  provider: ProviderId;
  /** True when served from the local cache (no network happened). */
  fromCache: boolean;
}

export type LookupFailure = "rate-limited" | "offline" | "not-found";

export class LookupError extends Error {
  readonly reason: LookupFailure;

  constructor(reason: LookupFailure, message?: string) {
    super(message ?? reason);
    this.name = "LookupError";
    this.reason = reason;
  }
}

/* ------------------------------------------------------------------ cache */

const CACHE_KEY = "lexumo.dict.v1";
const CACHE_TTL_MS = 1000 * 60 * 60 * 24 * 30;
const CACHE_MAX = 400;

interface CacheRecord {
  at: number;
  result: LookupResult;
}

type CacheMap = Record<string, CacheRecord>;

/** The slice of `Storage` the cache needs; `null` keeps everything in memory. */
interface LookupStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

/**
 * Injected time source. The cache TTL and the 429 cooldown both read it, so a
 * test can move time forward without waiting or resetting module state.
 */
export interface LookupClock {
  now(): number;
}

const systemClock: LookupClock = { now: () => Date.now() };

/** Cache as seen by the orchestrator: TTL is already applied by `get`. */
interface LookupCache {
  get(key: string): LookupResult | null;
  set(key: string, result: LookupResult): void;
  size(): number;
  clear(): void;
}

interface LookupCacheOptions {
  /** Defaults to `localStorage` when it exists, otherwise memory only. */
  storage?: LookupStorage | null;
  key?: string;
  ttlMs?: number;
  max?: number;
  clock?: LookupClock;
}

function cacheKey(term: string, from: string, to: string): string {
  return `${from}>${to}:${term.trim().toLowerCase()}`;
}

function defaultStorage(): LookupStorage | null {
  return typeof localStorage !== "undefined" ? localStorage : null;
}

/**
 * Build a lookup cache. Persistence, the 30-day TTL and the size cap are the
 * same as before; the only change is that they belong to an instance, so two
 * lookups (or two tests) never share state.
 */
export function createLookupCache(options: LookupCacheOptions = {}): LookupCache {
  const storage = options.storage !== undefined ? options.storage : defaultStorage();
  const storageKey = options.key ?? CACHE_KEY;
  const ttlMs = options.ttlMs ?? CACHE_TTL_MS;
  const max = options.max ?? CACHE_MAX;
  const clock = options.clock ?? systemClock;

  // Loaded on first use so importing this module never touches localStorage.
  let map: CacheMap | null = null;

  function read(): CacheMap {
    if (map) return map;
    let parsed: CacheMap = {};
    try {
      const raw = storage?.getItem(storageKey);
      if (raw) parsed = JSON.parse(raw) as CacheMap;
    } catch {
      parsed = {};
    }
    map = parsed;
    return parsed;
  }

  function persist(next: CacheMap): void {
    map = next;
    try {
      storage?.setItem(storageKey, JSON.stringify(next));
    } catch {
      // Quota or privacy mode: the in-memory copy still helps this session.
    }
  }

  return {
    get(key) {
      const current = read();
      const hit = current[key];
      if (!hit) return null;
      if (clock.now() - hit.at > ttlMs) {
        delete current[key];
        persist(current);
        return null;
      }
      return { ...hit.result, fromCache: true };
    },
    set(key, result) {
      const current = read();
      current[key] = { at: clock.now(), result: { ...result, fromCache: false } };
      const keys = Object.keys(current);
      if (keys.length > max) {
        // Drop the oldest quarter; cheap and good enough for a lookup cache.
        const sorted = keys.sort((a, b) => current[a].at - current[b].at);
        for (const k of sorted.slice(0, Math.ceil(keys.length / 4))) delete current[k];
      }
      persist(current);
    },
    size() {
      return Object.keys(read()).length;
    },
    clear() {
      map = {};
      try {
        storage?.removeItem(storageKey);
      } catch {
        // ignore
      }
    },
  };
}

/** Wipe the default instance's cache (used by the settings page). */
export function clearLookupCache(): void {
  getDefaultLookup().clearCache();
}

/** Number of cached terms in the default instance — shown in settings. */
export function lookupCacheSize(): number {
  return getDefaultLookup().cacheSize();
}

/* --------------------------------------------------------------- helpers */

/** True when running inside the Tauri shell (custom commands available). */
export function isTauri(): boolean {
  return typeof window !== "undefined" && "__TAURI_INTERNALS__" in window;
}

export function normalizeTerm(term: string): string {
  return term.trim().replace(/\s+/g, " ");
}

function stripTags(input: string): string {
  return input.replace(/<[^>]+>/g, "");
}

/** Map app language codes onto the dialects the providers expect. */
function youdaoLang(code: string): string {
  const c = code.toLowerCase();
  if (c.startsWith("zh")) return "zh-CHS";
  if (c.startsWith("en")) return "en";
  if (c.startsWith("ja")) return "ja";
  if (c.startsWith("ko")) return "ko";
  if (c.startsWith("fr")) return "fr";
  if (c.startsWith("de")) return "de";
  if (c.startsWith("es")) return "es";
  if (c.startsWith("ru")) return "ru";
  return code;
}

/**
 * Google Translate does not accept Youdao's `zh-CHS` dialect tag. Worse than
 * rejecting it, it silently echoes the input back untranslated — which reads
 * as a real gloss and hides the failure. Google wants `zh-CN` / `zh-TW`.
 */
function googleLang(code: string): string {
  const c = code.toLowerCase();
  if (c.startsWith("zh")) {
    return c.includes("tw") || c.includes("hk") ? "zh-TW" : "zh-CN";
  }
  return youdaoLang(code);
}

function myMemoryPair(from: string, to: string): string {
  const norm = (c: string) => {
    const lower = c.toLowerCase();
    if (lower.startsWith("zh")) return "zh-CN";
    if (lower.startsWith("en")) return "en";
    return lower.slice(0, 2);
  };
  return `${norm(from)}|${norm(to)}`;
}

/**
 * Youdao appends a proper-noun block to nearly every common word:
 *
 *   `【名】 （Record）（美）勒科尔（人名）`
 *
 * It is not a sense of the word — it is the surname that happens to share its
 * spelling. Left in place it crowds out the real secondary senses (and for a
 * three-sense budget it can be the only thing that survives).
 */
function isProperNoun(meaning: string): boolean {
  return /^【名】/.test(meaning) || meaning.includes("（人名）");
}

/** Turn a Youdao sense string into `{pos, meaning}` parts. */
function splitSense(raw: string): DictSense[] {
  const text = stripTags(raw).trim();
  if (!text) return [];
  const match = /^([a-z]{1,6}\.)\s*(.+)$/i.exec(text);
  const pos = match ? match[1] : "";
  const body = match ? match[2] : text;
  return body
    .split(/[；;]\s*/)
    .map((part) => part.trim())
    .filter(Boolean)
    .filter((meaning) => !isProperNoun(meaning))
    .map((meaning) => ({ pos, meaning }));
}

/* --------------------------------------------------------------- parsers */

interface RawYoudaoTrs {
  tr?: { l?: { i?: string | string[] } }[];
}

interface RawYoudaoWord {
  usphone?: string;
  ukphone?: string;
  trs?: RawYoudaoTrs[];
}

interface RawYoudaoSentencePair {
  sentence?: string;
  "sentence-translation"?: string;
}

interface RawYoudao {
  ec?: { word?: RawYoudaoWord[] };
  blng_sents_part?: { "sentence-pair"?: RawYoudaoSentencePair[] };
  fanyi?: { tran?: string };
}

/** Parse the `dict.youdao.com/jsonapi` payload. Returns null when empty. */
export function parseYoudao(raw: unknown, term: string): LookupResult | null {
  const data = raw as RawYoudao | null;
  if (!data || typeof data !== "object") return null;

  const word = data.ec?.word?.[0];
  const senses: DictSense[] = [];

  for (const entry of word?.trs ?? []) {
    for (const tr of entry.tr ?? []) {
      const items = tr.l?.i;
      const list = Array.isArray(items) ? items : items ? [items] : [];
      for (const item of list) {
        if (typeof item === "string") senses.push(...splitSense(item));
      }
    }
  }

  // A sentence or an uncommon phrase only gets machine translation.
  if (senses.length === 0 && typeof data.fanyi?.tran === "string") {
    const tran = stripTags(data.fanyi.tran).trim();
    if (tran) senses.push({ pos: "", meaning: tran });
  }

  if (senses.length === 0) return null;

  const examples: DictExample[] = [];
  for (const pair of data.blng_sents_part?.["sentence-pair"] ?? []) {
    const en = stripTags(pair.sentence ?? "").trim();
    if (!en) continue;
    const zh = stripTags(pair["sentence-translation"] ?? "").trim();
    examples.push(zh ? { en, zh } : { en });
    if (examples.length >= 2) break;
  }

  const phonetic = (word?.usphone || word?.ukphone || "").trim();

  return {
    term,
    phonetic,
    senses,
    examples,
    provider: "youdao",
    fromCache: false,
  };
}

interface RawYoudaoTrans {
  /** Youdao sends this as a string ("0"), but be lenient about both shapes. */
  errorCode?: number | string;
  translation?: string[];
}

function errorCodeOf(raw: unknown): number | null {
  const code = (raw as RawYoudaoTrans | null)?.errorCode;
  if (typeof code === "number") return code;
  if (typeof code === "string" && code.trim() !== "") {
    const parsed = Number(code);
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

/** Parse the `aidemo.youdao.com/trans` payload (machine translation). */
export function parseYoudaoTranslation(raw: unknown, term: string): LookupResult | null {
  if (errorCodeOf(raw) !== 0) return null;
  const data = raw as RawYoudaoTrans;
  const lines = (data.translation ?? []).map((l) => stripTags(l).trim()).filter(Boolean);
  if (lines.length === 0) return null;
  return {
    term,
    phonetic: "",
    senses: lines.map((meaning) => ({ pos: "", meaning })),
    examples: [],
    provider: "youdao-web",
    fromCache: false,
  };
}

interface RawMyMemory {
  responseStatus?: number;
  responseData?: { translatedText?: string };
  matches?: { translation?: string; segment?: string; match?: number }[];
}

export function parseMyMemory(raw: unknown, term: string): LookupResult | null {
  const data = raw as RawMyMemory | null;
  const primary = stripTags(data?.responseData?.translatedText ?? "").trim();
  if (!primary) return null;
  const meanings = [primary];
  for (const match of data?.matches ?? []) {
    const text = stripTags(match.translation ?? "").trim();
    // Only alternatives that translate the term itself, not longer segments.
    const segment = (match.segment ?? "").trim().toLowerCase();
    if (!text || meanings.includes(text)) continue;
    if (segment && segment !== term.trim().toLowerCase()) continue;
    if ((match.match ?? 0) < 0.7) continue;
    meanings.push(text);
    if (meanings.length >= 3) break;
  }
  return {
    term,
    phonetic: "",
    senses: meanings.map((meaning) => ({ pos: "", meaning })),
    examples: [],
    provider: "mymemory",
    fromCache: false,
  };
}

/** Parse the `translate.googleapis.com/translate_a/single` nested array. */
export function parseGoogle(raw: unknown, term: string): LookupResult | null {
  const data = raw as unknown[] | null;
  if (!Array.isArray(data) || !Array.isArray(data[0])) return null;
  const text = (data[0] as unknown[])
    .map((chunk) => (Array.isArray(chunk) ? String(chunk[0] ?? "") : ""))
    .join("")
    .trim();
  if (!text) return null;
  return {
    term,
    phonetic: "",
    senses: [{ pos: "", meaning: text }],
    examples: [],
    provider: "google",
    fromCache: false,
  };
}

/* ------------------------------------------------------------- providers */

const COOLDOWN_MS = 90_000;

/** Per-call context the network adapters need beyond the term itself. */
export interface LookupContext {
  from: string;
  to: string;
  /** Shared timeout/cancel signal for the whole lookup. */
  signal: AbortSignal;
}

/**
 * One dictionary provider. `canServe` is consulted before `fetch`, so a chain
 * may hold providers that only cover some language pairs. `fetch` returns null
 * when the provider answered but had nothing (fall through to the next one) and
 * throws `LookupError("rate-limited")` to trigger that provider's cooldown.
 */
export interface LookupAdapter {
  readonly id: ProviderId;
  canServe(from: string, to: string): boolean;
  fetch(term: string, context: LookupContext): Promise<LookupResult | null>;
}

interface ProxyResponse {
  ok: boolean;
  status: number;
  body: string;
  error: string | null;
}

/** True when a list asks for a Chinese gloss (the only thing Youdao's
 *  dictionary endpoint can produce). */
function isChineseTarget(to: string | undefined): boolean {
  return !to || to.toLowerCase().startsWith("zh");
}

/** The desktop transport: a Rust command proxying Youdao (no CORS involved). */
function tauriAdapter(): LookupAdapter {
  return {
    id: "youdao",
    // `dict.youdao.com/jsonapi` always glosses into Chinese, whatever `to` the
    // list asked for. Serving a Japanese target from it would silently hand
    // back Chinese, so this adapter only claims Chinese targets; every other
    // pair is left to the web adapters in `createTauriAdapters`.
    canServe: (_from, to) => isChineseTarget(to),
    async fetch(term) {
      const res = await invoke<ProxyResponse>("lookup_word", { term });
      if (!res.ok) {
        if (res.status === 429) throw new LookupError("rate-limited");
        return null;
      }
      return parseYoudao(JSON.parse(res.body), term);
    },
  };
}

async function fetchJson(url: string, signal: AbortSignal): Promise<unknown> {
  const res = await fetch(url, { signal, headers: { Accept: "application/json" } });
  if (res.status === 429) throw new LookupError("rate-limited");
  if (!res.ok) throw new LookupError("offline", `http ${res.status}`);
  return res.json();
}

/**
 * How long one provider may take before the chain moves on, and how long the
 * whole lookup may take across all of them.
 *
 * These are two budgets, not one. A single shared 9s signal used to be handed
 * to every adapter, so a provider that does not answer *at all* — Google's
 * endpoint from the Android WebView, for instance — ate the entire budget and
 * left the following providers holding an already-aborted signal. The visible
 * symptom was a translate button that sat on "翻译中…" and then reported the
 * term as missing while a perfectly good provider behind it never got a try.
 */
const PER_PROVIDER_MS = 4_000;
const TOTAL_LOOKUP_MS = 9_000;

function timeoutSignal(signal: AbortSignal | undefined, ms: number): AbortSignal {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  const onAbort = () => controller.abort();
  signal?.addEventListener("abort", onAbort, { once: true });
  controller.signal.addEventListener(
    "abort",
    () => {
      clearTimeout(timer);
      signal?.removeEventListener("abort", onAbort);
    },
    { once: true },
  );
  return controller.signal;
}

function youdaoWebAdapter(): LookupAdapter {
  return {
    id: "youdao-web",
    canServe: () => true,
    async fetch(term, { from, to, signal }) {
      const url =
        "https://aidemo.youdao.com/trans?" +
        new URLSearchParams({ q: term, from: youdaoLang(from), to: youdaoLang(to) }).toString();
      const raw = await fetchJson(url, signal);
      const parsed = parseYoudaoTranslation(raw, term);
      if (!parsed && errorCodeOf(raw) === 411) throw new LookupError("rate-limited");
      return parsed;
    },
  };
}

function myMemoryAdapter(): LookupAdapter {
  return {
    id: "mymemory",
    canServe: () => true,
    async fetch(term, { from, to, signal }) {
      const url =
        "https://api.mymemory.translated.net/get?" +
        new URLSearchParams({ q: term, langpair: myMemoryPair(from, to) }).toString();
      return parseMyMemory(await fetchJson(url, signal), term);
    },
  };
}

export function googleAdapter(): LookupAdapter {
  return {
    id: "google",
    canServe: () => true,
    async fetch(term, { from, to, signal }) {
      const url =
        "https://translate.googleapis.com/translate_a/single?" +
        new URLSearchParams({
          client: "gtx",
          sl: googleLang(from),
          tl: googleLang(to),
          dt: "t",
          q: term,
        }).toString();
      return parseGoogle(await fetchJson(url, signal), term);
    },
  };
}

/** The browser fallback chain, in its historical order. */
export function createBrowserAdapters(): LookupAdapter[] {
  return [youdaoWebAdapter(), myMemoryAdapter(), googleAdapter()];
}

/**
 * The desktop chain. The Rust proxy is only needed for Youdao's dictionary
 * endpoint (it sends no CORS headers), and that endpoint can only gloss into
 * Chinese — so it leads, and the CORS-friendly public endpoints the browser
 * build already uses cover every other target (and fill gaps for Chinese).
 */
export function createTauriAdapters(): LookupAdapter[] {
  return [tauriAdapter(), googleAdapter(), myMemoryAdapter()];
}

/**
 * The chain the app ships with. `isTauri()` is read here — once, at the edge —
 * and never inside the orchestrator.
 */
function defaultAdapters(): LookupAdapter[] {
  return isTauri() ? createTauriAdapters() : createBrowserAdapters();
}

/* ------------------------------------------------------------- lookup core */

interface LookupOptions {
  from?: string;
  to?: string;
  /** Skip the cache and re-fetch (the "重新翻译" button). */
  force?: boolean;
  signal?: AbortSignal;
  /**
   * Adapter ids to try first, in this order. Everything else keeps its chain
   * position afterwards.
   *
   * The engines are not interchangeable for every query. Youdao translates
   * *into* Chinese from a dictionary and *out of* Chinese as machine
   * translation, which renders a bare noun as a polite sentence — `苹果` comes
   * back as `りんごです`, not `りんご`. That is fine for prose and wrong for a
   * vocabulary entry, which needs the lemma. Callers that want a word rather
   * than a sentence ask for the engine that returns one.
   */
  prefer?: ProviderId[];
}

/** What a lookup instance exposes. */
export interface Lookup {
  lookupTerm(term: string, options?: LookupOptions): Promise<LookupResult>;
  clearCache(): void;
  cacheSize(): number;
  /** Forget the 429 cooldowns (kept for the old module-level test hook). */
  resetCooldown(): void;
}

interface LookupDeps {
  /** Fallback order, first to last. */
  adapters: LookupAdapter[];
  /** Defaults to a fresh cache bound to `clock`. */
  cache?: LookupCache;
  /** Defaults to `systemClock`. */
  clock?: LookupClock;
}

/**
 * Build a lookup from its parts. The adapter list is data, and the cache and
 * cooldown live in this closure, so a test can make a fresh instance per case
 * instead of resetting module globals.
 */
export function createLookup({ adapters, cache, clock = systemClock }: LookupDeps): Lookup {
  const store = cache ?? createLookupCache({ clock });
  const cooldown = new Map<ProviderId, number>();

  function cooling(provider: ProviderId): boolean {
    const until = cooldown.get(provider);
    if (!until) return false;
    if (clock.now() > until) {
      cooldown.delete(provider);
      return false;
    }
    return true;
  }

  function markCooling(provider: ProviderId): void {
    cooldown.set(provider, clock.now() + COOLDOWN_MS);
  }

  /**
   * Look a term up, trying the cache first and then each adapter in turn.
   *
   * Throws `LookupError` when every adapter failed; `reason` lets the UI say
   * something more useful than "出错了".
   */
  async function lookupTerm(term: string, options: LookupOptions = {}): Promise<LookupResult> {
    const cleaned = normalizeTerm(term);
    if (!cleaned) throw new LookupError("not-found", "empty term");

    const from = options.from ?? "en";
    const to = options.to ?? "zh-CN";
    const key = cacheKey(cleaned, from, to);

    if (!options.force) {
      const cached = store.get(key);
      if (cached) return cached;
    }

    const totalSignal = timeoutSignal(options.signal, TOTAL_LOOKUP_MS);

    let rateLimited = false;
    let reachable = false;

    // `prefer` only reorders; it never removes a fallback. A caller asking for
    // Google first still gets MyMemory when Google is unreachable.
    const chain = options.prefer?.length
      ? [
          ...adapters.filter((a) => options.prefer!.includes(a.id)),
          ...adapters.filter((a) => !options.prefer!.includes(a.id)),
        ]
      : adapters;

    for (const adapter of chain) {
      if (!adapter.canServe(from, to)) continue;
      if (cooling(adapter.id)) {
        rateLimited = true;
        continue;
      }
      // A leash per provider, still bounded by the overall deadline and still
      // abortable through the caller's own signal. A silent provider costs one
      // slot of the budget instead of all of it.
      const signal = timeoutSignal(totalSignal, PER_PROVIDER_MS);
      const context: LookupContext = { from, to, signal };
      try {
        const result = await adapter.fetch(cleaned, context);
        reachable = true;
        if (result) {
          store.set(key, result);
          return result;
        }
      } catch (error) {
        if (options.signal?.aborted) throw error;
        if (error instanceof LookupError && error.reason === "rate-limited") {
          markCooling(adapter.id);
          rateLimited = true;
        }
      }
    }

    if (rateLimited) throw new LookupError("rate-limited");
    if (!reachable) throw new LookupError("offline");
    throw new LookupError("not-found");
  }

  return {
    lookupTerm,
    clearCache: () => store.clear(),
    cacheSize: () => store.size(),
    resetCooldown: () => cooldown.clear(),
  };
}

/* -------------------------------------------------------- default instance */

let defaultLookup: Lookup | null = null;

/**
 * The app-wide lookup. Built lazily so importing this module in Node touches
 * neither `localStorage` nor `isTauri()`; the chain is assembled once, here.
 */
function getDefaultLookup(): Lookup {
  if (!defaultLookup) {
    defaultLookup = createLookup({ adapters: defaultAdapters() });
  }
  return defaultLookup;
}

/**
 * Module-level entry point kept for existing callers (the word editor). New
 * code should take a `Lookup` from `createLookup` instead.
 */
export function lookupTerm(term: string, options: LookupOptions = {}): Promise<LookupResult> {
  return getDefaultLookup().lookupTerm(term, options);
}

/** Reset provider cooldowns on the default instance (tests / manual retry). */
export function resetProviderCooldown(): void {
  getDefaultLookup().resetCooldown();
}

/* ----------------------------------------------------------- formatting */

/**
 * How many extra senses the secondary field may hold. A long word can come back
 * with dozens (`run` returns forty-five, 437 characters' worth); past three of
 * them the field stops being a gloss and becomes a dictionary page.
 */
const MAX_SECONDARY_SENSES = 3;

/**
 * The primary sense on its own, with no part-of-speech prefix.
 *
 * The tag belongs in its own field (`Word.pos`) rather than glued to the front
 * of the meaning: `"n. 类比，比拟"` is a dictionary line, not a gloss, and it
 * reads badly in the word list, on a flashcard, and as a quiz option.
 */
export function primaryMeaning(result: LookupResult): string {
  return result.senses[0]?.meaning ?? "";
}

/**
 * The remaining senses, joined the way Chinese dictionaries write them.
 *
 * Two rules, both learned from what the dictionary actually returns:
 *
 * 1. **A different part of speech outranks another sense of the same one.**
 *    `record` arrives as noun, noun, noun, verb, adjective; taking the first
 *    three senses would spend the whole field on three noun shades and hide the
 *    fact that the word is also a verb. So senses that disagree with the primary
 *    tag are picked first, and only leftover slots go to same-tag senses.
 * 2. **A sense keeps its tag only once per run**, and never when it matches the
 *    primary one — `candid` (three adjective senses) reads
 *    `"抓拍的，偷拍的；公正的"`, not `"adj. 抓拍的，偷拍的；adj. 公正的"`.
 *
 * The chosen senses are still emitted in dictionary order.
 */
export function alternativeMeaning(result: LookupResult): string {
  const primary = result.senses[0];
  if (!primary) return "";
  const rest = result.senses.slice(1);

  const picked = new Set<number>();
  // Pass one: a part of speech the primary sense does not have.
  for (let i = 0; i < rest.length && picked.size < MAX_SECONDARY_SENSES; i++) {
    if (rest[i].pos !== "" && rest[i].pos !== primary.pos) picked.add(i);
  }
  // Pass two: fill what is left with further shades of the primary sense.
  for (let i = 0; i < rest.length && picked.size < MAX_SECONDARY_SENSES; i++) {
    picked.add(i);
  }

  const parts: string[] = [];
  let lastPos: string | null = null;
  for (const i of [...picked].sort((a, b) => a - b)) {
    const sense = rest[i];
    const needsTag = sense.pos !== "" && sense.pos !== primary.pos && sense.pos !== lastPos;
    parts.push(needsTag ? `${sense.pos} ${sense.meaning}` : sense.meaning);
    lastPos = sense.pos;
  }
  return parts.join("；");
}

/** All senses as one line — used for the "填入释义" preview and toasts. */
export function formatSenses(result: LookupResult): string {
  return result.senses.map((s) => (s.pos ? `${s.pos} ${s.meaning}` : s.meaning)).join("；");
}

/**
 * Distinct part-of-speech tags in order of first appearance, e.g.
 * `["n.", "v.", "adj."]`. Feeds the `pos` field in the editor: a word can be a
 * noun and a verb at once, and the secondary field only has room for three
 * senses, so this is the reliable place to record that it is both.
 */
export function posTags(result: LookupResult): string[] {
  const seen = new Set<string>();
  const tags: string[] = [];
  for (const sense of result.senses) {
    if (sense.pos && !seen.has(sense.pos)) {
      seen.add(sense.pos);
      tags.push(sense.pos);
    }
  }
  return tags;
}
