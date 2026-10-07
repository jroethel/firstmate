// The thread board's pure core: the thread store's operations and the bar's layout math.
//
// A thread is one conversation topic. Its marker is a colored circle assigned in order of
// first appearance and kept for the whole session, so a closed thread stays in the store
// (hidden from the bar) and its marker is never handed out again. Red never appears: it
// reads as an error. ../hooks/register.tsx owns everything that touches the engine; this
// module is plain functions over plain data so the tests drive it under `claude plugin test`
// with no engine at all.

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
};

export const EMPTY_BOARD: Board = { threads: [], lastResponseAt: null };

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
    return done({ ...board, threads: [...board.threads, thread] }, `Opened ${marker} ${name}.`);
  }
  const target = find(board.threads, input);
  if (target === undefined) return refuse("No thread matches that marker or name.");
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
  return done({ ...board, threads }, `${input.action === "close" ? "Closed" : "Updated"} ${target.marker} ${target.name}.`);
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
  /** The last-response stamp that heads row one. */
  stamp: string;
  /** The thread chips on each row; row one's follow the stamp. */
  rows: [string, string];
  /** Cells the left text may take. */
  leftColumns: number;
  /** Cells reserved at the far right, after SLOT_GAP blank ones. */
  slotColumns: number;
};

/** One thread's chip in `max` cells: marker, name and brief when they fit, else the marker and name alone, cut if need be. */
function chip(thread: Thread, max: number): string {
  const full = `${thread.marker} ${thread.name}${thread.brief ? ` - ${thread.brief}` : ""}`;
  return textWidth(full) <= Math.min(max, CHIP_MAX) ? full : fit(`${thread.marker} ${thread.name}`, max);
}

/**
 * Lay the bar out for `bodyColumns` cells: the slot at the far right, the last-response
 * stamp at the head of row one, then every open thread's chip flowing across row one and
 * on into row two. Threads that no longer fit fold into a closing "+N" so the count is
 * never silently lost.
 */
export function layoutBar(board: Board, bodyColumns: number): BarLayout {
  const slotColumns = SLOT_COLUMNS;
  const leftColumns = Math.max(0, bodyColumns - slotColumns - SLOT_GAP);
  const stamp = fit(`last reply ${formatLastResponse(board.lastResponseAt)}`, leftColumns);
  const rows: [string, string] = ["", ""];
  const open = board.threads.filter((thread) => thread.open);
  let row = 0;
  let shown = 0;
  for (const thread of open) {
    const behind = open.length - shown - 1;
    // Row two keeps room for the closing "+N" while threads remain behind this one.
    const reserve = (at: number): number => (at === 1 && behind > 0 ? textWidth(` +${behind}`) : 0);
    const room = (at: number): number =>
      leftColumns - textWidth(rows[at]!) - (at === 0 ? textWidth(stamp) + 2 : 0) - (rows[at] === "" ? 0 : 2) - reserve(at);
    // A chip moves down to row two rather than being cut short on row one.
    // The first chip settles for its name alone on row one; a later one wants room for its brief too.
    const named = Math.min(CHIP_MAX, textWidth(`${thread.marker} ${thread.name}`));
    const whole = Math.min(CHIP_MAX, textWidth(chip(thread, CHIP_MAX)));
    if (row === 0 && room(0) < (rows[0] === "" ? Math.max(CHIP_MIN, named) : whole)) row = 1;
    if (room(row) < CHIP_MIN) break;
    rows[row] = `${rows[row]}${rows[row] === "" ? "" : "  "}${chip(thread, room(row))}`;
    shown += 1;
  }
  if (shown < open.length) rows[1] = fit(`${rows[1]} +${open.length - shown}`.trimStart(), leftColumns);
  return { stamp, rows, leftColumns, slotColumns };
}
