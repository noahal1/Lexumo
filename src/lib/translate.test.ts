import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { invoke } from "@tauri-apps/api/core";
import {
  LookupError,
  alternativeMeaning,
  clearLookupCache,
  createBrowserAdapters,
  createLookup,
  createLookupCache,
  createTauriAdapters,
  formatSenses,
  lookupCacheSize,
  normalizeTerm,
  parseGoogle,
  parseMyMemory,
  parseYoudao,
  parseYoudaoTranslation,
  posTags,
  primaryMeaning,
  resetProviderCooldown,
  type Lookup,
  type LookupAdapter,
  type LookupClock,
  type LookupContext,
  type LookupResult,
  type ProviderId,
} from "./translate";

// The desktop transport is a Tauri command, not `fetch`; mocking the bridge is
// what makes the shipping path testable in plain Node.
vi.mock("@tauri-apps/api/core", () => ({ invoke: vi.fn() }));

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

/* ------------------------------------------------------------- test helpers */

function makeResult(provider: ProviderId, meaning: string, term = "candid"): LookupResult {
  return {
    term,
    phonetic: "",
    senses: [{ pos: "", meaning }],
    examples: [],
    provider,
    fromCache: false,
  };
}

function fakeAdapter(
  id: ProviderId,
  run: (term: string, context: LookupContext) => Promise<LookupResult | null>,
  canServe: (from: string, to: string) => boolean = () => true,
): LookupAdapter {
  return { id, canServe, fetch: run };
}

/** A lookup whose cache and cooldown are fresh, memory-only and time-frozen. */
function makeLookup(adapters: LookupAdapter[], clock: LookupClock = { now: () => 0 }): Lookup {
  return createLookup({ adapters, cache: createLookupCache({ storage: null, clock }), clock });
}

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
    ]);
  });

  it("drops the proper-noun line a dictionary appends to common words", () => {
    // Youdao ends most entries with an E/C translation of the surname
    // ("【名】 （Candid）（罗）坎迪德（人名）"). It is not a sense of the word, and
    // it used to eat one of the three slots the secondary field has.
    const withName = parseYoudao(
      {
        ec: {
          word: [
            {
              trs: [
                {
                  tr: [
                    {
                      l: {
                        i: [
                          "n. 记录，记载；（某人或某物过去的）记录，经历",
                          "v. 记录；录制；（仪器）显示，标示",
                          "【名】 （Record）（美）勒科尔（人名）",
                        ],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
      "record",
    )!;
    expect(posTags(withName)).toEqual(["n.", "v."]);
    expect(alternativeMeaning(withName)).not.toContain("【名】");
    expect(alternativeMeaning(withName)).not.toContain("勒科尔");
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

  it("keeps the tag off the primary meaning", () => {
    // The tag now lives in `Word.pos`; spelling it into `definition` made the
    // list read "n. 类比，比拟" instead of "类比，比拟".
    expect(primaryMeaning(result)).toBe("坦率的，直言不讳的");
    expect(primaryMeaning(result)).not.toMatch(/^[a-z]+\./);
  });

  it("joins the remaining senses for the secondary field", () => {
    expect(alternativeMeaning(result)).toBe("抓拍的，偷拍的；公正的");
  });

  it("re-tags a secondary sense only when its part of speech changes", () => {
    const mixed = parseYoudao(
      {
        ec: {
          word: [
            {
              trs: [
                {
                  tr: [
                    {
                      l: {
                        i: [
                          "n. 类比，比拟",
                          "n. 类似的人（或物）",
                          "v. 与……类似",
                          "adj. 类似的",
                        ],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
      "analogy",
    )!;
    expect(alternativeMeaning(mixed)).toBe("类似的人（或物）；v. 与……类似；adj. 类似的");
  });

  it("keeps a different part of speech even when same-tag senses come first", () => {
    // `record` arrives noun, noun, noun, verb, adjective. Taking the first three
    // senses put three noun shades in the field and said nothing about the word
    // being a verb — the exact failure a browser probe caught and the unit tests
    // had blessed.
    const record = parseYoudao(
      {
        ec: {
          word: [
            {
              trs: [
                {
                  tr: [
                    {
                      l: {
                        i: [
                          "n. 记录，记载",
                          "n. （某人或某物过去的）记录，经历",
                          "n. 唱片；纪录",
                          "v. 记录；录制；（仪器）显示，标示",
                          "adj. 创纪录的",
                        ],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
      "record",
    )!;
    const secondary = alternativeMeaning(record);
    expect(secondary).toBe("v. 记录；录制；（仪器）显示，标示");
    expect(secondary).toMatch(/(^|；)v\.\s/);
  });

  it("fills leftover slots with same-tag senses after the odd one out", () => {
    const senses = ["n. 甲", "n. 乙", "adj. 丙", "n. 丁"];
    const result = {
      provider: "youdao" as const,
      term: "x",
      phonetic: "",
      senses: senses.map((line) => {
        const [pos, meaning] = line.split(" ");
        return { pos, meaning };
      }),
      examples: [],
      fromCache: false,
    };
    // The adjective is promoted ahead of the third noun, but everything still
    // comes out in dictionary order.
    expect(alternativeMeaning(result)).toBe("乙；adj. 丙；丁");
  });

  it("caps the secondary field at three senses", () => {
    // "run" has 45 senses in the dictionary; all of them in one input box is
    // not a glossary, it is a wall.
    const many = parseYoudao(
      {
        ec: {
          word: [
            {
              trs: [
                {
                  tr: [
                    {
                      l: {
                        i: [
                          "v. 跑；奔跑；运转",
                          "v. 二；三；四；五；六；七；八；九；十",
                        ],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
      "run",
    )!;
    expect(many.senses.length).toBeGreaterThan(3);
    expect(alternativeMeaning(many).split("；")).toHaveLength(3);
  });

  it("has no secondary text when there is only one sense", () => {
    const single = parseYoudao({ fanyi: { tran: "视为当然" } }, "take it for granted")!;
    expect(alternativeMeaning(single)).toBe("");
  });

  it("lists the parts of speech in the order the dictionary gives them", () => {
    const mixed = parseYoudao(
      {
        ec: {
          word: [
            {
              trs: [
                {
                  tr: [
                    {
                      l: {
                        i: ["n. 记录，记载", "n. 唱片", "v. 记录；录制", "adj. 创纪录的"],
                      },
                    },
                  ],
                },
              ],
            },
          ],
        },
      },
      "record",
    )!;
    expect(posTags(mixed)).toEqual(["n.", "v.", "adj."]);
    expect(posTags(result)).toEqual(["adj."]);
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

  // One instance per test: the cache and the cooldown used to be module
  // globals that `beforeEach` had to reset by hand.
  let lookup: Lookup;

  beforeEach(() => {
    lookup = makeLookup(createBrowserAdapters());
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it("uses the first provider that answers", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ errorCode: 0, translation: ["坦率的"] }));
    vi.stubGlobal("fetch", fetchMock);

    const result = await lookup.lookupTerm("candid");
    expect(result.senses[0].meaning).toBe("坦率的");
    expect(result.provider).toBe("youdao-web");
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  it("serves repeat lookups from the cache", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ errorCode: 0, translation: ["坦率的"] }));
    vi.stubGlobal("fetch", fetchMock);

    await lookup.lookupTerm("candid");
    const second = await lookup.lookupTerm("Candid  ");
    expect(second.fromCache).toBe(true);
    expect(fetchMock).toHaveBeenCalledTimes(1);
    expect(lookup.cacheSize()).toBe(1);
  });

  it("falls through to the next provider when one is rate limited", async () => {
    let call = 0;
    const fetchMock = vi.fn(async () => {
      call += 1;
      // youdao-web: 429, then mymemory: success
      return call === 1 ? jsonResponse({}, 429) : jsonResponse(myMemoryPayload);
    });
    vi.stubGlobal("fetch", fetchMock);

    const result = await lookup.lookupTerm("candid");
    expect(result.provider).toBe("mymemory");
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  it("reports rate limiting when every provider refuses", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({}, 429)),
    );
    await expect(lookup.lookupTerm("candid")).rejects.toBeInstanceOf(LookupError);
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "rate-limited" });
  });

  it("reports not-found when providers answer but have nothing", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn(async () => jsonResponse({ errorCode: 0, translation: [] })),
    );
    await expect(lookup.lookupTerm("zzzzqqq")).rejects.toMatchObject({ reason: "not-found" });
  });

  it("rejects an empty term without touching the network", async () => {
    const fetchMock = vi.fn();
    vi.stubGlobal("fetch", fetchMock);
    await expect(lookup.lookupTerm("   ")).rejects.toMatchObject({ reason: "not-found" });
    expect(fetchMock).not.toHaveBeenCalled();
  });

  it("force skips the cache", async () => {
    const fetchMock = vi.fn(async () => jsonResponse({ errorCode: 0, translation: ["坦率的"] }));
    vi.stubGlobal("fetch", fetchMock);

    await lookup.lookupTerm("candid");
    await lookup.lookupTerm("candid", { force: true });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });
});

describe("adapter chain", () => {
  it("follows the injected adapter order, not a hard-coded chain", async () => {
    const first = vi.fn(async () => makeResult("google", "第一"));
    const second = vi.fn(async () => makeResult("mymemory", "第二"));
    const lookup = makeLookup([fakeAdapter("google", first), fakeAdapter("mymemory", second)]);

    const found = await lookup.lookupTerm("candid");
    expect(found.provider).toBe("google");
    expect(first).toHaveBeenCalledTimes(1);
    expect(second).not.toHaveBeenCalled();
  });

  it("skips an adapter whose canServe is false", async () => {
    const skipped = vi.fn(async () => makeResult("google", "不该出现"));
    const served = vi.fn(async () => makeResult("mymemory", "坦率的"));
    const lookup = makeLookup([
      fakeAdapter("google", skipped, () => false),
      fakeAdapter("mymemory", served),
    ]);

    const found = await lookup.lookupTerm("candid", { from: "en", to: "zh-CN" });
    expect(found.provider).toBe("mymemory");
    expect(skipped).not.toHaveBeenCalled();
    expect(served).toHaveBeenCalledTimes(1);
  });

  it("passes the language pair through to canServe", async () => {
    const seen: [string, string][] = [];
    const lookup = makeLookup([
      fakeAdapter(
        "google",
        async () => makeResult("google", "x"),
        (from, to) => {
          seen.push([from, to]);
          return true;
        },
      ),
    ]);

    await lookup.lookupTerm("candid", { from: "ja", to: "ko" });
    expect(seen).toEqual([["ja", "ko"]]);
  });

  it("exercises the desktop adapter path with an injected adapter", async () => {
    // This is the path that ships, and it had no test while the chain was a
    // literal chosen by `isTauri()` inside the orchestrator.
    const tauriFetch = vi.fn(async () => makeResult("youdao", "坦率的"));
    const lookup = makeLookup([fakeAdapter("youdao", tauriFetch)]);

    const found = await lookup.lookupTerm("candid");
    expect(found.provider).toBe("youdao");
    expect(tauriFetch).toHaveBeenCalledWith(
      "candid",
      expect.objectContaining({ from: "en", to: "zh-CN" }),
    );
  });

  it("reports not-found when every adapter answers with nothing", async () => {
    const lookup = makeLookup([
      fakeAdapter("google", async () => null),
      fakeAdapter("mymemory", async () => null),
    ]);
    await expect(lookup.lookupTerm("zzzzqqq")).rejects.toMatchObject({ reason: "not-found" });
  });

  it("reports offline when every adapter fails without answering", async () => {
    const lookup = makeLookup([
      fakeAdapter("google", async () => {
        throw new LookupError("offline");
      }),
      fakeAdapter("mymemory", async () => {
        throw new Error("boom");
      }),
    ]);
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "offline" });
  });

  it("reports rate-limited when every adapter is cooling", async () => {
    const lookup = makeLookup([
      fakeAdapter("google", async () => {
        throw new LookupError("rate-limited");
      }),
    ]);
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "rate-limited" });
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "rate-limited" });
  });

  it("treats a chain where no adapter can serve as offline", async () => {
    const lookup = makeLookup([
      fakeAdapter("google", async () => makeResult("google", "x"), () => false),
    ]);
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "offline" });
  });
});

describe("tauri adapter (the shipping path)", () => {
  const invokeMock = vi.mocked(invoke);

  beforeEach(() => {
    invokeMock.mockReset();
  });

  it("calls lookup_word and parses the dictionary payload", async () => {
    invokeMock.mockResolvedValue({
      ok: true,
      status: 200,
      body: JSON.stringify(youdaoPayload),
      error: null,
    });

    const lookup = makeLookup(createTauriAdapters());
    const found = await lookup.lookupTerm("candid");

    expect(invokeMock).toHaveBeenCalledWith("lookup_word", { term: "candid" });
    expect(found.provider).toBe("youdao");
    expect(found.senses).toHaveLength(3);
    expect(found.phonetic).toBe("ˈkændɪd");
  });

  it("marks the provider cooling when the proxy reports 429", async () => {
    invokeMock.mockResolvedValue({ ok: false, status: 429, body: "", error: "rate limited" });

    const lookup = makeLookup(createTauriAdapters());
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "rate-limited" });

    // The cooldown is per instance and still inside the window: no second call.
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "rate-limited" });
    expect(invokeMock).toHaveBeenCalledTimes(1);
  });

  it("reports not-found when the proxy answers with an error body", async () => {
    invokeMock.mockResolvedValue({ ok: false, status: 500, body: "", error: "boom" });

    const lookup = makeLookup(createTauriAdapters());
    await expect(lookup.lookupTerm("candid")).rejects.toMatchObject({ reason: "not-found" });
  });
});

describe("cache and cooldown live in the instance", () => {
  it("skips an adapter during the cooldown window and retries after it", async () => {
    let now = 1_000;
    const clock: LookupClock = { now: () => now };
    // Typed so the mock can later be re-armed to return a result.
    const limited = vi.fn<(...args: [string, LookupContext]) => Promise<LookupResult | null>>(
      async () => {
        throw new LookupError("rate-limited");
      },
    );
    const fallback = vi.fn(async () => makeResult("mymemory", "坦率的"));
    const lookup = makeLookup(
      [fakeAdapter("youdao-web", limited), fakeAdapter("mymemory", fallback)],
      clock,
    );

    const first = await lookup.lookupTerm("candid");
    expect(first.provider).toBe("mymemory");
    expect(limited).toHaveBeenCalledTimes(1);

    // Still inside the 90 s window: the rate-limited adapter is skipped.
    now += 89_000;
    const second = await lookup.lookupTerm("candid", { force: true });
    expect(second.provider).toBe("mymemory");
    expect(limited).toHaveBeenCalledTimes(1);
    expect(fallback).toHaveBeenCalledTimes(2);

    // Past the window it is tried again and can win.
    now += 2_000;
    limited.mockImplementation(async () => makeResult("youdao-web", "坦诚的"));
    const third = await lookup.lookupTerm("candid", { force: true });
    expect(third.provider).toBe("youdao-web");
    expect(limited).toHaveBeenCalledTimes(2);
  });

  it("serves a cache hit without calling any adapter", async () => {
    const fetchSpy = vi.fn(async () => makeResult("google", "坦率的"));
    const lookup = makeLookup([fakeAdapter("google", fetchSpy)]);

    await lookup.lookupTerm("candid");
    const cached = await lookup.lookupTerm(" Candid ");
    expect(cached.fromCache).toBe(true);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
    expect(lookup.cacheSize()).toBe(1);
  });

  it("expires a cache entry after the TTL on the injected clock", async () => {
    let now = 0;
    const clock: LookupClock = { now: () => now };
    const fetchSpy = vi.fn(async () => makeResult("google", "坦率的"));
    const lookup = makeLookup([fakeAdapter("google", fetchSpy)], clock);

    await lookup.lookupTerm("candid");
    now += 1000 * 60 * 60 * 24 * 30 + 1;
    const again = await lookup.lookupTerm("candid");
    expect(again.fromCache).toBe(false);
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it("keeps cache and cooldown separate per instance", async () => {
    const fetchSpy = vi.fn(async () => makeResult("google", "坦率的"));
    const a = makeLookup([fakeAdapter("google", fetchSpy)]);
    const b = makeLookup([fakeAdapter("google", fetchSpy)]);

    await a.lookupTerm("candid");
    expect(a.cacheSize()).toBe(1);
    expect(b.cacheSize()).toBe(0);

    a.clearCache();
    expect(a.cacheSize()).toBe(0);
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });
});

describe("module-level compatibility exports", () => {
  it("still expose the settings-page cache helpers", () => {
    expect(typeof lookupCacheSize()).toBe("number");
    expect(() => clearLookupCache()).not.toThrow();
    expect(() => resetProviderCooldown()).not.toThrow();
  });
});
