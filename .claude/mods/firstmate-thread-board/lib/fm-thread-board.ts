// The thread board's pure core: the thread store's operations and the bar's layout math.
//
// A thread is one conversation topic. Its marker is a colored circle assigned in order of
// first appearance and kept for the whole session, so a closed thread stays in the store
// (hidden from the bar) and its marker is never handed out again. Red never appears: it
// reads as an error. ../hooks/register.tsx owns everything that touches the engine; this
// module is plain functions over plain data so the tests drive it under `claude plugin test`
// with no engine at all.

/** The thread tool's full name once the engine registers it for the `fm-threads` plugin. */
export const THREAD_TOOL = "mcp__fm-threads__thread";

/** The markers handed out in order; past them a thread is numbered. */
export const THREAD_MARKERS = ["🟠", "🟡", "🟢", "🔵", "🟣", "🟤", "⚪", "⚫"] as const;

/** Terminal columns the bar reserves at its far right for Calm's working display. */
export const SLOT_COLUMNS = 30;
/** Blank columns between the thread text and the slot. */
export const SLOT_GAP = 2;
/** Longest brief kept, in characters: a thread's description is a few words. */
export const BRIEF_MAX = 60;
/** Longest chip, marker included, in cells. */
export const CHIP_MAX = 40;
/** The narrowest chip worth drawing, in cells; a thread that cannot get this folds into "+N". */
export const CHIP_MIN = 12;
/** The narrowest ticker worth drawing beside the stamp, in cells. */
export const TICKER_MIN = 8;
/** Blank cells between the end of a scrolling ticker's text and its start coming round again. */
export const TICKER_GAP = "   ";
/** Longest activity line kept, in characters, before it is windowed to the bar. */
export const ACTIVITY_MAX = 200;

export type Thread = {
  marker: string;
  name: string;
  brief: string;
  open: boolean;
};

export type Board = {
  threads: Thread[];
  /** Epoch milliseconds of the session's last response, or null before the first. */
  lastResponseAt: number | null;
  /** The marker of the thread touched last, whose brief the ticker shows while nothing is running; absent on boards saved before the ticker. */
  active?: string | null;
};

export const EMPTY_BOARD: Board = { threads: [], lastResponseAt: null, active: null };

export type ThreadInput = {
  action: "add" | "update" | "close";
  /** The marker to add under, or the thread to update or close. */
  marker?: string;
  /** The short name to add under, or the thread to update or close when no marker is given. */
  name?: string;
  brief?: string;
};

export type ThreadResult = { board: Board; text: string; isError: boolean };

// Every symbol that reads as an error or a stop. A marker that is one of these is refused.
const RED_MARKERS = new Set(["🔴", "🟥", "❤️", "❤", "♥️", "♥", "❌", "⛔", "🛑", "🚫", "📕", "🚨"]);

export function isRedMarker(marker: string): boolean {
  return RED_MARKERS.has(marker.trim());
}

/** The marker the next new thread gets: the next color in order, then a number. */
export function nextMarker(threads: readonly Thread[]): string {
  return THREAD_MARKERS[threads.length] ?? String(threads.length + 1);
}

function clean(text: string | undefined, max: number): string {
  return Array.from((text ?? "").replace(/\s+/g, " ").trim()).slice(0, max).join("");
}

function find(threads: readonly Thread[], input: ThreadInput): Thread | undefined {
  const marker = input.marker?.trim();
  if (marker) return threads.find((thread) => thread.marker === marker);
  const name = clean(input.name, 80).toLowerCase();
  if (name) return threads.find((thread) => thread.name.toLowerCase() === name);
  return undefined;
}

/** The open threads as the tool answers them, one line each. */
export function describeThreads(board: Board): string {
  const open = board.threads.filter((thread) => thread.open);
  if (open.length === 0) return "No open threads.";
  return open.map((thread) => `${thread.marker} ${thread.name}${thread.brief ? ` - ${thread.brief}` : ""}`).join("\n");
}

/** Apply one add, update, or close to the board. A refused input leaves the board as it was. */
export function applyThread(board: Board, input: ThreadInput): ThreadResult {
  const refuse = (text: string): ThreadResult => ({ board, text, isError: true });
  const done = (next: Board, verb: string): ThreadResult => ({
    board: next,
    text: `${verb}\n${describeThreads(next)}`,
    isError: false,
  });
  if (input.action === "add") {
    const name = clean(input.name, 40);
    if (!name) return refuse("A thread needs a short name.");
    const given = input.marker?.trim();
    if (given && isRedMarker(given)) return refuse("Red reads as an error and is never a thread marker; omit the marker to get the next color.");
    const marker = given || nextMarker(board.threads);
    if (board.threads.some((thread) => thread.marker === marker)) return refuse(`Marker ${marker} already belongs to a thread this session.`);
    const thread: Thread = { marker, name, brief: clean(input.brief, BRIEF_MAX), open: true };
    return done({ ...board, threads: [...board.threads, thread], active: marker }, `Opened ${marker} ${name}.`);
  }
  const target = find(board.threads, input);
  if (target === undefined) {
    // An empty board mid-conversation means the threads were lost, so say how to rebuild them.
    const lost = board.threads.length === 0 ? " The board is empty: re-open the conversation's threads with action=add." : "";
    return refuse(`No thread matches that marker or name.${lost}`);
  }
  const threads = board.threads.map((thread) => {
    if (thread !== target) return thread;
    if (input.action === "close") return { ...thread, open: false };
    return {
      ...thread,
      open: true,
      // Naming the thread by marker is how a rename is asked for.
      name: input.marker?.trim() && clean(input.name, 40) ? clean(input.name, 40) : thread.name,
      brief: input.brief === undefined ? thread.brief : clean(input.brief, BRIEF_MAX),
    };
  });
  const closing = input.action === "close";
  const active = closing ? (board.active === target.marker ? null : board.active ?? null) : target.marker;
  return done({ ...board, threads, active }, `${closing ? "Closed" : "Updated"} ${target.marker} ${target.name}.`);
}

/** One message of the transcript, as far as the board's replay reads it. */
export type ReplayMessage = {
  toolUses?: readonly { tool: string; input: Record<string, unknown>; text?: string; isError?: boolean }[];
};

/**
 * The board the transcript's thread calls add up to, replayed in order from an empty one.
 * A session moved to the background keeps its transcript under a new session id, so this
 * is how the new id gets its threads back.
 */
// ponytail: replays only what $.session.messages() holds (the newest 4096 entries, and nothing a compaction dropped); older threads are lost.
export function replayThreads(messages: readonly ReplayMessage[]): Board {
  let board = EMPTY_BOARD;
  for (const message of messages) {
    for (const use of message.toolUses ?? []) {
      // A call with no answer yet is the one being made right now, which applies itself.
      if (use.tool !== THREAD_TOOL || use.isError || use.text === undefined) continue;
      board = applyThread(board, use.input as unknown as ThreadInput).board;
    }
  }
  return board;
}

/** Terminal columns one code point takes: the markers and other emoji and CJK are two, joiners none. */
function cellWidth(codePoint: number): number {
  if (codePoint === 0x200d || (codePoint >= 0xfe00 && codePoint <= 0xfe0f)) return 0;
  if (codePoint === 0x26aa || codePoint === 0x26ab) return 2;
  if (codePoint >= 0x1f300 && codePoint <= 0x1faff) return 2;
  if (codePoint >= 0x1100 && codePoint <= 0x115f) return 2;
  if (codePoint >= 0x2e80 && codePoint <= 0xa4cf) return 2;
  if (codePoint >= 0xac00 && codePoint <= 0xd7a3) return 2;
  if (codePoint >= 0xff00 && codePoint <= 0xff60) return 2;
  return 1;
}

export function textWidth(text: string): number {
  let width = 0;
  for (const char of text) width += cellWidth(char.codePointAt(0) ?? 0);
  return width;
}

/** The text cut to at most `max` cells, ending in an ellipsis when it was cut. */
export function fit(text: string, max: number): string {
  if (max <= 0) return "";
  if (textWidth(text) <= max) return text;
  let out = "";
  let width = 0;
  for (const char of text) {
    const next = cellWidth(char.codePointAt(0) ?? 0);
    if (width + next > max - 1) break;
    out += char;
    width += next;
  }
  return `${out}…`;
}

const pad2 = (value: number): string => String(value).padStart(2, "0");

/** `10-06 23:42` in the machine's local time, or a dash before the first response. */
export function formatLastResponse(epochMs: number | null): string {
  if (epochMs === null) return "-";
  const date = new Date(epochMs);
  return `${pad2(date.getMonth() + 1)}-${pad2(date.getDate())} ${pad2(date.getHours())}:${pad2(date.getMinutes())}`;
}

export type BarLayout = {
  /** The last-response stamp that heads the top row. */
  stamp: string;
  /** What the ticker shows in its window now: the whole text when it fits, else the part of it scrolled into view. */
  ticker: string;
  /** Whether the ticker text is wider than its window and so moves. */
  scrolls: boolean;
  /** The thread chips on the bottom row. */
  legend: string;
  /** Cells the left text may take. */
  leftColumns: number;
  /** Cells reserved at the far right, after SLOT_GAP blank ones. */
  slotColumns: number;
};

/** What the model is doing, as one short line: the tool and the most telling thing it was handed. */
export function describeActivity(tool: string, args: Record<string, unknown>): string {
  const name = tool.startsWith("mcp__") ? tool.split("__").slice(1).join(":") : tool;
  const pick = (key: string): string | undefined => {
    const value = args[key];
    return typeof value === "string" && value.trim() !== "" ? value : undefined;
  };
  const file = pick("file_path")?.split("/").pop();
  const detail = pick("command") ?? file ?? pick("pattern") ?? pick("url") ?? pick("query") ?? pick("description");
  return detail === undefined ? name : `${name}: ${clean(detail, ACTIVITY_MAX)}`;
}

/** What the ticker says: the running tool's line while a turn works, else the active thread's name and brief. */
export function tickerText(board: Board, activity: string | undefined): string {
  if (activity) return activity;
  const open = board.threads.filter((thread) => thread.open);
  const thread = open.find((candidate) => candidate.marker === board.active) ?? open[open.length - 1];
  return thread === undefined ? "" : `${thread.name}${thread.brief ? ` - ${thread.brief}` : ""}`;
}

/** The text as `columns` cells show it: whole when it fits, else a window that moves one character per `tick`, wrapping round after a gap. */
export function tickerWindow(text: string, columns: number, tick: number): { text: string; scrolls: boolean } {
  if (textWidth(text) <= columns) return { text, scrolls: false };
  const chars = Array.from(`${text}${TICKER_GAP}`);
  const start = ((tick % chars.length) + chars.length) % chars.length;
  let out = "";
  let width = 0;
  for (let at = 0; at < chars.length; at += 1) {
    const char = chars[(start + at) % chars.length]!;
    const next = cellWidth(char.codePointAt(0) ?? 0);
    if (width + next > columns) break;
    out += char;
    width += next;
  }
  return { text: out, scrolls: true };
}

/** One thread's chip in `max` cells: marker, name and brief when they fit, else the marker and name alone, cut if need be. */
function chip(thread: Thread, max: number): string {
  const full = `${thread.marker} ${thread.name}${thread.brief ? ` - ${thread.brief}` : ""}`;
  return textWidth(full) <= Math.min(max, CHIP_MAX) ? full : fit(`${thread.marker} ${thread.name}`, max);
}

/**
 * Lay the bar out for `bodyColumns` cells: the slot at the far right; on the top row the
 * last-response stamp with the ticker after it; on the bottom row every open thread's chip.
 * Threads that no longer fit fold into a closing "+N" so the count is never silently lost.
 */
export function layoutBar(board: Board, bodyColumns: number, ticker = "", tick = 0): BarLayout {
  const slotColumns = SLOT_COLUMNS;
  const leftColumns = Math.max(0, bodyColumns - slotColumns - SLOT_GAP);
  const stamp = fit(`last reply ${formatLastResponse(board.lastResponseAt)}`, leftColumns);
  const tickerColumns = leftColumns - textWidth(stamp) - 2;
  const moving = tickerColumns >= TICKER_MIN && ticker !== "" ? tickerWindow(ticker, tickerColumns, tick) : { text: "", scrolls: false };
  let legend = "";
  const open = board.threads.filter((thread) => thread.open);
  let shown = 0;
  for (const thread of open) {
    const behind = open.length - shown - 1;
    // Keep room for the closing "+N" while threads remain behind this one.
    const room = leftColumns - textWidth(legend) - (legend === "" ? 0 : 2) - (behind > 0 ? textWidth(` +${behind}`) : 0);
    if (room < CHIP_MIN) break;
    legend = `${legend}${legend === "" ? "" : "  "}${chip(thread, room)}`;
    shown += 1;
  }
  if (shown < open.length) legend = fit(`${legend} +${open.length - shown}`.trimStart(), leftColumns);
  return { stamp, ticker: moving.text, scrolls: moving.scrolls, legend, leftColumns, slotColumns };
}
