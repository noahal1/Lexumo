/** Minimal i18n: dot-path lookup, {var} interpolation, React hook. */
import { createContext, useContext, useMemo, type ReactNode } from "react";
import { useSettings } from "@/lib/store";
import type { UiLang } from "@/lib/types";
import { zhCN } from "./locales/zh-CN";
import { en } from "./locales/en";

const DICTS: Record<UiLang, unknown> = { "zh-CN": zhCN, en };

export type TFunc = (key: string, vars?: Record<string, string | number>) => string;

function lookup(dict: unknown, path: string): unknown {
  let node: unknown = dict;
  for (const part of path.split(".")) {
    if (node && typeof node === "object" && part in (node as Record<string, unknown>)) {
      node = (node as Record<string, unknown>)[part];
    } else {
      return undefined;
    }
  }
  return node;
}

export function translate(
  lang: UiLang,
  key: string,
  vars?: Record<string, string | number>,
): string {
  const raw = lookup(DICTS[lang], key) ?? lookup(DICTS["zh-CN"], key);
  if (typeof raw !== "string") return key;
  if (!vars) return raw;
  return raw.replace(/\{(\w+)\}/g, (_, name: string) =>
    name in vars ? String(vars[name]) : `{${name}}`,
  );
}

const LangContext = createContext<UiLang>("zh-CN");

export function I18nProvider({ children }: { children: ReactNode }) {
  const { uiLang } = useSettings();
  const value = useMemo(() => (uiLang === "en" ? "en" : "zh-CN") as UiLang, [uiLang]);
  return <LangContext.Provider value={value}>{children}</LangContext.Provider>;
}

export function useLang(): UiLang {
  return useContext(LangContext);
}

/** The translation function for the active UI language. */
export function useT(): TFunc {
  const lang = useLang();
  return useMemo<TFunc>(
    () => (key: string, vars?: Record<string, string | number>) => translate(lang, key, vars),
    [lang],
  );
}
