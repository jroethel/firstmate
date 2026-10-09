#!/usr/bin/env bash
# Live Herdr submit-confirmation guard (live-harness-optin family).
#
# Herdr's native agent_status can stay idle for a whole landed Claude turn, and
# a busy-queued Enter can keep proven pending text visible. A stub cannot prove
# either signal. This guard launches real Claude Code in an isolated Herdr lab
# and requires fm_backend_herdr_send_text_submit to report empty for a landed
# idle steer. It then requires the same submit path to prove and submit a
# typed /exit slash command behind the command popup Claude renders below the
# composer (the fm-control exit breakage on 2.1.283, and on 2.1.294, where the
# popup's selected entry leads with the composer's own glyph) and verifies the
# agent actually exited.
# A second, named session then replays the steering blockers of issue #16
# through the production entry points: a steering doorbell wrapping under the
# session name Claude draws into the composer's top rule, a doorbell rung while
# the detailed-transcript view hides the composer, and fm-control exit with
# background work running, which must answer Claude's background-work picker
# with its exit option and stop that work.
# It fails naming the harness and version rather than degrading quietly.
#
# Run explicitly with FM_HERDR_SUBMIT_CONFIRM_LIVE=1 after a Herdr or Claude
# upgrade, and before trusting a refreshed docs/verification/runtime-backends.md
# "Herdr submit confirmation" entry.
# Every Herdr call, including adapter calls, is routed through bin/fm-herdr-lab.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}

fail() { printf 'not ok - %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

fm_live_gate opt-in FM_HERDR_SUBMIT_CONFIRM_LIVE herdr jq claude

[ -x "$LAB_HELPER" ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 but the Herdr lab helper is not executable at $LAB_HELPER"

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"
herdr_forget_inherited_pane

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name herdr-submit-confirm-live)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-herdr-submit-confirm-live.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"
CHECKED=0

cleanup() {
  local rc=$?
  trap - EXIT
  [ -z "${BG_MARK:-}" ] || pkill -f "$BG_MARK" 2>/dev/null || true
  if ! PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION"; then
    rc=1
  fi
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }
WS_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive --no-focus) \
  || fail "could not create the isolated submit-confirm workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"
VERSION=$(PATH="$ORIGINAL_PATH" claude --version 2>/dev/null | head -1 || printf 'version-unknown')
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

lab pane run "$PANE" "CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch Claude Code ($VERSION) in the isolated Herdr pane"

idle=0
trusted=0
i=0
while [ "$i" -lt 60 ]; do
  screen=$(lab pane read "$PANE" --source visible 2>/dev/null || true)
  case "$screen" in
    *'bypass permissions on'*)
      # The composer footer means Claude is past any folder-trust prompt. Herdr
      # can report the agent idle while that prompt is still up, so the wait
      # keys off the rendered composer rather than the native status alone.
      st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
      case "$st" in idle|done) idle=1; break ;; esac
      ;;
    *'Yes, I trust this folder'*)
      # A fresh checkout path stops on Claude's folder-trust prompt, which the
      # pre-send proof would read as a non-empty composer. Accept it once and
      # keep waiting for a real idle composer; the accepted dialog stays in the
      # viewport. The prompt preselects "No, exit", so move to "Yes" before
      # confirming; a bare Enter quits Claude.
      if [ "$trusted" = 0 ]; then
        trusted=1
        lab pane send-keys "$PANE" down enter >/dev/null \
          || fail "could not accept Claude's folder-trust prompt"
      fi
      ;;
  esac
  i=$((i + 1))
  sleep 1
done
[ "$idle" = 1 ] || fail "Claude Code ($VERSION) on $HERDR_VER never rendered an idle composer in the lab pane"

TOKEN="FMHERDRPONG$$_$RANDOM"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
  || fail "send_text_submit failed to run against Claude Code ($VERSION) on $HERDR_VER"
CHECKED=1
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed idle steer must confirm empty, got '$verdict'"

# Confirm the instruction reached Claude, not merely that the composer cleared.
# The token occurs once in the submitted prompt and once in Claude's reply.
landed=0
i=0
screen=''
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER reports empty and renders the requested reply in isolated session $SESSION"

# Away-mode digests start with U+2063, which Claude's composer read-back drops.
# The pre-Enter proof must still accept the rest of the payload.
# shellcheck source=bin/fm-operational-input.sh
. "$ROOT/bin/fm-operational-input.sh"
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
OP_TOKEN="FMHERDROPPONG$$_$RANDOM"
op_text=
fm_operational_input_encode away-supervisor "Reply with exactly $OP_TOKEN and nothing else." op_text \
  || fail "could not encode an away-supervisor payload"
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "$op_text" 3 0.4 0.4) \
  || fail "send_text_submit failed to run an operational payload against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" = empty ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a landed U+2063 operational payload must confirm empty, got '$verdict'"
landed=0
i=0
while [ "$i" -lt 45 ]; do
  screen=$(lab pane read "$PANE" --source recent --lines 200 2>/dev/null || true)
  occurrences=$(printf '%s\n' "$screen" | grep -F -c "$OP_TOKEN" || true)
  if [ "$occurrences" -ge 2 ]; then
    landed=1
    break
  fi
  i=$((i + 1))
  sleep 1
done
[ "$landed" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: operational submit reported '$verdict' but the expected reply never rendered"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER submits a U+2063 away-supervisor payload whose read-back drops the mark"

# The fm-control exit regression: a typed slash command (/exit) makes Claude
# Code 2.1.283 render its command popup between the composer and the pane
# bottom, which pushed the composer above the old bounded proof read - the
# typed command was judged unsent, cleared, and never submitted. On 2.1.294 the
# popup's selected entry leads with `❯` and read as the composer itself, with
# the same result. The viewport capture must prove the typed /exit and submit
# it; Claude must actually exit. This scenario ends this pane's Claude process.
i=0
while [ "$i" -lt 45 ]; do
  st=$(lab agent get "$PANE" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
  case "$st" in idle|done) break ;; esac
  i=$((i + 1))
  sleep 1
done
verdict=$(fm_backend_herdr_send_text_submit "$TARGET" '/exit' 3 0.4 1.2) \
  || fail "send_text_submit failed to run the /exit submission against Claude Code ($VERSION) on $HERDR_VER"
[ "$verdict" != send-failed ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a typed /exit behind its command popup was judged unsent and cleared instead of submitted"
exited=0
i=0
while [ "$i" -lt 30 ]; do
  if ! lab agent get "$PANE" >/dev/null 2>&1; then exited=1; break; fi
  i=$((i + 1))
  sleep 1
done
[ "$exited" = 1 ] \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the /exit submission reported '$verdict' but the agent never exited"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER proves and submits a typed /exit behind its command popup"

# --- issue #16: steering blockers on a named Claude session -----------------
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$ROOT/bin/fm-task-inbox-lib.sh"
DOORBELL_STATE="$TMP_ROOT/doorbell-state"
mkdir -p "$DOORBELL_STATE"

wait_claude_idle() {  # <pane>
  local pane=$1 i=0 st screen trusted=0
  while [ "$i" -lt 60 ]; do
    screen=$(lab pane read "$pane" --source visible 2>/dev/null || true)
    case "$screen" in
      *'bypass permissions on'*)
        st=$(lab agent get "$pane" 2>/dev/null | jq -r '.result.agent.agent_status // empty')
        case "$st" in idle|done) return 0 ;; esac
        ;;
      *'Yes, I trust this folder'*)
        if [ "$trusted" = 0 ]; then
          trusted=1
          lab pane send-keys "$pane" down enter >/dev/null || return 1
        fi
        ;;
    esac
    i=$((i + 1))
    sleep 1
  done
  return 1
}

# A rung doorbell counts only when the worker acted on its record (the reply
# token rendered) and acknowledged it (the mv into handled/).
wait_doorbell_handled() {  # <pane> <record> <token>
  local i=0 screen
  while [ "$i" -lt 90 ]; do
    if [ -f "${2%/*}/handled/${2##*/}" ]; then
      screen=$(lab pane read "$1" --source recent --lines 200 2>/dev/null || true)
      case "$screen" in *"$3"*) return 0 ;; esac
    fi
    i=$((i + 1))
    sleep 1
  done
  return 1
}

WS2_JSON=$(lab workspace create --cwd "$ROOT" --label fm-submitlive-named --no-focus) \
  || fail "could not create the isolated named-session workspace"
PANE2=$(printf '%s' "$WS2_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id for the named session"
TAB2=$(printf '%s' "$WS2_JSON" | jq -er '.result.root_pane.tab_id') \
  || fail "workspace create did not return a tab id for the named session"
TARGET2="$SESSION:$PANE2"
lab pane run "$PANE2" "export FM_TASK_INBOX='$DOORBELL_STATE/live.inbox'; CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false CLAUDE_CODE_SEND_FEEDBACK=0 claude --dangerously-skip-permissions --name 'Firstmate operational input' --settings '{\"feedbackDrafts\":\"off\"}'" >/dev/null \
  || fail "could not launch a named Claude Code ($VERSION) session in the isolated Herdr pane"
wait_claude_idle "$PANE2" || fail "the named Claude Code ($VERSION) session on $HERDR_VER never rendered an idle composer"

# A named session draws its name into the composer's top rule, the label the
# incident pane carried. The doorbell wraps under it, which read as an
# unidentifiable composer, so the payload proof refused every ring.
screen=$(lab pane read "$PANE2" --source visible 2>/dev/null || true)
case "$screen" in
  *' Firstmate operational input ─'*) ;;
  *) fail "Claude Code ($VERSION) on $HERDR_VER no longer draws a session name into the composer rule; the titled-composer scenario would check nothing" ;;
esac
TOKEN2="FMHERDRTITLED$$_$RANDOM"
rec=$(fm_task_inbox_write "$DOORBELL_STATE" live "Reply with exactly $TOKEN2 and nothing else.") \
  || fail "could not write the titled-composer steering record"
line=$(fm_task_inbox_doorbell_line "$rec") || fail "could not build the doorbell line"
rule_cols=$(printf '%s\n' "$screen" | grep -o '─\+' | awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }')
[ "${#line}" -gt "$rule_cols" ] \
  || fail "the doorbell (${#line} columns) no longer wraps in a $rule_cols-column composer; the titled scenario would check nothing"
fm_task_inbox_ring herdr "$TARGET2" "$rec" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a doorbell to a titled composer did not reach the pane (ring rc=$?)"
wait_doorbell_handled "$PANE2" "$rec" "$TOKEN2" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the doorbell rang under a titled composer rule but the worker never acted on and acknowledged it"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER takes a steering doorbell that wraps under a titled composer rule"

# ctrl+o swaps the idle composer for the detailed transcript. The doorbell
# must close it with that same toggle and ring, not report "did not reach".
wait_claude_idle "$PANE2" || fail "the named Claude Code ($VERSION) session did not return to idle"
lab pane send-keys "$PANE2" ctrl+o >/dev/null || fail "could not open Claude's detailed-transcript view"
sleep 2
fm_composer_hiding_view "$(lab pane read "$PANE2" --source visible --format ansi 2>/dev/null || true)" >/dev/null \
  || fail "Claude Code ($VERSION) on $HERDR_VER: ctrl+o no longer shows the recorded detailed-transcript view; the view scenario would check nothing"
TOKEN3="FMHERDRVIEW$$_$RANDOM"
rec=$(fm_task_inbox_write "$DOORBELL_STATE" live "Reply with exactly $TOKEN3 and nothing else.") \
  || fail "could not write the transcript-view steering record"
fm_task_inbox_ring herdr "$TARGET2" "$rec" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: a doorbell to a pane in its transcript view did not reach it (ring rc=$?)"
wait_doorbell_handled "$PANE2" "$rec" "$TOKEN3" \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the doorbell rang from the transcript view but the worker never acted on and acknowledged it"
pass "live Herdr submit confirm: Claude Code ($VERSION) on $HERDR_VER leaves its detailed-transcript view with ctrl+o and takes the doorbell"

# With a background shell still running, /exit opens Claude's background-work
# picker. fm-control exit must answer it with its exit option and stop that
# shell, rather than refusing or leaving it for a human.
wait_claude_idle "$PANE2" || fail "the named Claude Code ($VERSION) session did not return to idle"
BG_MARK="fmlivebg$$_$RANDOM"
verdict=$(fm_backend_send_text_submit herdr "$TARGET2" "Use your Bash tool with run_in_background=true to run exactly: sleep 600 # $BG_MARK . Then reply with the single word started and stop." 3 0.4 0.4) \
  || fail "could not ask Claude Code ($VERSION) to start a background shell"
i=0
while [ "$i" -lt 90 ]; do
  pgrep -f "$BG_MARK" >/dev/null 2>&1 && wait_claude_idle "$PANE2" && break
  i=$((i + 1))
  sleep 1
done
pgrep -f "$BG_MARK" >/dev/null 2>&1 \
  || fail "Claude Code ($VERSION) on $HERDR_VER never started the background shell; the picker scenario would check nothing"
CONTROL_HOME=$(PATH="$ORIGINAL_PATH" "$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/control-home") \
  || fail "could not create the lab home for fm-control"
{
  echo "window=$TARGET2"
  echo "endpoint_task_id=bgexit"
  echo "worktree=$ROOT"
  echo "project=$ROOT"
  echo "harness=claude"
  echo "kind=ship"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=${PANE2%%:*}"
  echo "herdr_tab_id=$TAB2"
  echo "herdr_pane_id=$PANE2"
} > "$CONTROL_HOME/state/bgexit.meta"
out=$(env FM_HOME="$CONTROL_HOME" FM_SPAWN_NO_GUARD=1 "$ROOT/bin/fm-control.sh" bgexit exit 2>&1) \
  || fail "Claude Code ($VERSION) on $HERDR_VER: fm-control exit with a background shell running failed:"$'\n'"$out"
case "$out" in
  *"answered the Claude background-task exit picker with its exit option"*) ;;
  *) fail "Claude Code ($VERSION) on $HERDR_VER: exit never met the background-work picker; the scenario checked nothing:"$'\n'"$out" ;;
esac
case "$out" in
  *"stopped bgexit"*) ;;
  *) fail "Claude Code ($VERSION) on $HERDR_VER: exit did not report the agent stopped:"$'\n'"$out" ;;
esac
! pgrep -f "$BG_MARK" >/dev/null 2>&1 \
  || fail "Claude Code ($VERSION) on $HERDR_VER: the picker was answered but the background shell is still running"
pass "live Herdr submit confirm: fm-control exit answers Claude Code ($VERSION)'s background-work picker on $HERDR_VER and stops the shell"

[ "$CHECKED" -gt 0 ] || fail "FM_HERDR_SUBMIT_CONFIRM_LIVE=1 checked no harness"
