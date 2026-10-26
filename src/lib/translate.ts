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
 */
import { invoke } from "@tauri-apps/api/core";

export type ProviderId = "youdao" | "youdao-web" | "mymemory" | "google";

export interface DictSense {
  /** Part of speech such as "adj." — empty when the provider has no tags. */
  pos: string;
  meaning: string;
}

export interface DictExample {
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

const CACHE_KEY = "lexilo.dict.v1";
const CACHE_TTL_MS = 1000 * 60 * 60 * 24 * 30;
const CACHE_MAX = 400;

interface CacheRecord {
  at: number;
  result: LookupResult;
}

type CacheMap = Record<string, CacheRecord>;

let memoryCache: CacheMap | null = null;

function cacheKey(term: string, from: string, to: string): string {
  return `${from}>${to}:${term.trim().toLowerCase()}`;
}

function readCache(): CacheMap {
  if (memoryCache) return memoryCache;
  let parsed: CacheMap = {};
  try {
    const raw = localStorage.getItem(CACHE_KEY);
    if (raw) parsed = JSON.parse(raw) as CacheMap;
  } catch {
    parsed = {};
  }
  memoryCache = parsed;
  return parsed;
}

function persistCache(map: CacheMap): void {
  memoryCache = map;
  try {
    localStorage.setItem(CACHE_KEY, JSON.stringify(map));
  } catch {
    // Quota or privacy mode: the in-memory copy still helps this session.
  }
}

function readCached(key: string): LookupResult | null {
  const map = readCache();
  const hit = map[key];
  if (!hit) return null;
  if (Date.now() - hit.at > CACHE_TTL_MS) {
    delete map[key];
    persistCache(map);
    return null;
  }
  return { ...hit.result, fromCache: true };
}

function writeCached(key: string, result: LookupResult): void {
  const map = readCache();
  map[key] = { at: Date.now(), result: { ...result, fromCache: false } };
  const keys = Object.keys(map);
  if (keys.length > CACHE_MAX) {
    // Drop the oldest quarter; cheap and good enough for a lookup cache.
    const sorted = keys.sort((a, b) => map[a].at - map[b].at);
    for (const k of sorted.slice(0, Math.ceil(keys.length / 4))) delete map[k];
  }
  persistCache(map);
}

/** Wipe the dictionary cache (used by the settings page). */
export function clearLookupCache(): void {
  memoryCache = {};
  try {
    localStorage.removeItem(CACHE_KEY);
  } catch {
    // ignore
  }
}

/** Number of cached terms — shown in settings as a hint. */
export function lookupCacheSize(): number {
  return Object.keys(readCache()).length;
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

function myMemoryPair(from: string, to: string): string {
  const norm = (c: string) => {
    const lower = c.toLowerCase();
    if (lower.startsWith("zh")) return "zh-CN";
    if (lower.startsWith("en")) return "en";
    return lower.slice(0, 2);
  };
  return `${norm(from)}|${norm(to)}`;
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
const cooldown = new Map<ProviderId, number>();

function cooling(provider: ProviderId): boolean {
  const until = cooldown.get(provider);
  if (!until) return false;
  if (Date.now() > until) {
    cooldown.delete(provider);
    return false;
  }
  return true;
}

function markCooling(provider: ProviderId): void {
  cooldown.set(provider, Date.now() + COOLDOWN_MS);
}

/** Reset provider cooldowns (tests). */
export function resetProviderCooldown(): void {
  cooldown.clear();
}

interface ProxyResponse {
  ok: boolean;
  status: number;
  body: string;
  error: string | null;
}

async function viaTauri(term: string): Promise<LookupResult | null> {
  const res = await invoke<ProxyResponse>("lookup_word", { term });
  if (!res.ok) {
    if (res.status === 429) throw new LookupError("rate-limited");
    return null;
  }
  return parseYoudao(JSON.parse(res.body), term);
}

async function fetchJson(url: string, signal: AbortSignal): Promise<unknown> {
  const res = await fetch(url, { signal, headers: { Accept: "application/json" } });
  if (res.status === 429) throw new LookupError("rate-limited");
  if (!res.ok) throw new LookupError("offline", `http ${res.status}`);
  return res.json();
}

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

async function viaYoudaoWeb(
  term: string,
  from: string,
  to: string,
  signal: AbortSignal,
): Promise<LookupResult | null> {
  const url =
    "https://aidemo.youdao.com/trans?" +
    new URLSearchParams({ q: term, from: youdaoLang(from), to: youdaoLang(to) }).toString();
  const raw = await fetchJson(url, signal);
  const parsed = parseYoudaoTranslation(raw, term);
  if (!parsed && errorCodeOf(raw) === 411) throw new LookupError("rate-limited");
  return parsed;
}

async function viaMyMemory(
  term: string,
  from: string,
  to: string,
  signal: AbortSignal,
): Promise<LookupResult | null> {
  const url =
    "https://api.mymemory.translated.net/get?" +
    new URLSearchParams({ q: term, langpair: myMemoryPair(from, to) }).toString();
  return parseMyMemory(await fetchJson(url, signal), term);
}

async function viaGoogle(
  term: string,
  from: string,
  to: string,
  signal: AbortSignal,
): Promise<LookupResult | null> {
  const url =
    "https://translate.googleapis.com/translate_a/single?" +
    new URLSearchParams({
      client: "gtx",
      sl: youdaoLang(from),
      tl: youdaoLang(to),
      dt: "t",
      q: term,
    }).toString();
  return parseGoogle(await fetchJson(url, signal), term);
}

export interface LookupOptions {
  from?: string;
  to?: string;
  /** Skip the cache and re-fetch (the "重新翻译" button). */
  force?: boolean;
  signal?: AbortSignal;
}

/**
 * Look a term up, trying the cache first and then each provider in turn.
 *
 * Throws `LookupError` when every provider failed; `reason` lets the UI say
 * something more useful than "出错了".
 */
export async function lookupTerm(term: string, options: LookupOptions = {}): Promise<LookupResult> {
  const cleaned = normalizeTerm(term);
  if (!cleaned) throw new LookupError("not-found", "empty term");

  const from = options.from ?? "en";
  const to = options.to ?? "zh-CN";
  const key = cacheKey(cleaned, from, to);

  if (!options.force) {
    const cached = readCached(key);
    if (cached) return cached;
  }

  const signal = timeoutSignal(options.signal, 9_000);
  const attempts: { id: ProviderId; run: () => Promise<LookupResult | null> }[] = isTauri()
    ? [{ id: "youdao", run: () => viaTauri(cleaned) }]
    : [
        { id: "youdao-web", run: () => viaYoudaoWeb(cleaned, from, to, signal) },
        { id: "mymemory", run: () => viaMyMemory(cleaned, from, to, signal) },
        { id: "google", run: () => viaGoogle(cleaned, from, to, signal) },
      ];

  let rateLimited = false;
  let reachable = false;

  for (const attempt of attempts) {
    if (cooling(attempt.id)) {
      rateLimited = true;
      continue;
    }
    try {
      const result = await attempt.run();
      reachable = true;
      if (result) {
        writeCached(key, result);
        return result;
      }
    } catch (error) {
      if (options.signal?.aborted) throw error;
      if (error instanceof LookupError && error.reason === "rate-limited") {
        markCooling(attempt.id);
        rateLimited = true;
      }
    }
  }

  if (rateLimited) throw new LookupError("rate-limited");
  if (!reachable) throw new LookupError("offline");
  throw new LookupError("not-found");
}

/* ----------------------------------------------------------- formatting */

/** `"adj. 坦率的"` — part of speech kept, since it carries real information. */
export function primaryMeaning(result: LookupResult): string {
  const first = result.senses[0];
  if (!first) return "";
  return first.pos ? `${first.pos} ${first.meaning}` : first.meaning;
}

/** The remaining senses, joined the way Chinese dictionaries write them. */
export function alternativeMeaning(result: LookupResult): string {
  return result.senses
    .slice(1)
    .map((sense) => sense.meaning)
    .join("；");
}

/** All senses as one line — used for the "填入释义" preview and toasts. */
export function formatSenses(result: LookupResult): string {
  return result.senses.map((s) => (s.pos ? `${s.pos} ${s.meaning}` : s.meaning)).join("；");
}
