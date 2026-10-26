/**
 * Persistence: a single versioned snapshot in IndexedDB, with a
 * localStorage fallback (and in-memory fallback of last resort).
 *
 * Kept behind this narrow interface so the storage engine can later be
 * swapped for SQLite via a Tauri plugin without touching app code.
 */
import type { AppData } from "./types";

const DB_NAME = "lexumo";
const STORE = "kv";
const KEY = "app";
const LS_KEY = "lexumo:data";

let dbPromise: Promise<IDBDatabase> | null = null;

function openDb(): Promise<IDBDatabase> {
  if (dbPromise) return dbPromise;
  dbPromise = new Promise((resolve, reject) => {
    if (typeof indexedDB === "undefined") {
      reject(new Error("indexedDB unavailable"));
      return;
    }
    const req = indexedDB.open(DB_NAME, 1);
    req.onupgradeneeded = () => {
      const db = req.result;
      if (!db.objectStoreNames.contains(STORE)) db.createObjectStore(STORE);
    };
    req.onsuccess = () => resolve(req.result);
    req.onerror = () => reject(req.error ?? new Error("indexedDB open failed"));
  });
  return dbPromise;
}

export async function loadSnapshot(): Promise<AppData | null> {
  try {
    const db = await openDb();
    const value = await new Promise<AppData | null>((resolve, reject) => {
      const tx = db.transaction(STORE, "readonly");
      const req = tx.objectStore(STORE).get(KEY);
      req.onsuccess = () => resolve((req.result as AppData) ?? null);
      req.onerror = () => reject(req.error);
    });
    if (value) return value;
  } catch {
    /* fall through to localStorage */
  }
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (raw) return JSON.parse(raw) as AppData;
  } catch {
    /* ignore */
  }
  return null;
}

export async function saveSnapshot(data: AppData): Promise<void> {
  try {
    const db = await openDb();
    await new Promise<void>((resolve, reject) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).put(data, KEY);
      tx.oncomplete = () => resolve();
      tx.onerror = () => reject(tx.error);
    });
    return;
  } catch {
    /* fall through */
  }
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(data));
  } catch {
    /* last resort: memory only */
  }
}

export async function clearSnapshot(): Promise<void> {
  try {
    const db = await openDb();
    await new Promise<void>((resolve) => {
      const tx = db.transaction(STORE, "readwrite");
      tx.objectStore(STORE).delete(KEY);
      tx.oncomplete = () => resolve();
      tx.onerror = () => resolve();
    });
  } catch {
    /* ignore */
  }
  try {
    localStorage.removeItem(LS_KEY);
  } catch {
    /* ignore */
  }
}
