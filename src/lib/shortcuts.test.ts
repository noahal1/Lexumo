import { describe, expect, it, vi } from "vitest";

import {
  SCOPE_PRECEDENCE,
  SHORTCUTS,
  SHORTCUT_HELP,
  ShortcutRegistry,
  shouldIgnoreKey,
  type KeyEventLike,
  type ShortcutBinding,
  type ShortcutScope,
} from "./shortcuts";

/** A keydown event with only the fields a test cares about. */
function keyEvent(overrides: Partial<KeyEventLike> = {}): KeyEventLike {
  return { key: "x", ...overrides };
}

function editable(tagName: string, isContentEditable = false): unknown {
  return { tagName, isContentEditable };
}

/** Build a binding whose match is `key === wanted` unless overridden. */
function binding(
  id: string,
  scope: ShortcutScope,
  run: (event: KeyEventLike) => void,
  extra: Partial<ShortcutBinding> = {},
): ShortcutBinding {
  return {
    id,
    keys: [],
    // The label is irrelevant to these tests; use a real key so the typed
    // registry accepts the binding.
    labelKey: "shortcuts.help",
    scope,
    match: (event) => event.key === "x",
    run,
    ...extra,
  };
}

describe("shouldIgnoreKey — the one IME-aware guard", () => {
  it("ignores every editable target kind", () => {
    for (const target of [
      editable("INPUT"),
      editable("input"),
      editable("TEXTAREA"),
      editable("SELECT"),
      editable("DIV", true),
    ]) {
      expect(shouldIgnoreKey(keyEvent({ target }))).toBe(true);
    }
  });

  it("does not ignore non-editable targets", () => {
    for (const target of [editable("DIV"), editable("BUTTON"), undefined, {}]) {
      expect(shouldIgnoreKey(keyEvent({ target }))).toBe(false);
    }
  });

  it("ignores keys that belong to an IME composition", () => {
    expect(shouldIgnoreKey(keyEvent({ isComposing: true }))).toBe(true);
    expect(shouldIgnoreKey(keyEvent({ isComposing: true, target: editable("DIV") }))).toBe(
      true,
    );
  });

  it("ignores the legacy IME keyCode 229", () => {
    expect(shouldIgnoreKey(keyEvent({ keyCode: 229 }))).toBe(true);
  });

  it("does not ignore ordinary keys", () => {
    expect(shouldIgnoreKey(keyEvent({ keyCode: 13 }))).toBe(false);
    expect(shouldIgnoreKey(keyEvent({ isComposing: false, keyCode: 229 + 1 }))).toBe(
      false,
    );
  });

  it("lets opt-in bindings bypass the guard (Escape in a field)", () => {
    expect(shouldIgnoreKey(keyEvent({ target: editable("INPUT") }), true)).toBe(false);
    expect(shouldIgnoreKey(keyEvent({ isComposing: true }), true)).toBe(false);
  });
});

describe("ShortcutRegistry — declared precedence modal > page > app", () => {
  it("declares the precedence order once, highest first", () => {
    expect(SCOPE_PRECEDENCE).toEqual(["modal", "page", "app"]);
  });

  it("runs only the highest scope with a matching binding", () => {
    const registry = new ShortcutRegistry();
    const calls: string[] = [];
    registry.addScope("app", () => [binding("app", "app", () => calls.push("app"))]);
    registry.addScope("page", () => [
      binding("page", "page", () => calls.push("page")),
    ]);
    registry.addScope("modal", () => [
      binding("modal", "modal", () => calls.push("modal")),
    ]);

    expect(registry.handle(keyEvent())).toBe(true);
    expect(calls).toEqual(["modal"]);
  });

  it("falls back to the page when the modal has no matching binding", () => {
    const registry = new ShortcutRegistry();
    const calls: string[] = [];
    registry.addScope("modal", () => [
      binding("modal", "modal", () => calls.push("modal"), {
        match: (event) => event.key === "Escape",
      }),
    ]);
    registry.addScope("page", () => [
      binding("page", "page", () => calls.push("page")),
    ]);

    expect(registry.handle(keyEvent({ key: "x" }))).toBe(true);
    expect(calls).toEqual(["page"]);
  });

  it("falls through a binding whose precondition is false", () => {
    const registry = new ShortcutRegistry();
    const calls: string[] = [];
    registry.addScope("modal", () => [
      binding("modal", "modal", () => calls.push("modal"), { when: () => false }),
    ]);
    registry.addScope("page", () => [
      binding("page", "page", () => calls.push("page")),
    ]);

    expect(registry.handle(keyEvent())).toBe(true);
    expect(calls).toEqual(["page"]);
  });

  it("tries app only after page is removed", () => {
    const registry = new ShortcutRegistry();
    const calls: string[] = [];
    registry.addScope("app", () => [binding("app", "app", () => calls.push("app"))]);
    const disposePage = registry.addScope("page", () => [
      binding("page", "page", () => calls.push("page")),
    ]);

    registry.handle(keyEvent());
    disposePage();
    registry.handle(keyEvent());
    expect(calls).toEqual(["page", "app"]);
  });
});

describe("ShortcutRegistry — consumption", () => {
  it("prevents the default and does not run lower scopes", () => {
    const registry = new ShortcutRegistry();
    const preventDefault = vi.fn();
    const lower = vi.fn();
    const order: string[] = [];
    registry.addScope("page", () => [
      binding("page", "page", () => {
        order.push("run");
      }),
    ]);
    registry.addScope("app", () => [binding("app", "app", lower)]);

    expect(
      registry.handle(
        keyEvent({
          preventDefault: () => {
            order.push("prevent");
            preventDefault();
          },
        }),
      ),
    ).toBe(true);
    expect(preventDefault).toHaveBeenCalledTimes(1);
    expect(lower).not.toHaveBeenCalled();
    expect(order).toEqual(["prevent", "run"]);
  });

  it("does nothing at all when no binding matches", () => {
    const registry = new ShortcutRegistry();
    const preventDefault = vi.fn();
    const run = vi.fn();
    registry.addScope("page", () => [
      binding("page", "page", run, { match: (event) => event.key === "z" }),
    ]);

    expect(registry.handle(keyEvent({ key: "x", preventDefault }))).toBe(false);
    expect(preventDefault).not.toHaveBeenCalled();
    expect(run).not.toHaveBeenCalled();
  });

  it("skips a binding the typing guard ignores, without consuming", () => {
    const registry = new ShortcutRegistry();
    const preventDefault = vi.fn();
    const run = vi.fn();
    registry.addScope("page", () => [binding("page", "page", run)]);

    expect(
      registry.handle(
        keyEvent({ target: editable("INPUT"), preventDefault }),
      ),
    ).toBe(false);
    expect(run).not.toHaveBeenCalled();
    expect(preventDefault).not.toHaveBeenCalled();
  });

  it("runs an opt-in binding even when the target is editable", () => {
    const registry = new ShortcutRegistry();
    const run = vi.fn();
    registry.addScope("modal", () => [
      binding("modal", "modal", run, { allowWhenTyping: true }),
    ]);

    expect(registry.handle(keyEvent({ target: editable("TEXTAREA") }))).toBe(true);
    expect(run).toHaveBeenCalledTimes(1);
  });
});

describe("ShortcutRegistry — unmount cleanup", () => {
  it("stops dispatching after the scope is disposed", () => {
    const registry = new ShortcutRegistry();
    const run = vi.fn();
    const dispose = registry.addScope("page", () => [binding("page", "page", run)]);

    expect(registry.handle(keyEvent())).toBe(true);
    dispose();
    expect(registry.handle(keyEvent())).toBe(false);
    expect(run).toHaveBeenCalledTimes(1);
  });

  it("tolerates disposing twice", () => {
    const registry = new ShortcutRegistry();
    const dispose = registry.addScope("app", () => []);
    expect(() => {
      dispose();
      dispose();
    }).not.toThrow();
  });
});

describe("SHORTCUT_HELP — the sheet is generated from the registry", () => {
  it("keeps the nine rows the hand-written sheet had, in order", () => {
    expect(SHORTCUT_HELP.map((shortcut) => shortcut.id)).toEqual([
      "app.pageSwitch",
      "app.help",
      "words.search",
      "words.addWord",
      "flashcards.flip",
      "flashcards.grade",
      "flashcards.undo",
      "flashcards.skip",
      "modal.escape",
    ]);
  });

  it("leaves contextual quiz keys out of the sheet but keeps them registered", () => {
    expect(SHORTCUT_HELP.some((shortcut) => shortcut.id === "quiz.choose")).toBe(false);
    expect(SHORTCUTS.quizChoose.scope).toBe("page");
    expect(SHORTCUTS.quizAnswer.keys).toEqual(["Enter"]);
  });

  it("labels every row through i18n and declares the modal scope", () => {
    for (const shortcut of SHORTCUT_HELP) {
      expect(shortcut.labelKey.length).toBeGreaterThan(0);
      expect(shortcut.keys.length).toBeGreaterThan(0);
    }
    expect(SHORTCUTS.closeModal.scope).toBe("modal");
    expect(SHORTCUTS.pageSwitch.scope).toBe("app");
    expect(SHORTCUTS.addWord.scope).toBe("page");
  });
});
