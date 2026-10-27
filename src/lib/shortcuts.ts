/**
 * Keyboard shortcuts: one IME-aware guard, one document listener, three scopes.
 *
 * The app used to attach five separate `keydown` listeners (App, WordsPage,
 * FlashcardsPage, QuizPage, Modal), each with its own copy of the "don't fire
 * while typing" check. The copies disagreed (two forgot SELECT, none checked
 * `isComposing`), so typing pinyin could fire page shortcuts. This module is
 * the single seam: every binding goes through `shouldIgnoreKey`, and the only
 * listener on the document is the one installed by `getShortcutRegistry`.
 *
 * Scopes are declared, not inferred. `SCOPE_PRECEDENCE` is the one place that
 * says a modal outranks the page, and the page outranks the app shell. A
 * binding that handles a key consumes it: lower scopes never see it and the
 * browser default is prevented. A scope that has no matching binding lets the
 * key fall through — that is how Escape closes a modal while the page behind
 * keeps its own shortcuts.
 */
import { useEffect, useRef } from "react";
import type { MessageKey } from "@/i18n/locales/zh-CN";

/** Where a binding lives. Ordered by `SCOPE_PRECEDENCE`, highest first. */
export type ShortcutScope = "modal" | "page" | "app";

/**
 * The single declaration of scope precedence: modal > page > app.
 * The registry walks this list and stops at the first binding that handles the
 * event, so reordering this array changes which scope wins.
 */
export const SCOPE_PRECEDENCE: readonly ShortcutScope[] = ["modal", "page", "app"];

/**
 * The part of a KeyboardEvent the registry needs. Real KeyboardEvents are
 * assignable to this, and tests can pass plain objects (no DOM required).
 */
export interface KeyEventLike {
  key: string;
  code?: string;
  keyCode?: number;
  isComposing?: boolean;
  metaKey?: boolean;
  ctrlKey?: boolean;
  altKey?: boolean;
  shiftKey?: boolean;
  target?: unknown;
  preventDefault?: () => void;
}

/** Static description of a shortcut, shared by the binding and the help sheet. */
export interface ShortcutDefinition {
  /** Stable id, e.g. "words.addWord". */
  id: string;
  /** Human-readable key caps, e.g. ["Ctrl", "1…5"]. */
  keys: string[];
  /** i18n key for the label. */
  labelKey: MessageKey;
  scope: ShortcutScope;
  /** Contextual shortcuts are registered but left out of the global help sheet. */
  showInHelp?: boolean;
}

/** A definition plus the behaviour that decides and handles the event. */
export interface ShortcutBinding extends ShortcutDefinition {
  match: (event: KeyEventLike) => boolean;
  run: (event: KeyEventLike) => void;
  /**
   * Bypass the typing guard. Used by bindings that must work while an input is
   * focused (Escape in a dialog, Ctrl+digit page switch — the old listeners
   * allowed both while typing).
   */
  allowWhenTyping?: boolean;
  /**
   * Extra precondition. Returning false does not consume the key; lower scopes
   * still get a chance at it.
   */
  when?: (event: KeyEventLike) => boolean;
}

function isEditableTarget(target: unknown): boolean {
  const el = target as { tagName?: string; isContentEditable?: boolean } | null;
  if (!el || typeof el.tagName !== "string") return false;
  const tag = el.tagName.toUpperCase();
  return (
    tag === "INPUT" ||
    tag === "TEXTAREA" ||
    tag === "SELECT" ||
    el.isContentEditable === true
  );
}

/**
 * The one guard. Returns true when a keydown must not trigger a shortcut:
 *
 * - the event is part of an IME composition (`isComposing`, or the legacy
 *   `keyCode === 229`), so pinyin "n"/Space/"1" never leave the input; or
 * - the event targets an editable element (input, textarea, select,
 *   contenteditable), where single-key shortcuts would eat the keystroke.
 *
 * `allowWhenTyping` opts a binding out of both checks (the modal's Escape).
 */
export function shouldIgnoreKey(
  event: KeyEventLike,
  allowWhenTyping = false,
): boolean {
  if (allowWhenTyping) return false;
  if (event.isComposing === true || event.keyCode === 229) return true;
  return isEditableTarget(event.target);}

type BindingsProvider = () => readonly ShortcutBinding[];

/**
 * Holds the active bindings per scope. Components add a provider on mount and
 * remove it on unmount; `handle` resolves an event against all of them in
 * `SCOPE_PRECEDENCE` order.
 */
export class ShortcutRegistry {
  private providers = new Map<ShortcutScope, BindingsProvider[]>();

  /** Register a live bindings provider for a scope. Returns the disposer. */
  addScope(scope: ShortcutScope, provide: BindingsProvider): () => void {
    const current = this.providers.get(scope) ?? [];
    this.providers.set(scope, [...current, provide]);
    let disposed = false;
    return () => {
      if (disposed) return;
      disposed = true;
      const remaining = (this.providers.get(scope) ?? []).filter(
        (candidate) => candidate !== provide,
      );
      this.providers.set(scope, remaining);
    };
  }

  /**
   * Resolve and run the highest-precedence binding for `event`.
   * Returns true when a binding handled it (its `preventDefault` was called).
   */
  handle(event: KeyEventLike): boolean {
    for (const scope of SCOPE_PRECEDENCE) {
      for (const provide of this.providers.get(scope) ?? []) {
        for (const binding of provide()) {
          if (!binding.match(event)) continue;
          if (shouldIgnoreKey(event, binding.allowWhenTyping === true)) continue;
          if (binding.when && !binding.when(event)) continue;
          event.preventDefault?.();
          binding.run(event);
          return true;
        }
      }
    }
    return false;
  }
}

let singleton: ShortcutRegistry | null = null;
let listening = false;

/**
 * The app-wide registry. The first call installs the single document-level
 * `keydown` listener; every scope funnels through it.
 */
export function getShortcutRegistry(): ShortcutRegistry {
  if (!singleton) {
    singleton = new ShortcutRegistry();
    if (!listening && typeof document !== "undefined") {
      listening = true;
      document.addEventListener("keydown", (event) => {
        singleton?.handle(event);
      });
    }
  }
  return singleton;
}

/**
 * Declare the bindings for `scope` while the calling component is mounted.
 * The ref keeps the newest closures visible to the provider without making the
 * effect re-run on every render.
 */
export function useShortcutScope(
  scope: ShortcutScope,
  bindings: ShortcutBinding[],
): void {
  const latest = useRef(bindings);
  latest.current = bindings;
  useEffect(() => {
    return getShortcutRegistry().addScope(scope, () => latest.current);
  }, [scope]);
}

/**
 * Every shortcut in the app, in the order the help sheet shows them.
 * Bindings spread the definition they use, so display keys, labels and scopes
 * cannot drift from the behaviour.
 */
const definitions = {
  pageSwitch: {
    id: "app.pageSwitch",
    keys: ["Ctrl", "1…5"],
    labelKey: "shortcuts.pageSwitch",
    scope: "app",
  },
  help: {
    id: "app.help",
    keys: ["?"],
    labelKey: "shortcuts.help",
    scope: "app",
  },
  search: {
    id: "words.search",
    keys: ["/"],
    labelKey: "settings.shortcutSearch",
    scope: "page",
  },
  addWord: {
    id: "words.addWord",
    keys: ["n"],
    labelKey: "settings.shortcutAdd",
    scope: "page",
  },
  flip: {
    id: "flashcards.flip",
    keys: ["空格"],
    labelKey: "settings.shortcutFlip",
    scope: "page",
  },
  grade: {
    id: "flashcards.grade",
    keys: ["1", "2", "3"],
    labelKey: "shortcuts.grade",
    scope: "page",
  },
  undo: {
    id: "flashcards.undo",
    keys: ["Ctrl", "Z"],
    labelKey: "shortcuts.undo",
    scope: "page",
  },
  skip: {
    id: "flashcards.skip",
    keys: ["←", "→"],
    labelKey: "shortcuts.skip",
    scope: "page",
  },
  closeModal: {
    id: "modal.escape",
    keys: ["Esc"],
    labelKey: "shortcuts.closeModal",
    scope: "modal",
  },
  quizChoose: {
    id: "quiz.choose",
    keys: ["A", "B", "C", "D", "1", "2", "3", "4"],
    labelKey: "shortcuts.quizChoose",
    scope: "page",
    showInHelp: false,
  },
  quizAnswer: {
    id: "quiz.answer",
    keys: ["Enter"],
    labelKey: "quiz.next",
    scope: "page",
    showInHelp: false,
  },
} satisfies Record<string, ShortcutDefinition>;

export const SHORTCUTS = definitions;

export type ShortcutName = keyof typeof SHORTCUTS;

/** Rows for the shortcut sheet, in declaration order. */
export const SHORTCUT_HELP: ShortcutDefinition[] = Object.values(SHORTCUTS).filter(
  (shortcut: ShortcutDefinition) => shortcut.showInHelp !== false,
);
