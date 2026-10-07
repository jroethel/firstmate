// Firstmate thread board for Claude Code: the hooks module of the thread-board mod, whose
// plugin name is `fm-threads`.
//
// One bar above the prompt, two rows tall: the session's last response time and every open
// conversation thread on the left, and a reserved slot at the far right. The threads live in
// one store, kept by the model through the `thread` tool this module registers (add, update,
// close). The slot stays empty until Firstmate Calm (../../firstmate-calm) is on and a turn
// is running; Calm then publishes its working-ship frame as the `fm` plugin's `workingSlot`
// state value, which this bar draws, so the boat gets a bounded 30 columns instead of the
// transcript's full width. This module publishes `slot` so Calm knows a bar is there to draw
// into; with no bar loaded Calm draws as it always did.
//
// All of the engine glue is here; the thread operations and the layout math are plain
// functions in ../lib/fm-thread-board.ts, tested without an engine. Like Calm, nothing here
// does anything unless CLAUDE_CODE_ENABLE_FUNCTION_HOOKS is exactly 1.
import type { EngineInterface, Register } from "claude-code";
import {
  applyThread,
  EMPTY_BOARD,
  layoutBar,
  SLOT_COLUMNS,
  SLOT_GAP,
  type Board,
  type ThreadInput,
} from "../lib/fm-thread-board.ts";

const TOOL = "thread";
const FULL_TOOL = `mcp__fm-threads__${TOOL}`;

const BOARD = { plugin: "fm-threads", key: "board" } as const;
const SLOT = { plugin: "fm-threads", key: "slot" } as const;
// Calm's published working-ship frame, packed for the slot's width.
const CALM_SLOT = { plugin: "fm", key: "workingSlot" } as const;

let activation: Promise<boolean> | undefined;

function isActivated($: EngineInterface): Promise<boolean> {
  if (activation === undefined) {
    activation = $.env.get("CLAUDE_CODE_ENABLE_FUNCTION_HOOKS").then(
      (value) => value === "1",
      () => false,
    );
  }
  return activation;
}

/** The store key for this session's board, so `--continue` restores its threads. */
async function storeKey($: EngineInterface): Promise<string> {
  return `board:${await $.session.id().catch(() => "session")}`;
}

async function readBoard($: EngineInterface): Promise<Board> {
  return (await $.state.get(BOARD)).value ?? EMPTY_BOARD;
}

/** Make `board` the session's board: the drawing's source and the copy that outlives the session. */
async function saveBoard($: EngineInterface, board: Board): Promise<void> {
  await $.state.set(BOARD, board);
  await $.store.set(await storeKey($), board).catch(() => undefined);
}

export const register: Register = (on) => {
  on("session.start", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const stored = (await $.store.get(await storeKey($)).catch(() => undefined)) as Board | undefined;
    await $.state.set(BOARD, stored ?? EMPTY_BOARD);
    await $.state.set(SLOT, { columns: SLOT_COLUMNS });
    await $.tool.register({
      name: TOOL,
      description:
        "Keep the session's conversation-thread board. Each topic of the conversation is a thread with a colored circle marker, a short name, and a brief description (a few words); the board is shown to the person above the prompt. " +
        "Call action=add when a new topic begins (the marker is assigned in order: orange, yellow, green, blue, purple, brown, white, black, then numbers - omit it unless the person's replies already use one), " +
        "action=update (marker or name, plus a new brief) when a topic's state changes, and action=close when a topic is finished. " +
        "A thread keeps its marker for the whole session. Red is never used.",
      inputSchema: {
        type: "object",
        properties: {
          action: { type: "string", enum: ["add", "update", "close"] },
          marker: { type: "string", description: "add: the marker to use, normally omitted. update/close: the thread's marker." },
          name: { type: "string", description: "The thread's short name (a word or two). update/close: names the thread when no marker is given." },
          brief: { type: "string", description: "A very brief description: where the thread stands." },
        },
        required: ["action"],
      },
    });
    return next(e);
  });

  // A /clear starts a new conversation, so its board starts empty.
  on("session.end", async ($, e, next) => {
    if (await isActivated($)) {
      if (e.reason === "clear") await $.state.set(BOARD, EMPTY_BOARD);
    }
    return next(e);
  });

  on("tool.check", { tool: FULL_TOOL }, async ($, e, next) =>
    (await isActivated($)) ? { decision: "allow" as const } : next(e),
  );

  on("tool.call", { tool: FULL_TOOL }, async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    const result = applyThread(await readBoard($), e as unknown as ThreadInput);
    if (!result.isError) await saveBoard($, result.board);
    return { result: result.text, ...(result.isError ? { isError: true as const } : {}) };
  });

  // The main conversation's response ended (an interrupt included): stamp the time.
  on("turn.complete", async ($, e, next) => {
    if (!(await isActivated($))) return next(e);
    if (e.agentId === undefined) await saveBoard($, { ...(await readBoard($)), lastResponseAt: await $.clock.now() });
    return next(e);
  });

  on("ui.render", { component: "AbovePrompt" }, async ($, e, next) => {
    if (!(await isActivated($)) || e.surface !== "terminal" || e.props.hasSurvey) return next(e);
    const board = await readBoard($);
    const frame = (await $.state.get(CALM_SLOT)).value;
    const layout = layoutBar(board, e.props.bodyColumns);
    const { Box, Text, Raster } = $.ui.resolve(e);
    const boat = e.props.isWorking && frame ? frame : undefined;
    return (
      <Box flexDirection="row" width={e.props.bodyColumns}>
        <Box flexDirection="column" width={layout.leftColumns} flexShrink={0}>
          <Text wrap="truncate">
            <Text dimColor>{layout.stamp}</Text>
            {layout.rows[0] === "" ? "" : `  ${layout.rows[0]}`}
          </Text>
          <Text wrap="truncate">{layout.rows[1]}</Text>
        </Box>
        <Box width={SLOT_GAP + layout.slotColumns} height={2} paddingLeft={SLOT_GAP} flexShrink={0}>
          {boat && <Raster key="calm-slot" columns={boat.columns} rows={boat.rows} cells={boat.cells} />}
        </Box>
      </Box>
    );
  });
};
