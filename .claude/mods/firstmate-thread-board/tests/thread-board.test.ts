// The thread board under `claude plugin test`: the thread store's operations, the bar's
// layout math, and the engine glue that keeps threads and draws the bar and its slot.
import { describe, expect, test } from "claude-code/testing";
import { mock } from "claude-code/testing";
import {
  applyThread,
  describeActivity,
  EMPTY_BOARD,
  fit,
  formatLastResponse,
  layoutBar,
  nextMarker,
  replayThreads,
  textWidth,
  tickerText,
  tickerWindow,
  SLOT_COLUMNS,
  SLOT_GAP,
  THREAD_MARKERS,
  THREAD_TOOL,
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

describe("rebuilding a board from the transcript", () => {
  const use = (input: Record<string, string>, extra: Record<string, unknown> = {}) => ({
    tool: THREAD_TOOL,
    input,
    text: "ok",
    ...extra,
  });

  test("replays answered thread calls in order, closed threads and their spent markers included", () => {
    const board = replayThreads([
      { toolUses: [use({ action: "add", name: "calm", brief: "slot" }), use({ action: "add", name: "bar" })] },
      { toolUses: [{ tool: "Bash", input: { command: "ls" }, text: "x" }] },
      { toolUses: [use({ action: "close", name: "calm" }), use({ action: "update", name: "bar", brief: "drawing" })] },
    ]);
    expect(board.threads).toEqual([
      { marker: "🟠", name: "calm", brief: "slot", open: false },
      { marker: "🟡", name: "bar", brief: "drawing", open: true },
    ]);
    expect(nextMarker(board.threads)).toBe("🟢");
  });

  test("skips a refused call and the call still in flight, which applies itself", () => {
    const board = replayThreads([
      { toolUses: [use({ action: "add", name: "calm" }), use({ action: "add", name: "x" }, { isError: true })] },
      { toolUses: [{ tool: THREAD_TOOL, input: { action: "add", name: "now" } }] },
    ]);
    expect(board.threads.map((thread) => thread.name)).toEqual(["calm"]);
  });

  test("tells the model how to rebuild when it names a thread on an empty board", () => {
    expect(applyThread(EMPTY_BOARD, { action: "update", marker: "🟠", brief: "x" }).text).toContain("re-open the conversation's threads with action=add");
    expect(applyThread(add(EMPTY_BOARD, "calm").board, { action: "close", name: "nope" }).text).not.toContain("empty");
  });
});

describe("the ticker", () => {
  const board = add(add(EMPTY_BOARD, "calm", "wiring the boat").board, "bar", "drawing it").board;

  test("says the running tool while a turn works, else the active thread, else nothing", () => {
    expect(tickerText(board, "Bash: ls")).toBe("Bash: ls");
    expect(tickerText(board, undefined)).toBe("bar - drawing it");
    const touched = applyThread(board, { action: "update", name: "calm", brief: "merged" }).board;
    expect(tickerText(touched, undefined)).toBe("calm - merged");
    // Closing the active thread falls back to the newest open one.
    expect(tickerText(applyThread(touched, { action: "close", name: "calm" }).board, undefined)).toBe("bar - drawing it");
    expect(tickerText(EMPTY_BOARD, undefined)).toBe("");
  });

  test("describes a tool call by its most telling argument", () => {
    expect(describeActivity("Bash", { command: "git  status\n-s" })).toBe("Bash: git status -s");
    expect(describeActivity("Edit", { file_path: "/a/b/register.tsx", old_string: "x" })).toBe("Edit: register.tsx");
    expect(describeActivity("mcp__github__get_me", {})).toBe("github:get_me");
  });

  test("sits still when it fits and scrolls one character a step, wrapping round, when it does not", () => {
    expect(tickerWindow("short", 10, 7)).toEqual({ text: "short", scrolls: false });
    const text = "abcdefghij";
    const frames = [0, 1, 2].map((tick) => tickerWindow(text, 6, tick));
    expect(frames.map((frame) => frame.text)).toEqual(["abcdef", "bcdefg", "cdefgh"]);
    expect(frames.every((frame) => frame.scrolls)).toBe(true);
    // One lap is the text plus its gap; the window then starts over.
    expect(tickerWindow(text, 6, 13).text).toBe("abcdef");
    expect(tickerWindow(text, 6, 11).text).toBe("  abcd");
    for (let tick = 0; tick < 30; tick += 1) expect(textWidth(tickerWindow("🟠 wide 🟡 text", 9, tick).text)).toBeLessThanOrEqual(9);
  });

  test("takes the room the stamp leaves, and none below the narrowest worth drawing", () => {
    const roomy = layoutBar(board, 100, "a short line", 0);
    expect(roomy).toMatchObject({ ticker: "a short line", scrolls: false });
    const long = "x".repeat(200);
    const cut = layoutBar(board, 100, long, 0);
    expect(cut.scrolls).toBe(true);
    expect(textWidth(cut.stamp) + 2 + textWidth(cut.ticker)).toBe(cut.leftColumns);
    expect(layoutBar(board, 50, long, 0)).toMatchObject({ ticker: "", scrolls: false });
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
      const layout = layoutBar(some(8), columns, "y".repeat(300));
      expect(layout.slotColumns).toBe(SLOT_COLUMNS);
      expect(layout.leftColumns + SLOT_GAP + layout.slotColumns).toBe(columns);
      expect(textWidth(layout.stamp) + 2 + textWidth(layout.ticker)).toBeLessThanOrEqual(layout.leftColumns);
      expect(textWidth(layout.legend)).toBeLessThanOrEqual(layout.leftColumns);
    }
  });

  test("flows the chips across the one legend row and folds what does not fit into a +N that keeps the count", () => {
    const layout = layoutBar(some(8), 100);
    const shown = THREAD_MARKERS.filter((marker) => layout.legend.includes(marker)).length;
    const folded = Number(/ \+(\d+)$/.exec(layout.legend)?.[1] ?? 0);
    expect(shown).toBeGreaterThan(0);
    expect(shown + folded).toBe(8);
    // Wide enough for everything: no fold at all.
    const roomy = layoutBar(some(3, ""), 200);
    expect(roomy.legend).not.toContain("+");
    expect(roomy.legend).toBe("🟠 thread0  🟡 thread1  🟢 thread2");
  });

  test("gives a chip its brief when the row has room and its name alone when it does not", () => {
    expect(layoutBar(some(1, "a fairly long brief here"), 100).legend).toBe("🟠 thread0 - a fairly long brief here");
    expect(layoutBar(some(1, "a fairly long brief here"), 60).legend).toBe("🟠 thread0");
  });

  test("shows only open threads and survives a terminal narrower than the slot", () => {
    const closed = applyThread(some(2), { action: "close", marker: "🟠" }).board;
    expect(layoutBar(closed, 120).legend).not.toContain("thread0");
    const narrow = layoutBar(some(2), 20, "something");
    expect(narrow.leftColumns).toBe(0);
    // ponytail: under about 40 columns the left text has no room at all; hiding the slot there if it ever matters.
    expect([narrow.legend, narrow.ticker]).toEqual(["", ""]);
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
  // The transcript `$.session.messages()` answers, and the session's id.
  let transcript: unknown[] = [];
  let sessionId = "session-1";
  let clock: ReturnType<typeof mock.clock>;

  async function started($: Parameters<Parameters<typeof test>[1]>[0], on: Parameters<Parameters<typeof test>[1]>[1], hooks = "1") {
    mock.env(on, { CLAUDE_CODE_ENABLE_FUNCTION_HOOKS: hooks });
    mock.store(on);
    clock = mock.clock(on);
    values.clear();
    on("state.get", async (_$, e) => ({ value: { value: values.get(`${e.plugin}.${e.key}`) as never, version: 1 } }));
    on("state.set", async (_$, e) => {
      values.set(`${e.plugin}.${e.key}`, e.value);
      return { value: { isSet: true as const, version: 1 } };
    });
    on("turn.complete", async () => ({ text: "" }));
    on("session.end", async () => ({}));
    on("session.id", async () => ({ value: sessionId }));
    on("session.messages", async () => ({ value: transcript as never }));
    on("session.start", async (_$, e) => ({ cwd: e.cwd }));
    on("tool.register", async (_$, e) => ({ value: { tool: `mcp__fm-threads__${e.name}` } }));
    on("tool.call", async () => ({ result: "ok", text: "ok" }));
    on("ui.render", async () => ({ type: "Text", props: {}, children: ["STOCK"] }));
    await $.session.start({ cwd: "/work", surface: "terminal", isInteractive: true });
  }

  const call = ($: Parameters<Parameters<typeof test>[1]>[0], input: Record<string, string>) =>
    $.tool.call({ tool: "mcp__fm-threads__thread", ...input } as never);
  const working = { ...BAR, props: { ...BAR.props, isWorking: true } };

  test("keeps threads through the tool and draws them in the bar with the empty slot", async ($, on) => {
    await started($, on);
    await call($, { action: "add", name: "calm", brief: "slot wiring" });
    await call($, { action: "add", name: "bar", brief: "drawing it" });
    const drawn = text(await $.ui.render(BAR));
    expect(drawn).toContain("🟠 calm - slot wiring");
    expect(drawn).toContain("🟡 bar - drawing it");
    expect(drawn).toContain("last reply -");
    expect(drawn).not.toContain("Raster");
    await call($, { action: "close", name: "calm" });
    expect(text(await $.ui.render(BAR))).not.toContain("slot wiring");
  });

  test("draws a divider above the bar, the last reply and ticker on top, and the legend on the bottom row", async ($, on) => {
    await started($, on);
    await call($, { action: "add", name: "calm", brief: "slot wiring" });
    const drawn = text(await $.ui.render(BAR));
    const divider = drawn.indexOf("─".repeat(BAR.props.bodyColumns));
    const stamp = drawn.indexOf("last reply");
    // The ticker is the active thread's brief while nothing runs; the legend holds the chip after it.
    const ticker = drawn.indexOf("calm - slot wiring");
    const legend = drawn.indexOf("🟠 calm - slot wiring");
    expect(divider).toBeGreaterThanOrEqual(0);
    expect(divider).toBeLessThan(stamp);
    expect(stamp).toBeLessThan(ticker);
    expect(ticker).toBeLessThan(legend);
    expect(drawn.split("🟠").length - 1).toBe(1);
  });

  test("says the running tool in the ticker, still when it fits and moving when it does not", async ($, on) => {
    await started($, on);
    const frames = async (bar: typeof BAR): Promise<string[]> => {
      const seen: string[] = [];
      for (let step = 0; step < 3; step += 1) {
        seen.push(text(await $.ui.render(bar)));
        await clock.advance(250);
      }
      return seen;
    };
    await $.tool.call({ tool: "Bash", command: "git status" } as never);
    const [first, ...later] = await frames(working);
    expect(first).toContain("Bash: git status");
    expect(later.every((frame) => frame === first)).toBe(true);
    // Out of a turn the tool is no longer what is going on.
    expect(text(await $.ui.render(BAR))).not.toContain("Bash: git status");

    const narrow = { ...working, props: { ...working.props, bodyColumns: 70 } };
    await $.tool.call({ tool: "Bash", command: "bin/fm-spawn.sh --task thread-board-ticker --profile some-long-profile-name" } as never);
    const [one, two, three] = await frames(narrow);
    expect(one).toContain("Bash: bin/fm");
    expect(new Set([one, two, three]).size).toBe(3);
    expect(one).not.toContain("some-long-profile-name");
    // The turn ending clears the line.
    await $.turn.complete({ answer: "x", durationMs: 1, isAborted: false, turnId: "t1", reason: "answer" } as never);
    expect(text(await $.ui.render(working))).not.toContain("Bash: bin/fm");
  });

  test("draws Calm's published frame in the slot only while a turn is working", async ($, on) => {
    await started($, on);
    const frame = { columns: SLOT_COLUMNS, rows: 2, cells: BLANK_CELLS };
    values.set("fm.workingSlot", frame);
    expect(text(await $.ui.render(BAR))).not.toContain("Raster");
    const drawn = text(await $.ui.render(working));
    expect(drawn).toContain('"type":"Raster"');
    expect(drawn).toContain(`"cells":"${BLANK_CELLS}"`);
    values.set("fm.workingSlot", null);
    expect(text(await $.ui.render(working))).not.toContain("Raster");
  });

  test("stamps the last response when the main conversation's turn completes, not a subagent's", async ($, on) => {
    await started($, on);
    await $.turn.complete({ answer: "x", durationMs: 1, isAborted: false, turnId: "t1", reason: "answer", agentId: "sub" } as never);
    expect(text(await $.ui.render(BAR))).toContain("last reply -");
    await $.turn.complete({ answer: "x", durationMs: 1, isAborted: false, turnId: "t2", reason: "answer" } as never);
    expect(text(await $.ui.render(BAR))).toMatch(/last reply \d\d-\d\d \d\d:\d\d/);
  });

  // The session moved to the background: the same conversation under a new id, with the old id's board left behind in the store.
  describe("a session moved to the background", () => {
    const answered = (input: Record<string, string>) => ({ tool: "mcp__fm-threads__thread", input, text: "ok" });
    const conversation = [
      { role: "assistant", text: "", toolUses: [answered({ action: "add", name: "calm", brief: "slot wiring" })] },
      { role: "assistant", text: "", toolUses: [answered({ action: "add", name: "bar", brief: "drawing it" })] },
      { role: "assistant", text: "", toolUses: [answered({ action: "close", name: "calm" })] },
    ];

    test("gets its threads back from the transcript under the new id, and keeps working on them", async ($, on) => {
      transcript = conversation;
      sessionId = "moved-2";
      await started($, on);
      const drawn = text(await $.ui.render(BAR));
      expect(drawn).toContain("🟡 bar - drawing it");
      expect(drawn).not.toContain("slot wiring");
      // The thread opened before the move answers to its marker.
      const update = await call($, { action: "update", marker: "🟡", brief: "moved" });
      expect(update).not.toHaveProperty("isError");
      expect(text(await $.ui.render(BAR))).toContain("🟡 bar - moved");
      // The closed thread's marker stays spent.
      await call($, { action: "add", name: "next" });
      expect(text(await $.ui.render(BAR))).toContain("🟢 next");
      transcript = [];
      sessionId = "session-1";
    });

    test("rebuilds on the first thread call when the transcript was not readable at start", async ($, on) => {
      transcript = [];
      sessionId = "moved-3";
      await started($, on);
      expect(text(await $.ui.render(BAR))).not.toContain("bar - drawing it");
      transcript = conversation;
      const refused = await call($, { action: "update", marker: "🟡", brief: "moved" });
      expect(refused).not.toHaveProperty("isError");
      expect(text(await $.ui.render(BAR))).toContain("🟡 bar - moved");
      transcript = [];
      sessionId = "session-1";
    });

    test("tells the model to re-open the threads when nothing can be rebuilt", async ($, on) => {
      await started($, on);
      const result = await call($, { action: "update", marker: "🟡", brief: "x" });
      expect(result).toMatchObject({ isError: true });
      expect(text(result)).toContain("action=add");
    });
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
