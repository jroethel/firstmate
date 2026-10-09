#!/usr/bin/env bash
# Opt-in credentialed Claude live guard for the background-move lock handoff
# (fm_session_lock_handed_off_to_self in bin/fm-session-lock-lib.sh).
# Proves, against the real installed Claude Code in a bin/fm-live-lab.sh lab
# built from this checkout's HEAD:
#   - the agents view's left-arrow key moves the lab primary's conversation into
#     a new background session while the front-end that recorded the lock stays
#     alive as the agents view; if the front-end exits instead, the guard fails
#     naming the Claude Code version, because the live-owner case was not
#     exercised;
#   - Claude writes the continued-in record naming the moved session into the
#     moved-from transcript, the vendor signal the handoff reads;
#   - one turn in the moved session, attached in its own lab window, reclaims
#     the lock onto that session's model-loop pid and id, and a live watcher
#     then holds the lab home.
# The guard stops and removes the one background session it created and tears
# the lab down. It never sends any key but the left arrow to the agents view,
# which lists every background session of the account.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_live_gate opt-in FM_CLAUDE_BG_MOVE_LIVE_E2E claude tmux jq

LAB_SCRIPT="$ROOT/bin/fm-live-lab.sh"
CLAUDE_VERSION=$(claude --version)
LAB=$(mktemp -d /tmp/fmlab.XXXXXX) && rmdir "$LAB" || fail "cannot reserve a lab root"
MOVED_SHORT=

cleanup() {
  if [ -n "$MOVED_SHORT" ]; then
    claude stop "$MOVED_SHORT" >/dev/null 2>&1 || true
    claude rm "$MOVED_SHORT" >/dev/null 2>&1 || true
  fi
  [ ! -e "$LAB/.fm-live-lab" ] || "$LAB_SCRIPT" down "$LAB" >/dev/null 2>&1 || true
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

"$LAB_SCRIPT" up --harness claude --worker "$LAB" >/dev/null 2>&1 \
  || fail "$CLAUDE_VERSION: the lab did not come up: $("$LAB_SCRIPT" check "$LAB" 2>&1 | grep -v '^ok ')"
HOME_DIR="$LAB/home"
STATE="$HOME_DIR/state"
TMUX_DIR=$(sed -n 's/^tmux_dir=//p' "$LAB/.fm-live-lab" | head -n 1)
CONFIG_DIR=$(sed -n 's/^claude_config_dir=//p' "$LAB/.fm-live-lab" | head -n 1)
PROJECTS="${CONFIG_DIR:-$HOME/.claude}/projects"
lab_tmux() { env -u TMUX TMUX_TMPDIR="$TMUX_DIR" tmux "$@"; }

FRONTEND=$(head -n 1 "$STATE/.lock")
OLD_ID=$(head -n 1 "$STATE/.lock-session" 2>/dev/null)
[ -n "$OLD_ID" ] || fail "$CLAUDE_VERSION: the lab primary recorded no trusted session id beside its lock"

moved_id() {
  local transcript
  for transcript in "$PROJECTS"/*/"$OLD_ID".jsonl; do
    [ -f "$transcript" ] || continue
    grep '^{"type":"continued-in",' "$transcript" | tail -n 1 | jq -r '.continuedInSessionId // empty'
  done
}
have_moved_id() { MOVED_ID=$(moved_id) && [ -n "$MOVED_ID" ]; }

lab_tmux send-keys -t firstmate:main Left
wait_until 60 have_moved_id \
  || fail "$CLAUDE_VERSION: the left-arrow background move wrote no continued-in record for $OLD_ID"
MOVED_SHORT=${MOVED_ID:0:8}
sleep 5
kill -0 "$FRONTEND" 2>/dev/null \
  || fail "$CLAUDE_VERSION: the front-end $FRONTEND exited after the background move, so the live-owner case was not exercised"
[ "$(head -n 1 "$STATE/.lock")" = "$FRONTEND" ] \
  || fail "$CLAUDE_VERSION: the lock moved before the moved session ran a turn: $(head -n 1 "$STATE/.lock")"
MOVED_PID=$(claude agents --json --cwd "$HOME_DIR" | jq -r --arg id "$MOVED_ID" '.[] | select(.sessionId == $id) | .pid')
case "$MOVED_PID" in
  ''|*[!0-9]*) fail "$CLAUDE_VERSION: claude agents did not list the moved session $MOVED_ID" ;;
esac

lab_tmux new-window -d -t firstmate: -n moved -c "$HOME_DIR" claude attach "$MOVED_SHORT" \
  || fail "cannot attach the moved session in a lab window"
sleep 10
"$LAB_SCRIPT" say "$LAB" --window moved 'Lab probe: run no tool or command. Reply with only the word MOVED.' \
  || fail "cannot prompt the moved session"

lock_handed_off() {
  [ "$(head -n 1 "$STATE/.lock")" = "$MOVED_PID" ] \
    && [ "$(head -n 1 "$STATE/.lock-session" 2>/dev/null)" = "$MOVED_ID" ]
}
wait_until 240 lock_handed_off \
  || fail "$CLAUDE_VERSION: the moved session's turn left the lock at pid $(head -n 1 "$STATE/.lock"), session $(head -n 1 "$STATE/.lock-session" 2>/dev/null); expected pid $MOVED_PID, session $MOVED_ID"
kill -0 "$FRONTEND" 2>/dev/null \
  || fail "$CLAUDE_VERSION: the front-end exited before the handoff, so the live-owner case was not exercised"
watcher_live() { "$LAB_SCRIPT" check "$LAB" 2>/dev/null | grep -q '^ok watcher'; }
wait_until 120 watcher_live \
  || fail "$CLAUDE_VERSION: no live watcher held the lab home after the handoff: $("$LAB_SCRIPT" check "$LAB" 2>&1 | grep watcher)"

pass "session-lock live ($CLAUDE_VERSION): a left-arrow background move hands the live front-end's lock and supervision to the moved session"
