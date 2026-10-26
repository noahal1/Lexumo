// @vitest-environment jsdom
/**
 * Integration smoke test: mounts the real App (store + i18n + router + all
 * five pages) in jsdom and drives it like a user would.
 *
 * This is the safety net the unit tests cannot provide — it catches runtime
 * errors that TypeScript happily accepts (bad hook usage, undefined lookups,
 * broken component contracts) and proves every page actually renders.
 */
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";

import { App } from "@/App";
import { RouterProvider } from "@/app/router";
import { I18nProvider } from "@/i18n";
import { ToastProvider } from "@/components/ui";
import { getData, initStore, updateSettings } from "@/lib/store";

/* ------------------------------------------------------------------ */
/* Browser APIs jsdom does not implement                               */
/* ------------------------------------------------------------------ */

beforeAll(() => {
  Object.defineProperty(globalThis, "IS_REACT_ACT_ENVIRONMENT", {
    value: true,
    writable: true,
    configurable: true,
  });

  Object.defineProperty(window, "matchMedia", {
    writable: true,
    configurable: true,
    value: (query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }),
  });

  class FakeUtterance {
    text: string;
    lang = "";
    rate = 1;
    voice: unknown = null;
    onend: (() => void) | null = null;
    constructor(text: string) {
      this.text = text;
    }
  }
  Object.defineProperty(globalThis, "SpeechSynthesisUtterance", {
    writable: true,
    configurable: true,
    value: FakeUtterance,
  });

  Object.defineProperty(window, "speechSynthesis", {
    writable: true,
    configurable: true,
    value: {
      speaking: false,
      getVoices: () => [],
      addEventListener: () => {},
      removeEventListener: () => {},
      speak: () => {},
      cancel: () => {},
    },
  });
});

/* ------------------------------------------------------------------ */
/* Harness                                                             */
/* ------------------------------------------------------------------ */

let host: HTMLDivElement | null = null;
let root: Root | null = null;

async function mount(): Promise<HTMLDivElement> {
  await initStore();
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <I18nProvider>
        <ToastProvider>
          <RouterProvider>
            <App />
          </RouterProvider>
        </ToastProvider>
      </I18nProvider>,
    );
  });
  return host;
}

async function goto(page: string): Promise<void> {
  await act(async () => {
    window.location.hash = `#/${page}`;
    window.dispatchEvent(new HashChangeEvent("hashchange"));
  });
}

/** Click the first <button> whose visible text contains `label`. */
async function clickText(label: string): Promise<boolean> {
  const target = Array.from(document.querySelectorAll("button")).find((b) =>
    (b.textContent ?? "").includes(label),
  );
  if (!target) return false;
  await act(async () => {
    target.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  return true;
}

afterEach(async () => {
  if (root) {
    await act(async () => root!.unmount());
    root = null;
  }
  host?.remove();
  host = null;
  window.location.hash = "";
  vi.restoreAllMocks();
});

/* ------------------------------------------------------------------ */
/* Tests                                                               */
/* ------------------------------------------------------------------ */

describe("App smoke test", () => {
  it("mounts the shell with the seeded vocabulary", async () => {
    const errors: unknown[] = [];
    vi.spyOn(console, "error").mockImplementation((...args) => {
      errors.push(args);
    });

    const el = await mount();

    // Sidebar chrome is present.
    expect(el.textContent).toContain("Lexumo");
    expect(el.textContent).toContain("词砚");
    for (const label of ["词库", "闪卡", "测验", "统计", "设置"]) {
      expect(el.textContent).toContain(label);
    }

    // The seeded demo list rendered real words.
    const data = getData();
    expect(data.words.length).toBeGreaterThan(10);
    expect(el.textContent).toContain(data.words[0].term);

    // No React runtime errors / warnings.
    expect(errors).toEqual([]);
  });

  it("renders every page without crashing", async () => {
    const el = await mount();
    for (const page of ["words", "flashcards", "quiz", "stats", "settings"]) {
      await goto(page);
      const len = (el.textContent ?? "").length;
      expect(len, `page "${page}" rendered too little content`).toBeGreaterThan(80);
      expect(el.querySelector(".page-inner"), `page "${page}" missing page shell`).not.toBeNull();
    }
  });

  it("switches theme from settings and applies data-theme", async () => {
    await mount();
    await act(async () => {
      updateSettings({ theme: "dark" });
    });
    expect(document.documentElement.dataset.theme).toBe("dark");

    await act(async () => {
      updateSettings({ theme: "light" });
    });
    expect(document.documentElement.dataset.theme).toBe("light");
  });

  it("opens the word editor modal and closes it again", async () => {
    await mount();
    await goto("words");

    const opened = await clickText("添加词语");
    expect(opened).toBe(true);
    expect(document.querySelector(".modal")).not.toBeNull();

    // Cancel via the modal footer.
    const closed = await clickText("取消");
    expect(closed).toBe(true);
    expect(document.querySelector(".modal")).toBeNull();
  });

  it("filters the word list through the search box", async () => {
    const el = await mount();
    await goto("words");

    const input = el.querySelector<HTMLInputElement>("input.search-input, .search input");
    expect(input).not.toBeNull();
    const term = getData().words[0].term;
    await act(async () => {
      const setter = Object.getOwnPropertyDescriptor(
        HTMLInputElement.prototype,
        "value",
      )!.set!;
      setter.call(input!, term.slice(0, 4));
      input!.dispatchEvent(new Event("input", { bubbles: true }));
    });
    expect(el.textContent).toContain(term);
  });
});
