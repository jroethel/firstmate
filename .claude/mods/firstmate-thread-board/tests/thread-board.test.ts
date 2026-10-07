// The thread board under `claude plugin test`: the thread store's operations, the bar's
// layout math, and the engine glue that keeps threads and draws the bar and its slot.
import { describe, expect, test } from "claude-code/testing";
import { mock } from "claude-code/testing";
import {
  applyThread,
  EMPTY_BOARD,
  fit,
  formatLastResponse,
  layoutBar,
  nextMarker,
  textWidth,
  SLOT_COLUMNS,
  SLOT_GAP,
  THREAD_MARKERS,
  type Board,
} from "../lib/fm-thread-board.ts";

const add = (board: Board, name: string, brief = "", marker?: string) =>
  applyThread(board, { action: "add", name, brief, marker });

describe("the thread store", () => {
  test("hands out markers in order of first appearance, then numbers, and never red", () => {
    let board = EMPTY_BOARD;
    for (let index = 0; index < 10; index += 1) board = add(board, `t${index}`).board;
    expect(board.threads.map((thread) => thread.marker)).toEqual([...THREAD_MARKERS, "9", "10"]);
    expect((THREAD_MARKERS as readonly string[]).includes("🔴")).toBe(false);
  });

  test("refuses a red marker, a duplicate marker, and a nameless thread, leaving the board as it was", () => {
    const board = add(EMPTY_BOARD, "calm").board;
    for (const refused of [add(board, "x", "", "🔴"), add(board, "x", "", "🟠"), add(board, "  ")]) {
      expect(refused.isError).toBe(true);
      expect(refused.board).toBe(board);
    }
  });

  test("updates a thread by marker or name and closes it without freeing its marker", () => {
    let board = add(EMPTY_BOARD, "calm", "drafting").board;
    board = applyThread(board, { action: "update", name: "CALM", brief: "in review" }).board;
    expect(board.threads[0]).toMatchObject({ marker: "🟠", name: "calm", brief: "in review", open: true });
    board = applyThread(board, { action: "update", marker: "🟠", name: "calm mod", brief: "merged" }).board;
    expect(board.threads[0]).toMatchObject({ name: "calm mod", brief: "merged" });
    const closed = applyThread(board, { action: "close", marker: "🟠" });
    expect(closed.board.threads[0]!.open).toBe(false);
    expect(closed.text).toContain("No open threads.");
    // The closed thread's marker is spent: the next thread takes the next color.
    expect(nextMarker(closed.board.threads)).toBe("🟡");
    expect(applyThread(closed.board, { action: "close", name: "nothing" }).isError).toBe(true);
  });

  test("keeps a brief to a few words", () => {
    const board = add(EMPTY_BOARD, "calm", "word ".repeat(40)).board;
    expect(Array.from(board.threads[0]!.brief).length).toBeLessThanOrEqual(60);
  });
});

describe("the bar's layout", () => {
  const some = (count: number, brief = "something is going on"): Board => {
    let board = EMPTY_BOARD;
    for (let index = 0; index < count; index += 1) board = add(board, `thread${index}`, brief).board;
    return board;
  };

  test("measures emoji markers as two cells and cuts text to a cell budget", () => {
    expect(textWidth("🟠 ab")).toBe(5);
    expect(textWidth("⚪ab")).toBe(4);
    expect(fit("abcdefghij", 6)).toBe("abcde…");
    expect(textWidth(fit("🟠🟠🟠🟠", 5))).toBeLessThanOrEqual(5);
    expect(fit("short", 10)).toBe("short");
  });

  test("stamps the last response in local time, and a dash before the first", () => {
    expect(formatLastResponse(null)).toBe("-");
    expect(formatLastResponse(new Date(2026, 9, 6, 23, 42, 9).getTime())).toBe("10-06 23:42");
  });

  test("reserves the slot at the far right and never lets the left text into it", () => {
    for (const columns of [60, 80, 120, 200]) {
      const layout = layoutBar(some(8), columns);
      expect(layout.slotColumns).toBe(SLOT_COLUMNS);
      expect(layout.leftColumns + SLOT_GAP + layout.slotColumns).toBe(columns);
      expect(textWidth(layout.stamp) + 2 + textWidth(layout.rows[0])).toBeLessThanOrEqual(layout.leftColumns);
      expect(textWidth(layout.rows[1])).toBeLessThanOrEqual(layout.leftColumns);
    }
  });

  test("flows chips across both rows and folds what does not fit into a +N that keeps the count", () => {
    const board = some(8);
    const layout = layoutBar(board, 100);
    const text = `${layout.rows[0]}\n${layout.rows[1]}`;
    const shown = THREAD_MARKERS.filter((marker) => text.includes(marker)).length;
    const folded = Number(/ \+(\d+)$/.exec(layout.rows[1])?.[1] ?? 0);
    expect(shown).toBeGreaterThan(0);
    expect(shown + folded).toBe(8);
    // Wide enough for everything: no fold at all.
    const roomy = layoutBar(some(3, ""), 200);
    expect(roomy.rows[1]).not.toContain("+");
    expect(roomy.rows[0]).toContain("🟠 thread0");
  });

  test("moves a chip that cannot fit even by name to row two rather than cutting it short on row one", () => {
    const layout = layoutBar(some(3, "a fairly long brief here"), 90);
    expect(layout.rows[0]).toBe("🟠 thread0 - a fairly long brief here");
    expect(layout.rows[1]).toContain("🟡 thread1");
  });

  test("settles for a name alone only where no row has room for the brief", () => {
    // Narrow: row one has room for the first chip's name only, so it keeps just that; row two has room for a whole one.
    expect(layoutBar(some(2, "a fairly long brief here"), 80).rows).toEqual(["🟠 thread0", "🟡 thread1 - a fairly long brief here"]);
    // Wider: the first chip is whole on row one, and the second, which would fit only by name there, takes row two whole.
    expect(layoutBar(some(2, "a fairly long brief here"), 100).rows).toEqual([
      "🟠 thread0 - a fairly long brief here",
      "🟡 thread1 - a fairly long brief here",
    ]);
  });

  test("shows only open threads and survives a terminal narrower than the slot", () => {
    const closed = applyThread(some(2), { action: "close", marker: "🟠" }).board;
    expect(`${layoutBar(closed, 120).rows.join("")}`).not.toContain("thread0");
    const narrow = layoutBar(some(2), 20);
    expect(narrow.leftColumns).toBe(0);
    // ponytail: under about 40 columns the left text has no room at all; hiding the slot there if it ever matters.
    expect(narrow.rows).toEqual(["", ""]);
  });
});

const BAR = {
  surface: "terminal" as const,
  component: "AbovePrompt" as const,
  requestId: "band",
  viewport: { columns: 100, rows: 30 },
  props: { hasSurvey: false, isWorking: false, maxRows: 6, bodyColumns: 100, scroll: { bodyRows: 5 } },
};

// 30 by 2 blank cells, packed as Raster's `cells` are: little-endian u32 [glyph, foreground, background] triplets.
const BLANK_CELLS = btoa(
  String.fromCharCode(...new Uint8Array(new Uint32Array(Array.from({ length: 60 }, () => [0x20, 0x01000000, 0x01000000]).flat()).buffer)),
);

const text = (tree: unknown): string => JSON.stringify(tree);

describe("the engine glue", () => {
  // The host's `$.state`, in memory: one map of values by `plugin.key`, so a test can seed the
  // value another plugin owns (Calm's frame) exactly as the host would hold it.
  const values = new Map<string, unknown>();

  async function started($: Parameters<Parameters<typeof test>[1]>[0], on: Parameters<Parameters<typeof test>[1]>[1], hooks = "1") {
    mock.env(on, { CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: hooks });
    mock.store(on);
    mock.clock(on);
    values.clear();
    on("state.get", async (_$, e) => ({ value: { value: values.get(`${e.plugin}.${e.key}`) as never, version: 1 } }));
    on("state.set", async (_$, e) => {
      values.set(`${e.plugin}.${e.key}`, e.value);
      return { value: { isSet: true as const, version: 1 } };
    });
    on("turn.complete", async () => ({ text: "" }));
    on("session.end", async () => ({}));
    on("session.id", async () => ({ value: "session-1" }));
    on("session.start", async (_$, e) => ({ cwd: e.cwd }));
    on("tool.register", async (_$, e) => ({ value: { tool: `mcp__fm-threads__${e.name}` } }));
    on("ui.render", async () => ({ type: "Text", props: {}, children: ["STOCK"] }));
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
  }

  test("keeps threads through the tool and draws them in the bar with the empty slot", async ($, on) => {
    await started($, on);
    const call = (input: Record<string, string>) =>
      $.tool.call({ tool: "mcp__fm-threads__thread", ...input } as never);
    await call({ action: "add", name: "calm", brief: "slot wiring" });
    await call({ action: "add", name: "bar", brief: "drawing it" });
    const drawn = text(await $.ui.render(BAR));
    expect(drawn).toContain("🟠 calm - slot wiring");
    expect(drawn).toContain("🟡 bar - drawing it");
    expect(drawn).toContain("last reply -");
    expect(drawn).not.toContain("Raster");
    await call({ action: "close", name: "calm" });
    expect(text(await $.ui.render(BAR))).not.toContain("slot wiring");
  });

  test("draws Calm's published frame in the slot only while a turn is working", async ($, on) => {
    await started($, on);
    const frame = { columns: SLOT_COLUMNS, rows: 2, cells: BLANK_CELLS };
    values.set("fm.workingSlot", frame);
    expect(text(await $.ui.render(BAR))).not.toContain("Raster");
    const drawn = text(await $.ui.render({ ...BAR, props: { ...BAR.props, isWorking: true } }));
    expect(drawn).toContain('"type":"Raster"');
    expect(drawn).toContain(`"cells":"${BLANK_CELLS}"`);
    values.set("fm.workingSlot", null);
    expect(text(await $.ui.render({ ...BAR, props: { ...BAR.props, isWorking: true } }))).not.toContain("Raster");
  });

  test("stamps the last response when the main conversation's turn completes, not a subagent's", async ($, on) => {
    await started($, on);
    await $.turn.complete({ answer: "x", durationMs: 1, isAborted: false, turnId: "t1", reason: "answer", agentId: "sub" } as never);
    expect(text(await $.ui.render(BAR))).toContain("last reply -");
    await $.turn.complete({ answer: "x", durationMs: 1, isAborted: false, turnId: "t2", reason: "answer" } as never);
    expect(text(await $.ui.render(BAR))).toMatch(/last reply \d\d-\d\d \d\d:\d\d/);
  });

  test("leaves the engine's own band alone when a survey holds it or the opt-in is absent", async ($, on) => {
    await started($, on);
    expect(text(await $.ui.render({ ...BAR, props: { ...BAR.props, hasSurvey: true } }))).toContain("STOCK");
  });

  test("is inert without the function-hooks opt-in", async ($, on) => {
    await started($, on, "0");
    expect(text(await $.ui.render(BAR))).toContain("STOCK");
  });
});
