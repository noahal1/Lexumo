// @vitest-environment jsdom
/**
 * The two paths where a failure has no natural owner on screen.
 *
 * Both are invisible in ordinary use — one only fires when a render throws, the
 * other when the device refuses to persist — which is exactly why they are
 * worth pinning: nobody will notice them rotting until the day the app blanks
 * out or silently drops an edit.
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { ErrorBoundary } from "@/components/ErrorBoundary";
import { I18nProvider } from "@/i18n";
import { onError, reportError } from "@/lib/errors";
import { saveSnapshot } from "@/lib/db";
import type { AppData } from "@/lib/types";

let root: Root | null = null;
let container: HTMLDivElement | null = null;

beforeAll(() => {
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", {
    value: true,
    writable: true,
    configurable: true,
  });
});

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  container?.remove();
  root = null;
  container = null;
  vi.restoreAllMocks();
});

function Boom(): never {
  throw new Error("render exploded");
}

describe("error channel", () => {
  it("delivers to every listener and survives one of them throwing", () => {
    const first = vi.fn();
    const second = vi.fn();
    const offFirst = onError(first);
    const offSecond = onError(second);
    const offBad = onError(() => {
      throw new Error("listener is broken");
    });

    expect(() => reportError("store-write", { reason: "quota" })).not.toThrow();
    expect(first).toHaveBeenCalledWith("store-write", { reason: "quota" });
    expect(second).toHaveBeenCalledWith("store-write", { reason: "quota" });

    offFirst();
    offSecond();
    offBad();
    first.mockClear();
    reportError("render");
    expect(first).not.toHaveBeenCalled();
  });
});

describe("render crash", () => {
  it("replaces the tree with the recovery card instead of a blank window", async () => {
    // React re-throws caught render errors to the console; that is expected here.
    vi.spyOn(console, "error").mockImplementation(() => {});

    const seen: string[] = [];
    const off = onError((kind) => seen.push(kind));

    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);

    await act(async () => {
      root!.render(
        <I18nProvider>
          <ErrorBoundary>
            <Boom />
          </ErrorBoundary>
        </I18nProvider>,
      );
    });

    const text = container.textContent ?? "";
    expect(text).toContain("这个页面出了点问题");
    expect(text).toContain("词条都还在本机");
    expect(container.querySelector("button")?.textContent).toBe("重新载入");
    expect(seen).toContain("render");

    off();
  });
});

describe("storage failure", () => {
  it("reports store-write when the snapshot cannot be persisted anywhere", async () => {
    const seen: string[] = [];
    const off = onError((kind) => seen.push(kind));

    // jsdom has no IndexedDB, so the adapter already falls through to
    // localStorage; make that fallback fail too and the last resort is memory.
    const setItem = vi
      .spyOn(Storage.prototype, "setItem")
      .mockImplementation(() => {
        throw new DOMException("quota exceeded", "QuotaExceededError");
      });

    await saveSnapshot({ words: [], lists: [], logs: [], settings: {} } as unknown as AppData);

    expect(seen).toEqual(["store-write"]);
    expect(setItem).toHaveBeenCalled();

    off();
  });
});
