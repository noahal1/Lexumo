import { describe, expect, it } from "vitest";

import {
  createSession,
  formatAccuracy,
  gradeCountsAsCorrect,
  type Session,
} from "./session";

const IDS = ["a", "b", "c"];

/** Answer once and hand back the resulting progress for before/after checks. */
function answer(session: Session, correct: boolean) {
  session.record({ correct });
  return session.progress();
}

describe("createSession", () => {
  it("空卡组没有当前卡，进度归零且直接算完成", () => {
    const session = createSession({ ids: [] });

    expect(session.current()).toBeNull();
    expect(session.progress()).toEqual({
      index: 0,
      total: 0,
      reviewed: 0,
      correct: 0,
      skipped: 0,
      accuracy: 0,
      done: true,
    });
    expect(session.canUndo()).toBe(false);
    expect(session.undo()).toBeNull();
  });

  it("新会话停在第一张卡，正确率是 0 而不是 NaN", () => {
    const session = createSession({ ids: IDS });

    expect(session.current()).toBe("a");
    expect(session.progress()).toEqual({
      index: 0,
      total: 3,
      reviewed: 0,
      correct: 0,
      skipped: 0,
      accuracy: 0,
      done: false,
    });
  });

  it("record 推进卡片并累计复习张数与正确数", () => {
    const session = createSession({ ids: IDS });

    expect(answer(session, true)).toMatchObject({
      index: 1,
      reviewed: 1,
      correct: 1,
      done: false,
    });
    expect(session.current()).toBe("b");

    const afterWrong = answer(session, false);
    expect(afterWrong).toMatchObject({ index: 2, reviewed: 2, correct: 1 });
    expect(afterWrong.accuracy).toBeCloseTo(0.5);

    const afterLast = answer(session, true);
    expect(afterLast).toMatchObject({
      index: 3,
      reviewed: 3,
      correct: 2,
      done: true,
    });
    expect(afterLast.accuracy).toBeCloseTo(2 / 3);
    expect(session.current()).toBeNull();
  });

  it("skip 只计入 skipped，不算复习，也不影响正确率", () => {
    const session = createSession({ ids: IDS });

    session.skip();
    expect(session.progress()).toMatchObject({
      index: 1,
      reviewed: 0,
      skipped: 1,
      accuracy: 0,
      done: false,
    });
    expect(session.current()).toBe("b");

    session.skip();
    session.skip();
    expect(session.progress()).toMatchObject({
      index: 3,
      reviewed: 0,
      skipped: 3,
      accuracy: 0,
      done: true,
    });
    expect(session.current()).toBeNull();
  });

  it("完成后 record / skip 不再改变进度", () => {
    const session = createSession({ ids: ["a"] });
    answer(session, true);
    const finished = session.progress();

    session.record({ correct: false });
    session.skip();

    expect(session.progress()).toEqual(finished);
    expect(session.current()).toBeNull();
  });
});

describe("gradeCountsAsCorrect", () => {
  it.each([
    ["hard", false],
    ["good", true],
    ["easy", true],
  ] as const)("%s → %s", (grade, expected) => {
    expect(gradeCountsAsCorrect(grade)).toBe(expected);
  });

  it("只答困难时复习张数增加，但正确数不增加", () => {
    const session = createSession({ ids: ["a"] });

    session.record({ correct: gradeCountsAsCorrect("hard") });

    expect(session.progress()).toMatchObject({
      reviewed: 1,
      correct: 0,
      accuracy: 0,
    });
  });
});

describe("undo", () => {
  it("撤销一次答对，精确回到作答前的进度与卡片", () => {
    const session = createSession({ ids: IDS });
    const before = session.progress();

    session.record({ correct: true });
    const step = session.undo();

    expect(step).toEqual({ kind: "record", id: "a", correct: true });
    expect(session.progress()).toEqual(before);
    expect(session.current()).toBe("a");
    expect(session.canUndo()).toBe(false);
  });

  it("撤销一次答错，精确回到作答前的进度", () => {
    const session = createSession({ ids: IDS });
    answer(session, true);
    const before = session.progress();

    session.record({ correct: false });
    session.undo();

    expect(session.progress()).toEqual(before);
    expect(session.current()).toBe("b");
  });

  it("撤销 skip 精确还原 skipped 与卡片位置", () => {
    const session = createSession({ ids: IDS });
    const before = session.progress();

    session.skip();
    const step = session.undo();

    expect(step).toEqual({ kind: "skip", id: "a" });
    expect(session.progress()).toEqual(before);
    expect(session.current()).toBe("a");
  });

  it("连续撤销按后进先出回到每一个中间状态", () => {
    const session = createSession({ ids: IDS });
    const states = [session.progress()];

    states.push(answer(session, true));
    session.skip();
    states.push(session.progress());

    expect(session.undo()).toEqual({ kind: "skip", id: "b" });
    expect(session.progress()).toEqual(states[1]);

    expect(session.undo()).toEqual({ kind: "record", id: "a", correct: true });
    expect(session.progress()).toEqual(states[0]);

    expect(session.undo()).toBeNull();
  });

  it("撤销在完成后也能回到未完成状态", () => {
    const session = createSession({ ids: ["a"] });
    answer(session, true);
    expect(session.progress().done).toBe(true);

    session.undo();

    expect(session.progress()).toMatchObject({ index: 0, done: false });
    expect(session.current()).toBe("a");
  });
});

describe("reset", () => {
  it("reset 回到第一张卡并清空历史", () => {
    const session = createSession({ ids: IDS });
    answer(session, true);
    session.skip();

    session.reset();

    expect(session.progress()).toEqual({
      index: 0,
      total: 3,
      reviewed: 0,
      correct: 0,
      skipped: 0,
      accuracy: 0,
      done: false,
    });
    expect(session.current()).toBe("a");
    expect(session.canUndo()).toBe(false);
  });
});

describe("formatAccuracy", () => {
  it.each([
    [0, "0%"],
    [0.5, "50%"],
    [1, "100%"],
    [2 / 3, "67%"],
  ] as const)("%s → %s", (accuracy, expected) => {
    expect(formatAccuracy(accuracy)).toBe(expected);
  });
});
