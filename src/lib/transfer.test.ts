/**
 * Transfer tests: the three file formats the app reads and writes.
 *
 * These existed as an untested module until the bilingual example landed — the
 * CSV column list and the import parsers are a user-visible contract (people
 * edit these files in Excel), so a wrong column name or a dropped field is a
 * data-loss bug, not a cosmetic one.
 */
import { describe, expect, it } from "vitest";
import { exportCsv, exportJson, parseImport } from "./transfer";
import type { AppData, Word, WordList } from "./types";
import { DEFAULT_SETTINGS } from "./types";

const LIST_ID = "list_default";

function makeWord(overrides: Partial<Word> = {}): Word {
  return {
    id: "w1",
    term: "serendipity",
    phonetic: "",
    definition: "意外发现美好事物的能力",
    definition2: "",
    example: "a serendipitous meeting",
    note: "",
    status: "reviewing",
    favorite: false,
    listId: LIST_ID,
    sourceLang: "en",
    targetLang: "zh-CN",
    listenCount: 0,
    srs: {
      ease: 2.5,
      intervalDays: 7,
      dueAt: 0,
      reviewCount: 1,
      correctCount: 1,
      lastReviewedAt: 0,
    },
    createdAt: 0,
    updatedAt: 0,
    ...overrides,
  };
}

function makeData(words: Word[]): AppData {
  const list: WordList = {
    id: LIST_ID,
    name: "默认词库",
    sourceLang: "en",
    targetLang: "zh-CN",
    createdAt: 0,
    updatedAt: 0,
  };
  return {
    version: 2,
    lists: [list],
    words,
    logs: [],
    settings: DEFAULT_SETTINGS,
    settingsUpdatedAt: 0,
    tombstones: { words: {}, lists: {}, logs: {} },
    pending: { words: [], lists: [], logs: [], settings: false },
  };
}

describe("CSV export", () => {
  it("writes the documented header in the documented order", () => {
    const csv = exportCsv([makeWord()]);
    const header = csv.replace(/^\uFEFF/, "").split(/\r\n/)[0];
    expect(header).toBe(
      "term,pos,definition,definition2,example,exampleTranslation,note,status",
    );
  });

  it("writes the part of speech in its own column", () => {
    const csv = exportCsv([makeWord({ pos: "n." })]);
    expect(csv).toContain("serendipity,n.,意外发现美好事物的能力,");
  });

  it("puts the example translation in its own column", () => {
    const csv = exportCsv([makeWord({ exampleZh: "一次机缘巧合的相遇" })]);
    expect(csv).toContain("a serendipitous meeting,一次机缘巧合的相遇,");
  });

  it("has no tags column: the removed field never reaches the file", () => {
    const csv = exportCsv([makeWord()]);
    expect(csv).not.toContain("抽象");
    const header = csv.replace(/^\uFEFF/, "").split(/\r\n/)[0];
    expect(header).not.toContain("tag");
  });

  it("quotes commas, quotes and newlines per RFC 4180", () => {
    const csv = exportCsv([
      makeWord({ definition: 'a, b', example: 'he said "hi"', note: "line1\nline2" }),
    ]);
    expect(csv).toContain('"a, b"');
    expect(csv).toContain('"he said ""hi"""');
    expect(csv).toContain('"line1\nline2"');
  });
});

describe("CSV import", () => {
  it("round-trips through export, keeping the example pair", () => {
    const word = makeWord({ exampleZh: "一次机缘巧合的相遇" });
    const csv = exportCsv([word]);
    const result = parseImport(csv, LIST_ID);

    expect(result.format).toBe("csv");
    expect(result.skipped).toBe(0);
    expect(result.words).toHaveLength(1);
    expect(result.words[0]).toMatchObject({
      term: "serendipity",
      definition: "意外发现美好事物的能力",
      example: "a serendipitous meeting",
      exampleZh: "一次机缘巧合的相遇",
      status: "reviewing",
      listId: LIST_ID,
    });
  });

  it("keeps the part of speech across an export and import", () => {
    const word = makeWord({ pos: "n." });
    const result = parseImport(exportCsv([word]), LIST_ID);
    expect(result.words[0]?.pos).toBe("n.");
    expect(result.words[0]?.definition).toBe("意外发现美好事物的能力");
  });

  it("accepts the part of speech under any of its aliases", () => {
    for (const header of ["pos", "part of speech", "partOfSpeech", "词性"]) {
      const text = `term,${header},definition\nword one,adj.,一个词义\n`;
      const result = parseImport(text, LIST_ID);
      expect(result.words[0]?.pos, header).toBe("adj.");
    }
  });

  it("accepts the example translation under any of its aliases", () => {
    for (const header of ["example_zh", "exampleZh", "例句翻译", "例句译文"]) {
      const text = `term,example,${header}\nword one,a sentence,一句话\n`;
      const result = parseImport(text, LIST_ID);
      expect(result.words[0]?.exampleZh, header).toBe("一句话");
    }
  });

  it("leaves the translation undefined when the column is absent", () => {
    const result = parseImport("term,definition\nhello,你好\n", LIST_ID);
    expect(result.words[0]?.exampleZh).toBeUndefined();
  });

  it("treats an empty translation cell as absent, not as an empty string", () => {
    const result = parseImport("term,example,exampleTranslation\nhello,hi,\n", LIST_ID);
    expect(result.words[0]?.exampleZh).toBeUndefined();
  });

  it("skips rows with no term and counts them", () => {
    const result = parseImport("term,definition\n,orphan\nhello,你好\n", LIST_ID);
    expect(result.words).toHaveLength(1);
    expect(result.skipped).toBe(1);
  });

  it("accepts a BOM and CRLF from Excel", () => {
    const result = parseImport("\uFEFFterm,definition\r\nhello,你好\r\n", LIST_ID);
    expect(result.words[0]?.term).toBe("hello");
  });

  it("ignores an unknown status instead of guessing one", () => {
    const result = parseImport("term,status\nhello,weird\n", LIST_ID);
    expect(result.words[0]?.status).toBeUndefined();
  });
});

describe("JSON import", () => {
  it("keeps the example pair from a full snapshot", () => {
    const word = makeWord({ exampleZh: "一次机缘巧合的相遇" });
    const result = parseImport(exportJson(makeData([word])), LIST_ID);
    expect(result.format).toBe("json");
    expect(result.words[0]?.exampleZh).toBe("一次机缘巧合的相遇");
  });

  it("accepts a bare array of words", () => {
    const result = parseImport(JSON.stringify([{ term: "solo", exampleZh: "单独" }]), LIST_ID);
    expect(result.words[0]).toMatchObject({ term: "solo", exampleZh: "单独" });
  });

  it("restores only words — settings and logs in the file are ignored", () => {
    const data = makeData([makeWord()]);
    const result = parseImport(exportJson(data), LIST_ID);
    expect(result.words).toHaveLength(1);
    expect(Object.keys(result)).toEqual(["words", "skipped", "format"]);
  });
});

describe("Anki import", () => {
  it("joins the non-first columns into the definition and strips HTML", () => {
    const result = parseImport("candid\t<b>坦率</b>\tan opinion\n", LIST_ID);
    expect(result.format).toBe("anki");
    expect(result.words[0]).toMatchObject({
      term: "candid",
      definition: "坦率 an opinion",
      example: "",
    });
  });

  it("prefers tabs over commas, so a comma inside a definition survives", () => {
    const result = parseImport("candid\ta, b, c\n", LIST_ID);
    expect(result.format).toBe("anki");
    expect(result.words[0]?.definition).toBe("a, b, c");
  });
});

describe("unknown input", () => {
  it("reports nothing to import rather than throwing", () => {
    const result = parseImport("just some prose with no separators", LIST_ID);
    expect(result.format).toBe("unknown");
    expect(result.words).toEqual([]);
  });
});
