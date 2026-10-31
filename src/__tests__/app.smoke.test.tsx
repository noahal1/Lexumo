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

/** Set an input's value through React's own setter, then notify it. */
async function setInput(input: HTMLInputElement, value: string): Promise<void> {
  await act(async () => {
    const setter = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
    setter.call(input, value);
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });
}

/** Blur an input the way tabbing away does. */
async function blur(input: HTMLInputElement): Promise<void> {
  await act(async () => {
    input.dispatchEvent(new FocusEvent("focusout", { bubbles: true }));
    input.blur();
  });
  // Give any (wrong) asynchronous lookup a chance to actually start.
  await act(async () => {
    await new Promise((r) => setTimeout(r, 20));
  });
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

    // The five destinations are what the sidebar carries. The app's own name
    // moved to the window title bar, which only exists inside the desktop
    // shell, so it is asserted in its own test below.
    for (const label of ["词库", "闪卡", "测验", "统计", "设置"]) {
      expect(el.textContent).toContain(label);
    }

    // A browser tab has no window to minimize, so no title bar is drawn and
    // there are no buttons that would do nothing.
    expect(el.querySelector(".frame-bar")).toBeNull();

    // The seeded demo list rendered real words.
    const data = getData();
    expect(data.words.length).toBeGreaterThan(10);
    expect(el.textContent).toContain(data.words[0].term);

    // No React runtime errors / warnings.
    expect(errors).toEqual([]);
  });

  it("draws the window title bar only inside the desktop shell", async () => {
    (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__ = {};
    try {
      const el = await mount();

      const bar = el.querySelector(".frame-bar");
      expect(bar).not.toBeNull();
      // The whole bar drags, including the name and the gaps between buttons.
      expect(bar!.getAttribute("data-tauri-drag-region")).toBe("deep");

      expect(el.textContent).toContain("Lexumo");
      expect(el.textContent).toContain("词砚");

      const labels = Array.from(bar!.querySelectorAll("button")).map((b) =>
        b.getAttribute("aria-label"),
      );
      expect(labels).toEqual(["最小化", "最大化", "关闭"]);
    } finally {
      delete (window as unknown as Record<string, unknown>).__TAURI_INTERNALS__;
    }
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

  /**
   * Regression for the request "不要自动补齐翻译什么的 必须要手动点击翻译":
   * typing a word and tabbing away must not fire a lookup. The old code did it
   * on blur, which meant a network request and rewritten fields while the user
   * was still typing.
   */
  it("never looks a word up on blur — only on an explicit click", async () => {
    const fetchSpy = vi.fn<typeof fetch>(async () => {
      throw new Error("no network in this test");
    });
    vi.stubGlobal("fetch", fetchSpy);

    try {
      const el = await mount();
      await goto("words");
      expect(await clickText("添加词语")).toBe(true);

      const term = el.querySelector<HTMLInputElement>("#word-term");
      const def = el.querySelector<HTMLInputElement>("#word-def");
      expect(term).not.toBeNull();
      expect(def).not.toBeNull();

      // Typing the word, then leaving the field, must stay silent.
      await setInput(term!, "apple");
      await blur(term!);
      // Typing a meaning must not trigger the reverse pass either.
      await setInput(def!, "苹果");
      await blur(def!);

      expect(fetchSpy).not.toHaveBeenCalled();
      // Nothing was filled in behind the user's back.
      expect(def!.value).toBe("苹果");

      // The button is the one thing that does look it up — it is disabled
      // while empty, so the field above had to be typed first to reach here.
      const translate = Array.from(document.querySelectorAll("button")).find(
        (b) => (b.textContent ?? "").includes("翻译") && !(b as HTMLButtonElement).disabled,
      );
      expect(translate).toBeDefined();
    } finally {
      vi.unstubAllGlobals();
    }
  });

  /**
   * Regression for "我没法打字 打一个字母就跳出": the dialog's focus effect
   * listed `onClose` as a dependency. Every parent render rebuilds that closure,
   * and every keystroke renders, so each typed character re-ran the effect and
   * re-focused the first control — the caret jumped out of the field after one
   * letter. The effect now runs only when the dialog opens.
   */
  it("keeps the caret in the field being typed into", async () => {
    const el = await mount();
    await goto("words");
    expect(await clickText("添加词语")).toBe(true);

    // The dialog opens with the caret in the word field, not on a button.
    const term = el.querySelector<HTMLInputElement>("#word-term");
    const def = el.querySelector<HTMLInputElement>("#word-def");
    expect(term).not.toBeNull();
    expect(def).not.toBeNull();
    expect(document.activeElement).toBe(term);

    // Each keystroke re-renders; focus must survive all of them.
    await setInput(term!, "candid");
    expect(document.activeElement).toBe(term);
    expect(term!.value).toBe("candid");

    // Same for the meaning field, which is what the user hits second.
    await act(async () => def!.focus());
    await setInput(def!, "坦率");
    expect(document.activeElement).toBe(def);
    expect(def!.value).toBe("坦率");

    // Nothing was dismissed along the way.
    expect(document.querySelector(".modal")).not.toBeNull();
  });
});
