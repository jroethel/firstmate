#!/usr/bin/env bash
# Land an approved local-only Firstmate task and publish it: the one writer of
# fork main (docs/jr-fm-drift.md). Fetches origin in the project clone, refuses
# unless origin/main is an ancestor of the task's recorded ship branch (so a
# branch the fork has moved past never lands), runs bin/fm-merge-local.sh
# <task-id> to fast-forward the clone's main, pushes that main to origin without
# forcing, and prints the /updatefirstmate reminder for the home.
# The project, ship branch, and approval checks come from fm-merge-local.sh and
# the task record state/<task-id>.meta, read the same way it reads them.
# Usage: jr-fm-land.sh <task-id>
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
die() { echo "error: $*" >&2; exit 1; }

if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then die "usage: $0 <task-id>"; fi
ID=$1 META="$STATE/$1.meta"
[ -f "$META" ] || die "no meta for task $ID at $META"
PROJ=$(grep '^project=' "$META" | cut -d= -f2- || true)
BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
[ -d "$PROJ" ] || die "task $ID records no project clone"

git -C "$PROJ" fetch -q origin
git -C "$PROJ" merge-base --is-ancestor origin/main "refs/heads/$BRANCH" \
  || die "REFUSED: $BRANCH does not contain origin/main; have the worker rebase it onto origin/main, then retry"
"$SCRIPT_DIR/fm-merge-local.sh" "$ID"
git -C "$PROJ" push -q origin main
echo "pushed main to origin; in the running home, run /updatefirstmate (reread AGENTS.md when it says so)"
