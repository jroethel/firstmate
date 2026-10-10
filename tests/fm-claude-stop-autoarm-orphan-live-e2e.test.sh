#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for a Stop auto-arm claim left running
# by a session that is gone (fm_autoarm_claim_open in bin/fm-wake-lib.sh).
# Proves, against the real installed Claude Code in a bin/fm-live-lab.sh lab
# built from this checkout's HEAD:
#   - session A's process can end while its asynchronous Stop hook, supervision
#     host, and watcher keep running (the shape Claude's daemon left when it
#     retired an idle background session); if A's hook tree dies with it, the
#     guard fails naming the Claude Code version, because the case was not
#     exercised;
#   - a fresh session B started in A's place takes the session lock, and its
#     first turn end arms a host of its own instead of deferring to A's
#     leftover claim, and that host stops the leftover one;
#   - when the lab's gated worker then finishes, its status wakes session B.
# The guard tears the lab down and stops every lab process, including any
# hook tree left behind, which is no longer a descendant of the lab panes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_ORPHAN_CLAIM_LIVE_E2E claude tmux jq

LAB_SCRIPT="$ROOT/bin/fm-live-lab.sh"
CLAUDE_VERSION=$(claude --version)
LAB=$(mktemp -d /tmp/fmlab.XXXXXX) || fail "cannot reserve a lab root"
rmdir "$LAB"

lab_pids() {
  local p
  for p in $(pgrep -u "$(id -u)" . 2>/dev/null); do
    [ "$p" != "$$" ] || continue
    { tr '\0' ' ' < "/proc/$p/cmdline"; } 2>/dev/null | grep -q "$LAB/" && printf '%s\n' "$p"
  done
}

# A hook tree left behind by a killed session is no longer a descendant of the
# lab panes that down stops, so every process naming the lab root is stopped.
cleanup() {
  local -a pids=()
  [ ! -e "$LAB/.fm-live-lab" ] || "$LAB_SCRIPT" down "$LAB" >/dev/null 2>&1 || true
  read -r -a pids <<< "$(lab_pids | tr '\n' ' ')"
  if [ "${#pids[@]}" -gt 0 ]; then
    kill -TERM "${pids[@]}" 2>/dev/null
    sleep 2
    read -r -a pids <<< "$(lab_pids | tr '\n' ' ')"
    [ "${#pids[@]}" -eq 0 ] || kill -KILL "${pids[@]}" 2>/dev/null
  fi
  rm -rf "$LAB"
}
trap cleanup EXIT

wait_until() {  # <seconds> <command...>
  local deadline=$(( $(date +%s) + $1 ))
  shift
  until "$@"; do
    [ "$(date +%s)" -lt "$deadline" ] || return 1
    sleep 2
  done
}

[ -d /proc/self ] || { printf 'skip: live: this guard reads /proc to find lab processes\n'; exit 0; }

"$LAB_SCRIPT" up --harness claude --worker "$LAB" >/dev/null 2>&1 \
  || fail "$CLAUDE_VERSION: the lab did not come up: $("$LAB_SCRIPT" check "$LAB" 2>&1 | grep -v '^ok ')"
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
TMUX_DIR=$(sed -n 's/^tmux_dir=//p' "$LAB/.fm-live-lab" | head -n 1)
CONFIG_DIR=$(sed -n 's/^claude_config_dir=//p' "$LAB/.fm-live-lab" | head -n 1)
PROJECTS="${CONFIG_DIR:-$HOME/.claude}/projects"
WORKER_ID=$(sed -n 's/^worker_id=//p' "$LAB/.fm-live-lab" | head -n 1)
GATE=$(sed -n 's/^gate=//p' "$LAB/.fm-live-lab" | head -n 1)
lab_tmux() { env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux "$@"; }

claim_arming() { grep -q 'outcome=arming' "$STATE/.claude-autoarm-epoch" 2>/dev/null; }
host_pid() { awk -F '\t' '$1 == "host" { print $2; exit }' "$STATE/.supervision-host" 2>/dev/null; }
alive() { case "${1:-}" in ''|*[!0-9]*) return 1 ;; esac; kill -0 "$1" 2>/dev/null; }

# The parked worker's own turn end and its first-sight stale alert each close
# a cycle soon after up; let both be handled so the cycle that outlives A is a
# quiet, parked one.
stale_handled() { grep -q 'reason=actionable-stale' "$STATE/.watch-cycle-exits.log" 2>/dev/null && claim_arming; }
wait_until 360 stale_handled || fail "$CLAUDE_VERSION: the lab's first cycles never settled into a parked claim"
quiet() {
  local n
  n=$(wc -l < "$STATE/.watch-cycle-exits.log")
  sleep 30
  [ "$(wc -l < "$STATE/.watch-cycle-exits.log")" = "$n" ] && claim_arming && alive "$(host_pid)"
}
wait_until 300 quiet || fail "$CLAUDE_VERSION: the lab never held a parked cycle for 30s"

A_PID=$(head -n 1 "$STATE/.lock")
A_AUTOARM=$(sed -n '1s/.*owner_pid=\([0-9]*\).*/\1/p' "$STATE/.claude-autoarm-epoch")
A_HOST=$(host_pid)
A_WATCHER=$(cat "$STATE/.watch.lock/pid" 2>/dev/null)
kill -KILL "$A_PID" 2>/dev/null || fail "cannot end session A ($A_PID)"
sleep 5
alive "$A_PID" && fail "$CLAUDE_VERSION: session A $A_PID survived SIGKILL"
{ alive "$A_AUTOARM" && alive "$A_HOST" && claim_arming; } \
  || fail "$CLAUDE_VERSION: session A's Stop hook tree did not outlive it, so the leftover claim was not exercised"

lab_tmux respawn-pane -k -t firstmate:main -c "$HOME_DIR" \
  env FM_HOME="$HOME_DIR" CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false \
  claude --setting-sources project,local --model sonnet --effort medium --permission-mode auto \
  || fail "cannot start session B in the lab window"
lock_moved() { [ "$(head -n 1 "$STATE/.lock" 2>/dev/null)" != "$A_PID" ] && alive "$(head -n 1 "$STATE/.lock")"; }
wait_until 180 lock_moved || fail "$CLAUDE_VERSION: session B never took the session lock from gone session A"
B_PID=$(head -n 1 "$STATE/.lock")
B_ID=$(head -n 1 "$STATE/.lock-session" 2>/dev/null)
sleep 8
"$LAB_SCRIPT" say "$LAB" 'Lab probe: run no tool or command. Reply with only the word BREADY.' \
  || fail "cannot prompt session B"

descends_from_b() {  # <pid>
  local pid=$1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    case "$pid" in ''|*[!0-9]*|0|1) return 1 ;; esac
    [ "$pid" = "$B_PID" ] && return 0
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  done
  return 1
}
b_hosts() { descends_from_b "$(host_pid)"; }
wait_until 240 b_hosts \
  || fail "$CLAUDE_VERSION: session B's turn end deferred to gone session A's claim: no supervision host descends from B (host $(host_pid), A's host $A_HOST alive=$(alive "$A_HOST" && echo yes || echo no))"
leftover_gone() { ! alive "$A_HOST"; }
wait_until 90 leftover_gone || fail "$CLAUDE_VERSION: session B's host left gone session A's host $A_HOST running"
# Non-vacuity: the leftover cycle must have been stopped, not closed by a wake
# of its own, or B armed only because the claim had already ended.
A_EXIT=$(awk -F '\t' -v w="watcher_pid=$A_WATCHER" '$2 == w { for (i = 1; i <= NF; i++) if ($i ~ /^reason=/) r = substr($i, 8) } END { print r }' "$STATE/.watch-cycle-exits.log")
case "$A_EXIT" in
  ''|actionable-*) fail "$CLAUDE_VERSION: gone session A's cycle ended with '${A_EXIT:-no record}' before session B's turn end, so the leftover claim was not exercised" ;;
esac

touch "$GATE"
"$LAB_SCRIPT" say "$LAB" --window worker 'The gate file exists now; resume.' || fail "cannot resume the lab worker"
worker_done() { grep -q '^done' "$STATE/$WORKER_ID.status" 2>/dev/null; }
wait_until 900 worker_done || fail "$CLAUDE_VERSION: the lab worker never reported done"
DONE_AT=$(grep '^done' "$STATE/$WORKER_ID.status" | tail -n 1 | sed -n 's/.*\[at=\([0-9]*\)\].*/\1/p')
DONE_FROM=$(date -u -d "@${DONE_AT:-0}" +%FT%T)
b_woken() {
  local transcript
  for transcript in "$PROJECTS"/*/"$B_ID".jsonl; do
    [ -f "$transcript" ] || continue
    jq -r --arg s "$DONE_FROM" 'select((.timestamp // "") >= $s) | (.content // .message.content // "" | tostring)' "$transcript" 2>/dev/null \
      | grep -q 'Stop hook feedback' && return 0
  done
  return 1
}
wait_until 300 b_woken || fail "$CLAUDE_VERSION: the finished worker did not wake session B ($B_ID)"

pass "orphaned auto-arm claim live ($CLAUDE_VERSION): a session started after its predecessor's process died arms its own host and is woken by a finishing worker"
