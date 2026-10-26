/**
 * Account + multi-device sync client.
 *
 * Local-first: every mutation lands in the local snapshot first; this module
 * only mirrors it to the self-hosted server in the background. See
 * docs/sync-protocol.md for the wire contract.
 *
 * The engine is intentionally tiny: one `POST /api/sync` per round that both
 * pushes pending records and pulls everything newer than the last revision we
 * have seen.
 */
import {
  applyRemoteChanges,
  getChangesToPush,
  getData,
  markPushed,
  pendingChangeCount,
} from "./store";
import { hasChanges } from "./syncMerge";
import { onLocalChange } from "./localChanges";
import type { ChangeSet } from "./types";

const CONFIG_KEY = "lexumo.sync.v1";
/** Default server shown in the settings form. */
export const DEFAULT_SERVER = "http://127.0.0.1:8787";

export interface SyncConfig {
  server: string;
  email: string;
  token: string;
  /** Highest server revision we have merged. */
  rev: number;
  lastSyncAt: number;
}

export type SyncState = "signed-out" | "idle" | "syncing" | "error";

export interface SyncStatus {
  state: SyncState;
  /** Human readable reason for the last failure (i18n key or raw message). */
  error: SyncError | null;
  lastSyncAt: number;
  /** Records waiting to be pushed. */
  pending: number;
  email: string;
  server: string;
}

export type SyncError =
  | "offline"
  | "unauthorized"
  | "server"
  | "bad_credentials"
  | "email_taken"
  | "weak_password"
  | "invalid_email";

/* ------------------------------------------------------------------ */
/* Config persistence                                                  */
/* ------------------------------------------------------------------ */

function readConfig(): SyncConfig | null {
  if (typeof localStorage === "undefined") return null;
  try {
    const raw = localStorage.getItem(CONFIG_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<SyncConfig>;
    if (!parsed.server || !parsed.token || !parsed.email) return null;
    return {
      server: parsed.server,
      email: parsed.email,
      token: parsed.token,
      rev: typeof parsed.rev === "number" ? parsed.rev : 0,
      lastSyncAt: typeof parsed.lastSyncAt === "number" ? parsed.lastSyncAt : 0,
    };
  } catch {
    return null;
  }
}

function writeConfig(config: SyncConfig | null) {
  if (typeof localStorage === "undefined") return;
  try {
    if (config) localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
    else localStorage.removeItem(CONFIG_KEY);
  } catch {
    /* storage full / private mode — sync just won't survive a reload */
  }
}

export function getSyncConfig(): SyncConfig | null {
  return readConfig();
}

export function isSignedIn(): boolean {
  return readConfig() !== null;
}

/* ------------------------------------------------------------------ */
/* Status observable (for the settings page)                           */
/* ------------------------------------------------------------------ */

let status: SyncStatus = deriveStatus(null);
const listeners = new Set<() => void>();

function deriveStatus(config: SyncConfig | null, patch?: Partial<SyncStatus>): SyncStatus {
  return {
    state: config ? "idle" : "signed-out",
    error: null,
    lastSyncAt: config?.lastSyncAt ?? 0,
    pending: pendingChangeCount(),
    email: config?.email ?? "",
    server: config?.server ?? DEFAULT_SERVER,
    ...patch,
  };
}

function publish(patch?: Partial<SyncStatus>, config = readConfig()) {
  status = { ...deriveStatus(config), ...patch, pending: pendingChangeCount() };
  for (const fn of listeners) fn();
}

export function getSyncStatus(): SyncStatus {
  return status;
}

export function subscribeSyncStatus(fn: () => void): () => void {
  listeners.add(fn);
  return () => listeners.delete(fn);
}

/** Refresh the pending counter after local mutations. */
export function refreshSyncStatus() {
  if (status.pending === pendingChangeCount()) return;
  publish({ pending: pendingChangeCount() });
}

/* ------------------------------------------------------------------ */
/* HTTP                                                                */
/* ------------------------------------------------------------------ */

function normalizeServer(server: string): string {
  return server.trim().replace(/\/+$/, "");
}

class HttpError extends Error {
  constructor(
    readonly kind: SyncError,
    readonly status: number,
  ) {
    super(kind);
  }
}

async function request<T>(
  server: string,
  path: string,
  init: { method?: string; body?: unknown; token?: string } = {},
): Promise<T> {
  const headers: Record<string, string> = { "content-type": "application/json" };
  if (init.token) headers.authorization = `Bearer ${init.token}`;
  let res: Response;
  try {
    res = await fetch(`${normalizeServer(server)}${path}`, {
      method: init.method ?? "GET",
      headers,
      body: init.body === undefined ? undefined : JSON.stringify(init.body),
    });
  } catch {
    throw new HttpError("offline", 0);
  }
  if (res.status === 204) return undefined as T;
  const text = await res.text();
  let payload: unknown = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = null;
    }
  }
  if (!res.ok) {
    const code = (payload as { error?: string } | null)?.error;
    const known: SyncError[] = [
      "unauthorized",
      "bad_credentials",
      "email_taken",
      "weak_password",
      "invalid_email",
    ];
    const kind = known.includes(code as SyncError)
      ? (code as SyncError)
      : res.status === 401
        ? "unauthorized"
        : "server";
    throw new HttpError(kind, res.status);
  }
  return payload as T;
}

/* ------------------------------------------------------------------ */
/* Auth                                                               */
/* ------------------------------------------------------------------ */

interface AuthResponse {
  token: string;
  email: string;
  rev: number;
}

export async function register(
  server: string,
  email: string,
  password: string,
): Promise<void> {
  const res = await request<AuthResponse>(server, "/api/auth/register", {
    method: "POST",
    body: { email, password },
  });
  adoptSession(server, res);
}

export async function login(server: string, email: string, password: string): Promise<void> {
  const res = await request<AuthResponse>(server, "/api/auth/login", {
    method: "POST",
    body: { email, password },
  });
  adoptSession(server, res);
}

function adoptSession(server: string, res: AuthResponse) {
  writeConfig({
    server: normalizeServer(server),
    email: res.email,
    token: res.token,
    // Start from zero so the first sync pulls the whole account down; pending
    // local records are pushed in the same round.
    rev: 0,
    lastSyncAt: 0,
  });
  publish({ state: "idle", error: null }, readConfig());
}

export async function signOut(): Promise<void> {
  const config = readConfig();
  writeConfig(null);
  publish({ state: "signed-out", error: null, lastSyncAt: 0 }, null);
  if (!config) return;
  try {
    await request(config.server, "/api/auth/logout", { method: "POST", token: config.token });
  } catch {
    /* best effort: the local session is already gone */
  }
}

export async function testConnection(server: string): Promise<boolean> {
  try {
    await request(server, "/api/health");
    return true;
  } catch {
    return false;
  }
}

/* ------------------------------------------------------------------ */
/* Sync                                                               */
/* ------------------------------------------------------------------ */

interface SyncResponse {
  rev: number;
  serverTime: number;
  changes: ChangeSet;
}

const EMPTY_CHANGES: ChangeSet = { words: [], lists: [], logs: [], settings: null };

let inFlight: Promise<boolean> | null = null;

/**
 * Push local changes and merge whatever the server has newer.
 * Returns true when the round succeeded. Concurrent callers share one request.
 */
export function syncNow(): Promise<boolean> {
  if (inFlight) return inFlight;
  inFlight = runSync().finally(() => {
    inFlight = null;
  });
  return inFlight;
}

async function runSync(): Promise<boolean> {
  const config = readConfig();
  if (!config) {
    publish({ state: "signed-out" }, null);
    return false;
  }
  publish({ state: "syncing", error: null }, config);
  const pushed = getChangesToPush();
  try {
    const res = await request<SyncResponse>(config.server, "/api/sync", {
      method: "POST",
      token: config.token,
      body: { since: config.rev, changes: hasChanges(pushed) ? pushed : EMPTY_CHANGES },
    });
    // Clear the pending flags *before* merging so that a record the user edits
    // during the request is not silently marked as synced.
    if (hasChanges(pushed)) markPushed(pushed);
    applyRemoteChanges(res.changes ?? EMPTY_CHANGES);
    const next: SyncConfig = {
      ...config,
      rev: res.rev,
      lastSyncAt: res.serverTime || Date.now(),
    };
    writeConfig(next);
    publish({ state: "idle", error: null, lastSyncAt: next.lastSyncAt }, next);
    return true;
  } catch (err) {
    const kind = err instanceof HttpError ? err.kind : "offline";
    if (kind === "unauthorized") {
      writeConfig(null);
      publish({ state: "signed-out", error: "unauthorized" }, null);
      return false;
    }
    publish({ state: "error", error: kind }, config);
    return false;
  }
}

/* ------------------------------------------------------------------ */
/* Auto sync                                                           */
/* ------------------------------------------------------------------ */

let timer: ReturnType<typeof setInterval> | null = null;
let started = false;
let soonTimer: ReturnType<typeof setTimeout> | null = null;

/** Sync when the app regains connectivity or focus. */
function onWake() {
  if (!isSignedIn()) return;
  if (!getData().settings.autoSync) return;
  void syncNow();
}

/** Debounced push right after a local edit, so devices converge quickly. */
function scheduleSoon() {
  if (!isSignedIn()) return;
  if (!getData().settings.autoSync) return;
  if (soonTimer) clearTimeout(soonTimer);
  soonTimer = setTimeout(() => {
    soonTimer = null;
    if (!isSignedIn() || !getData().settings.autoSync) return;
    void syncNow();
  }, 2_500);
}

/** Boot the background loop (idempotent). */
export function initSync(): void {
  publish({}, readConfig());
  if (started) return;
  started = true;
  if (typeof window === "undefined") return;
  window.addEventListener("online", onWake);
  window.addEventListener("focus", onWake);
  onLocalChange(() => {
    refreshSyncStatus();
    scheduleSoon();
  });
  // Lightweight poll: the store has no change hooks, and this only fires work
  // when something is actually waiting to be pushed.
  timer = setInterval(() => {
    if (!isSignedIn()) return;
    if (!getData().settings.autoSync) return;
    if (pendingChangeCount() === 0) return;
    void syncNow();
  }, 15_000);
  // First round shortly after boot, so a fresh device fills up quickly.
  setTimeout(() => {
    if (isSignedIn() && getData().settings.autoSync) void syncNow();
  }, 800);
}

export function stopSyncLoop(): void {
  if (timer) clearInterval(timer);
  if (soonTimer) clearTimeout(soonTimer);
  timer = null;
  soonTimer = null;
  started = false;
}
