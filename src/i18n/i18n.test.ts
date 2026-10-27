/**
 * The dictionary is the app's entire vocabulary. These tests guard the two
 * properties the type system cannot: that every declared key actually resolves
 * to a non-empty string at runtime, and that interpolation really substitutes.
 */
import { describe, expect, it } from "vitest";
import { translate } from "./index";
import { zhCN, type MessageKey } from "./locales/zh-CN";
import { en } from "./locales/en";

/** Walk a nested dictionary and return every dot-path whose leaf is a string. */
function flatten(node: unknown, prefix = ""): string[] {
  if (typeof node === "string") return [prefix];
  if (!node || typeof node !== "object") return [];
  return Object.entries(node as Record<string, unknown>).flatMap(([key, value]) =>
    flatten(value, prefix ? `${prefix}.${key}` : key),
  );
}

const zhKeys = flatten(zhCN);
const enKeys = flatten(en);

describe("dictionary", () => {
  it("has a meaningful number of keys", () => {
    expect(zhKeys.length).toBeGreaterThan(250);
  });

  it("declares the same paths in both languages", () => {
    const zhOnly = zhKeys.filter((k) => !enKeys.includes(k));
    const enOnly = enKeys.filter((k) => !zhKeys.includes(k));
    expect(zhOnly).toEqual([]);
    expect(enOnly).toEqual([]);
  });

  it("has no empty strings in either language", () => {
    const blank = zhKeys.filter((k) => {
      const key = k as MessageKey;
      return translate("zh-CN", key).trim() === "" || translate("en", key).trim() === "";
    });
    expect(blank).toEqual([]);
  });

  it("resolves every key in both languages, never echoing the key back", () => {
    const broken = zhKeys.filter((k) => {
      const key = k as MessageKey;
      return translate("zh-CN", key) === k || translate("en", key) === k;
    });
    expect(broken).toEqual([]);
  });

  it("interpolates named placeholders", () => {
    expect(translate("zh-CN", "stats.reviewWithCount", { n: 7 })).toContain("7");
    expect(translate("en", "stats.reviewWithCount", { n: 7 })).toContain("7");
    expect(translate("en", "settings.dataNote", { words: 12, logs: 40 })).toBe(
      "12 words, 40 records",
    );
  });

  it("leaves an unknown placeholder visible instead of printing undefined", () => {
    expect(translate("en", "stats.reviewWithCount", {})).toContain("{n}");
  });
});
