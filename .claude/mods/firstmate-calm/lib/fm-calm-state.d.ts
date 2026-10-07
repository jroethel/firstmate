// The Calm mod's `$.state` contract. Any plugin reads these values; only this one writes them.
declare module 'claude-code' {
  interface PluginState {
    fm: {
      /** Calm's working-ship frame packed for the thread board's slot while Calm is on and a turn runs; null otherwise. */
      workingSlot: { columns: number; rows: number; cells: string } | null;
    };
    // Owned and written by the thread board (../firstmate-thread-board); Calm only reads it.
    'fm-threads': { slot: { columns: number } | null };
  }
}
