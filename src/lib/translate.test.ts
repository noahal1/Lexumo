import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  LookupError,
  alternativeMeaning,
  clearLookupCache,
  formatSenses,
  lookupCacheSize,
  lookupTerm,
  normalizeTerm,
  parseGoogle,
  parseMyMemory,
  parseYoudao,
  parseYoudaoTranslation,
  primaryMeaning,
  resetProviderCooldown,
} from "./translate";

/** A trimmed-down but structurally faithful `dict.youdao.com/jsonapi` payload. */
const youdaoPayload = {
  ec: {
    word: [
      {
        usphone: "ˈkændɪd",
        ukphone: "ˈkændɪd",
        trs: [
          { tr: [{ l: { i: ["adj. 坦率的，直言不讳的；抓拍的，偷拍的；公正的"] } }] },
          { tr: [{ l: { i: ["【名】 （Candid）（罗）坎迪德（人名）"] } }] },
        ],
      },
    ],
  },
  blng_sents_part: {
    "sentence-pair": [
      { sentence: "She is very <b>candid</b>.", "sentence-translation": "她为人很坦诚。" },
      { sentence: "I gave them my candid opinion.", "sentence-translation": "我给了他们坦率的意见。" },
      { sentence: "Third one is dropped.", "sentence-translation": "第三条会被丢弃。" },
    ],
  },
};

const myMemoryPayload = {
  responseStatus: 200,
  responseData: { translatedText: "坦率的" },
  matches: [
    { translation: "坦率的", segment: "candid", match: 0.99 },
    { translation: "直言的", segment: "candid", match: 0.9 },
    // Different segment: should not be treated as a sense of this term.
    { translation: "公开坦率的", segment: "open and candid", match: 0.66 },
    { translation: "坦率的", segment: "candid", match: 0.5 },
  ],
};

const googlePayload = [[["坦率的", "candid", null, null]], null, "en"];

describe("parseYoudao", () => {
  it("splits part-of-speech senses and keeps the phonetic", () => {
    const result = parseYoudao(youdaoPayload, "candid");
    expect(result).not.toBeNull();
    expect(result!.phonetic).toBe("ˈkændɪd");
    expect(result!.provider).toBe("youdao");
    expect(result!.senses).toEqual([
      { pos: "adj.", meaning: "坦率的，直言不讳的" },
      { pos: "adj.", meaning: "抓拍的，偷拍的" },
      { pos: "adj.", meaning: "公正的" },
      { pos: "", meaning: "【名】 （Candid）（罗）坎迪德（人名）" },
    ]);
  });

  it("keeps at most two examples and strips markup", () => {
    const result = parseYoudao(youdaoPayload, "candid")!;
    expect(result.examples).toHaveLength(2);
    expect(result.examples[0]).toEqual({ en: "She is very candid.", zh: "她为人很坦诚。" });
    expect(result.examples[1].en).toBe("I gave them my candid opinion.");
  });

  it("falls back to machine translation when there is no dictionary entry", () => {
    const result = parseYoudao({ fanyi: { tran: "视为当然；把……当成理所当然" } }, "take it for granted");
    expect(result).not.toBeNull();
    expect(result!.senses).toEqual([{ pos: "", meaning: "视为当然；把……当成理所当然" }]);
    expect(result!.phonetic).toBe("");
  });

  it("returns null for an empty payload", () => {
    expect(parseYoudao({}, "nothing")).toBeNull();
    expect(parseYoudao(null, "nothing")).toBeNull();
    expect(parseYoudao("nope", "nothing")).toBeNull();
  });
});

describe("parseYoudaoTranslation", () => {
  it("maps translation lines to senses", () => {
    const result = parseYoudaoTranslation({ errorCode: "0", translation: ["坦诚的"] }, "candid");
    expect(result!.senses).toEqual([{ pos: "", meaning: "坦诚的" }]);
    expect(result!.provider).toBe("youdao-web");
  });

  it("accepts a numeric error code too", () => {
    const result = parseYoudaoTranslation({ errorCode: 0, translation: ["坦诚的"] }, "candid");
    expect(result!.senses).toEqual([{ pos: "", meaning: "坦诚的" }]);
  });

  it("rejects a rate-limited response", () => {
    // The live endpoint sends `"errorCode":"411"` as a string.
    expect(parseYoudaoTranslation({ errorCode: "411" }, "candid")).toBeNull();
    expect(parseYoudaoTranslation({ errorCode: 411 }, "candid")).toBeNull();
  });

  it("rejects a payload without an error code", () => {
    expect(parseYoudaoTranslation({ translation: ["x"] }, "x")).toBeNull();
  });
});

describe("parseMyMemory", () => {
  it("keeps alternatives that translate the term itself", () => {
    const result = parseMyMemory(myMemoryPayload, "candid")!;
    expect(result.senses.map((s) => s.meaning)).toEqual(["坦率的", "直言的"]);
    expect(result.provider).toBe("mymemory");
  });

  it("ignores low-confidence and unrelated segments", () => {
    const result = parseMyMemory(myMemoryPayload, "candid")!;
    expect(result.senses).toHaveLength(2);
  });

  it("returns null without a translated text", () => {
    expect(parseMyMemory({ responseData: {} }, "x")).toBeNull();
  });
});

describe("parseGoogle", () => {
  it("joins the chunked translation array", () => {
    const result = parseGoogle(googlePayload, "candid")!;
    expect(result.senses[0].meaning).toBe("坦率的");
    expect(result.provider).toBe("google");
  });

  it("returns null for unexpected shapes", () => {
    expect(parseGoogle({}, "x")).toBeNull();
    expect(parseGoogle([], "x")).toBeNull();
  });
});

describe("formatting helpers", () => {
  const result = parseYoudao(youdaoPayload, "candid")!;

  it("prefixes the first sense with its part of speech", () => {
    expect(primaryMeaning(result)).toBe("adj. 坦率的，直言不讳的");
  });

  it("joins the remaining senses for the secondary field", () => {
    expect(alternativeMeaning(result)).toBe("抓拍的，偷拍的；公正的；【名】 （Candid）（罗）坎迪德（人名）");
  });

  it("formats every sense on one line", () => {
    expect(formatSenses(result)).toContain("adj. 公正的");
  });

  it("collapses whitespace in terms", () => {
    expect(normalizeTerm("  take   it  easy ")).toBe("take it easy");
  });
});

describe("lookupTerm", () => {
  const jsonResponse = (body: unknown, status = 200) =>
    ({
      ok: status >= 200 && status < 300,
      status,
      json: async () => body,
    }) as unknown as Response;

  beforeEach(() => {
    clearLookupCache();
    resetProviderCooldown();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("uses the first provider that answers", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ errorCode: 0, translation: ["坦率的"] }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await lookupTerm("candid");
    expect(result.senses[0].meaning).toBe("坦率的");
    expect(result.provider).toBe("youdao-web");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("serves repeat lookups from the cache", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ errorCode: 0, translation: ["坦率的"] }));
    vi.stubGlobal("fetch", fetchMock);

    await lookupTerm("candid");
    const second = await lookupTerm("Candid  ");
    expect(second.fromCache).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(lookupCacheSize()).toBe(1);
  });

  it("falls through to the next provider when one is rate limited", async () => {
    let call = 0;
    const fetchMock = vi.fn(async () => {
      call += 1;
      // youdao-web: 429, then mymemory: success
      return call === 1 ? jsonResponse({}, 429) : jsonResponse(myMemoryPayload);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await lookupTerm("candid");
    expect(result.provider).toBe("mymemory");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("reports rate limiting when every provider refuses", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({}, 429)),
    );
    await expect(lookupTerm("candid")).rejects.toBeInstanceOf(LookupError);
    await expect(lookupTerm("candid")).rejects.toMatchObject({ reason: "rate-limited" });
  });

  it("reports not-found when providers answer but have nothing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ errorCode: 0, translation: [] })),
    );
    await expect(lookupTerm("zzzzqqq")).rejects.toMatchObject({ reason: "not-found" });
  });

  it("rejects an empty term without touching the network", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    await expect(lookupTerm("   ")).rejects.toMatchObject({ reason: "not-found" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("force skips the cache", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ errorCode: 0, translation: ["坦率的"] }));
    vi.stubGlobal("fetch", fetchMock);

    await lookupTerm("candid");
    await lookupTerm("candid", { force: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});
