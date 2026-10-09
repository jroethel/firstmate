#!/usr/bin/env bash
# Behavior tests for bin/jr-fm-land.sh against throwaway local repositories:
# a bare origin standing in for the fork, a project clone, and a task record.
# The refuse path leaves the clone and origin untouched when origin/main is not
# an ancestor of the task branch; the happy path fast-forwards the clone's main,
# pushes it to origin, and prints the /updatefirstmate reminder.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAND="$ROOT/bin/jr-fm-land.sh"
TMP_ROOT=$(fm_test_tmproot jr-fm-land)
fm_git_identity

# Echoes "<home>|<clone>|<origin>" for a clone whose main equals origin/main and
# a task <id> recorded on branch fm/<id> one commit ahead of that main.
make_world() {  # <name> <id>
  local dir="$TMP_ROOT/$1" id=$2
  mkdir -p "$dir/home/state" "$dir/home/data"
  fm_git_init_commit "$dir/clone"
  fm_git_add_origin "$dir/clone" "$dir/origin.git"
  git -C "$dir/clone" fetch -q origin
  git -C "$dir/clone" checkout -qb "fm/$id"
  printf 'change\n' > "$dir/clone/change"
  git -C "$dir/clone" add change
  git -C "$dir/clone" commit -qm change
  git -C "$dir/clone" checkout -q main
  fm_write_meta "$dir/home/state/$id.meta" "project=$dir/clone" mode=local-only "branch=fm/$id"
  printf '%s\n' "$dir/home|$dir/clone|$dir/origin.git"
}

land() {  # <home> <id>
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" "$LAND" "$2" 2>&1
}

test_refuses_when_origin_main_moved_past_the_branch() {
  local world home clone origin before_clone before_origin out code=0
  world=$(make_world refuse land-r1)
  IFS='|' read -r home clone origin <<<"$world"
  # Another landing moved fork main after the task branch was cut.
  git clone -q "$origin" "$TMP_ROOT/refuse/other"
  printf 'other\n' > "$TMP_ROOT/refuse/other/other"
  git -C "$TMP_ROOT/refuse/other" add other
  git -C "$TMP_ROOT/refuse/other" commit -qm other
  git -C "$TMP_ROOT/refuse/other" push -q origin main
  before_clone=$(git -C "$clone" rev-parse main)
  before_origin=$(git -C "$origin" rev-parse main)
  out=$(land "$home" land-r1) || code=$?
  expect_code 1 "$code" "landing a branch behind origin/main"
  assert_contains "$out" "REFUSED: fm/land-r1 does not contain origin/main" "refusal did not name the branch"
  assert_equals "$before_clone" "$(git -C "$clone" rev-parse main)" "refused landing moved the clone's main"
  assert_equals "$before_origin" "$(git -C "$origin" rev-parse main)" "refused landing moved origin main"
  pass "jr-fm-land: refuses a branch that does not contain origin/main and changes nothing"
}

test_lands_pushes_and_reminds() {
  local world home clone origin head out
  world=$(make_world happy land-h1)
  IFS='|' read -r home clone origin <<<"$world"
  head=$(git -C "$clone" rev-parse fm/land-h1)
  out=$(land "$home" land-h1) || fail "landing a current branch failed: $out"
  assert_equals "$head" "$(git -C "$clone" rev-parse main)" "clone main was not fast-forwarded to the task branch"
  assert_equals "$head" "$(git -C "$origin" rev-parse main)" "origin main was not pushed"
  assert_contains "$out" "/updatefirstmate" "landing did not print the /updatefirstmate reminder"
  pass "jr-fm-land: fast-forwards the clone's main, pushes it, and prints the reminder"
}

test_refuses_when_origin_main_moved_past_the_branch
test_lands_pushes_and_reminds
echo "# all jr-fm-land tests passed"
