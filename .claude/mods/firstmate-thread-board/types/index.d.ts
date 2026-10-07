// The thread board's `$.state` contract. Any plugin reads these values; only this one writes them.
// Self-contained on purpose: the engine reads this file alone, so the shapes repeat lib/fm-thread-board.ts's.
export type BoardThread = { marker: string; name: string; brief: string; open: boolean };
export type BoardState = { threads: BoardThread[]; lastResponseAt: number | null };
export type BoardSlot = { columns: number };

declare module 'claude-code' {
  interface PluginState {
    'fm-threads': {
      /** Every thread this session has opened, open or closed, and the last response's time. */
      board: BoardState;
      /** The width the bar reserves at its far right for Calm's working display; null until the bar loads. */
      slot: BoardSlot | null;
    };
  }
}

declare module 'claude-code' {
  interface PluginState {
    fm: { workingSlot: { columns: number; rows: number; cells: string } | null };
  }
}
