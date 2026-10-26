import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import {
  clamp,
  cx,
  dayKey,
  daysBetween,
  normalizeTerm,
  relativeDay,
  shuffle,
  startOfDay,
  uid,
} from "./utils";

const DAY = 86_400_000;

/** Local-time timestamp helper (month is 1-based for readability). */
function at(year: number, month: number, day: number, hour = 12): number {
  return new Date(year, month - 1, day, hour).getTime();
}

afterEach(() => {
  vi.restoreAllMocks();
});

describe("normalizeTerm", () => {
  it("去除首尾空白并转小写", () => {
    expect(normalizeTerm("  Hello  ")).toBe("hello");
    expect(normalizeTerm("Café")).toBe("café");
    expect(normalizeTerm("ÄBC")).toBe("äbc");
  });

  it("空字符串与纯空白返回空串", () => {
    expect(normalizeTerm("")).toBe("");
    expect(normalizeTerm("   ")).toBe("");
  });
});

describe("clamp", () => {
  it("区间内原样返回", () => {
    expect(clamp(5, 0, 10)).toBe(5);
    expect(clamp(0, 0, 10)).toBe(0);
    expect(clamp(10, 0, 10)).toBe(10);
  });

  it("低于下限取下限，高于上限取上限", () => {
    expect(clamp(-1, 0, 10)).toBe(0);
    expect(clamp(11, 0, 10)).toBe(10);
    expect(clamp(-0.5, -1, 1)).toBe(-0.5);
  });
});

describe("shuffle", () => {
  it("返回新数组，长度与元素集合不变，且不修改原数组", () => {
    const input = [1, 2, 3, 4, 5];
    const out = shuffle(input);
    expect(out).not.toBe(input);
    expect(out).toHaveLength(input.length);
    expect([...out].sort((a, b) => a - b)).toEqual([...input].sort((a, b) => a - b));
    expect(input).toEqual([1, 2, 3, 4, 5]);
  });

  it("空数组返回空数组", () => {
    expect(shuffle([])).toEqual([]);
  });

  it("固定随机数时产生确定的排列", () => {
    const spy = vi.spyOn(Math, "random").mockReturnValue(0);
    // i=3,2,1 时 j 均为 0：[1,2,3,4] → [2,3,4,1]
    expect(shuffle([1, 2, 3, 4])).toEqual([2, 3, 4, 1]);

    spy.mockReturnValue(0.9999);
    // j 始终等于 i，排列保持不变
    expect(shuffle([1, 2, 3, 4])).toEqual([1, 2, 3, 4]);
  });
});

describe("daysBetween / startOfDay", () => {
  it("同一天内不同时刻相差 0 天", () => {
    expect(daysBetween(at(2024, 3, 5, 1), at(2024, 3, 5, 23))).toBe(0);
  });

  it("相邻日期相差 ±1 天", () => {
    expect(daysBetween(at(2024, 3, 5), at(2024, 3, 6))).toBe(1);
    expect(daysBetween(at(2024, 3, 6), at(2024, 3, 5))).toBe(-1);
  });

  it("跨月、跨年、闰日都按自然日计算", () => {
    expect(daysBetween(at(2024, 1, 31), at(2024, 2, 1))).toBe(1);
    expect(daysBetween(at(2023, 12, 31), at(2024, 1, 1))).toBe(1);
    expect(daysBetween(at(2024, 2, 28), at(2024, 2, 29))).toBe(1);
    expect(daysBetween(at(2024, 3, 5), at(2024, 3, 15))).toBe(10);
  });

  it("startOfDay 归零到当天 00:00:00.000", () => {
    const t = startOfDay(at(2024, 3, 5, 23));
    const d = new Date(t);
    expect([d.getHours(), d.getMinutes(), d.getSeconds(), d.getMilliseconds()]).toEqual([
      0, 0, 0, 0,
    ]);
    expect(t).toBe(at(2024, 3, 5, 0));
  });
});

describe("dayKey", () => {
  it("输出 YYYY-MM-DD 并补零", () => {
    expect(dayKey(at(2024, 3, 5))).toBe("2024-03-05");
    expect(dayKey(at(2024, 3, 9))).toBe("2024-03-09");
    expect(dayKey(at(2024, 1, 1))).toBe("2024-01-01");
    expect(dayKey(at(2024, 12, 31))).toBe("2024-12-31");
  });
});

describe("cx", () => {
  it("过滤假值后用空格拼接", () => {
    expect(cx("a", false, null, undefined, "b", "")).toBe("a b");
  });

  it("没有有效类名时返回空串", () => {
    expect(cx()).toBe("");
    expect(cx(false, null, undefined, "")).toBe("");
  });

  it("单个类名原样返回", () => {
    expect(cx("only")).toBe("only");
  });
});

describe("uid", () => {
  it("默认生成 12 位唯一 id", () => {
    const ids = new Set(Array.from({ length: 1000 }, () => uid()));
    expect(ids.size).toBe(1000);
    for (const id of ids) expect(id).toMatch(/^[0-9a-z]{12}$/);
  });

  it("带前缀时以 前缀_ 开头", () => {
    expect(uid("w")).toMatch(/^w_[0-9a-z]{12}$/);
    expect(uid("list")).toMatch(/^list_[0-9a-z]{12}$/);
  });

  it("带前缀的 id 同样唯一", () => {
    const ids = new Set(Array.from({ length: 500 }, () => uid("r")));
    expect(ids.size).toBe(500);
  });
});

describe("relativeDay", () => {
  beforeEach(() => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date(2024, 5, 10, 12, 0, 0));
  });

  afterEach(() => {
    vi.useRealTimers();
  });

  it("中文文案", () => {
    const now = Date.now();
    expect(relativeDay(now, "zh-CN")).toBe("今天");
    expect(relativeDay(now + DAY, "zh-CN")).toBe("明天");
    expect(relativeDay(now - DAY, "zh-CN")).toBe("昨天");
    expect(relativeDay(now + 5 * DAY, "zh-CN")).toBe("5 天后");
    expect(relativeDay(now - 5 * DAY, "zh-CN")).toBe("5 天前");
  });

  it("英文文案", () => {
    const now = Date.now();
    expect(relativeDay(now, "en")).toBe("today");
    expect(relativeDay(now + DAY, "en")).toBe("tomorrow");
    expect(relativeDay(now - DAY, "en")).toBe("yesterday");
    expect(relativeDay(now + 5 * DAY, "en")).toBe("in 5 days");
    expect(relativeDay(now - 5 * DAY, "en")).toBe("5 days ago");
  });
});
