#!/usr/bin/env bash
# Sync this fork's main with kunchenguid/firstmate, in three ordered steps.
# Run with no argument to see which step is next. Each step refuses to run
# before the one it depends on, and every step is safe to rerun.
#   jr-fm-sync-upstream.sh 1 ["keyword"]  check: what upstream already has (open PRs and issues
#                                         matching the keyword, commits we are behind)
#   jr-fm-sync-upstream.sh 2 [--full]     sync: merge upstream/main on scratch branch sync-upstream,
#                                         run doc + lint + tests for files both sides changed,
#                                         fast-forward main. Stops on conflicts; fix, rerun 2.
#                                         The real-Herdr tests (about 12 minutes) need --full.
#   jr-fm-sync-upstream.sh 3              publish: git push origin main, then reminders. Yours to fire.
# git rerere replays a conflict resolution recorded earlier.
set -euo pipefail
cd "$(dirname "$0")/.."
PATH="$HOME/.local/bin:$PATH"  # pinned actionlint lives here (bin/fm-install-actionlint.sh)
BR=sync-upstream UP=kunchenguid/firstmate
STATE=$(git rev-parse --git-path jr-fm-sync)
die() { echo "error: $*" >&2; exit 1; }
done_step() { [ -e "$STATE/$1" ]; }
mark() { mkdir -p "$STATE"; : > "$STATE/$1"; }
need() { done_step "$1" || die "step $1 has not been run since the last publish; run: $0 $1"; }

status() {
  local n next=
  for n in 1 2 3; do
    if done_step "$n"; then echo "  [x] step $n"; else echo "  [ ] step $n"; [ -n "$next" ] || next=$n; fi
  done
  [ -z "$next" ] || echo "next: $0 $next"
}

step1() {
  git fetch -q upstream
  local behind
  behind=$(git rev-list --count main..upstream/main)
  echo "commits behind upstream: $behind"
  git log --oneline main..upstream/main | head -30
  if [ -n "${1:-}" ]; then
    echo "--- upstream open PRs matching \"$1\""
    gh search prs --repo "$UP" --state open "$1" --limit 10 --json number,title,url --template '{{range .}}#{{.number}} {{.title}} {{.url}}{{"\n"}}{{end}}'
    echo "--- upstream issues matching \"$1\""
    gh search issues --repo "$UP" "$1" --limit 10 --json number,state,title,url --template '{{range .}}#{{.number}} [{{.state}}] {{.title}} {{.url}}{{"\n"}}{{end}}'
  else
    echo "(no keyword given: pass one to also search upstream PRs and issues)"
  fi
  mark 1
}

step2() {
  need 1
  local FULL=0 cur
  [ "${1:-}" != --full ] || FULL=1
  cur=$(git branch --show-current)
  if [ "$cur" = main ]; then
    [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes on main; commit or stash first"
    git config rerere.enabled true
    git fetch -q upstream
    if [ "$(git rev-list --count main..upstream/main)" -eq 0 ]; then
      echo "already up to date with upstream."
      mark 2
      return 0
    fi
    git show-ref --verify --quiet "refs/heads/$BR" && die "$BR exists but you are on main; git switch $BR to resume it, or git branch -D $BR to drop it"
    git switch -c "$BR"
    git merge upstream/main || true
  elif [ "$cur" != "$BR" ]; then
    die "on $cur; git switch main first"
  fi

  # On $BR: stage what is resolved, commit the merge, then check and finish.
  if [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
    local still='' f
    for f in $(git diff --name-only --diff-filter=U); do
      if grep -qE '^(<<<<<<<|>>>>>>>) ' "$f"; then
        echo "conflict markers remain in: $f" >&2
        still=1
      else
        git add "$f"
      fi
    done
    [ -z "$still" ] || die "resolve the files above, then rerun: $0 2"
    git commit --no-edit -q
    echo "merge committed."
  fi
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes on $BR"
  git merge-base --is-ancestor upstream/main HEAD || die "$BR does not contain upstream/main"

  # Tests: files both sides changed since the merge base, plus each one's own test.
  local base overlap tests=() t excl=()
  base=$(git merge-base main upstream/main)
  overlap=$(comm -12 <(git diff --name-only "$base" main | sort) <(git diff --name-only "$base" upstream/main | sort))
  for f in $overlap; do
    case "$f" in
      tests/*.test.sh) t=$f ;;
      bin/*.sh) t=tests/$(basename "$f" .sh).test.sh ;;
      *) continue ;;
    esac
    [ -f "$t" ] && tests+=("$t")
  done
  echo "files both sides changed: ${overlap:-none}"
  bash bin/fm-doc-audience-check.sh
  bash bin/fm-lint.sh
  if [ "${#tests[@]}" -gt 0 ]; then
    [ "$FULL" = 1 ] || excl=(--exclude-family real-herdr-gated)
    # DISABLE_AUTOUPDATER and TYPESAFE_API_KEY leak into the dispatch tests (docs/jr-fm-drift.md)
    env -u DISABLE_AUTOUPDATER -u TYPESAFE_API_KEY bash bin/fm-test-run.sh ${excl[@]+"${excl[@]}"} "${tests[@]}"
  fi

  git switch main
  git merge --ff-only "$BR"
  git branch -d "$BR"
  echo "main synced to upstream."
  mark 2
}

step3() {
  need 2
  [ "$(git branch --show-current)" = main ] || die "on $(git branch --show-current); git switch main first"
  git fetch -q origin
  local ahead
  ahead=$(git rev-list --count origin/main..main)
  if [ "$ahead" -gt 0 ]; then
    git push origin main
    echo "pushed $ahead commit(s)."
  else
    echo "origin/main is already current."
  fi
  rm -rf "$STATE"
  echo "Other hosts: git pull --ff-only origin main"
  echo "Running firstmate session: /updatefirstmate (reread AGENTS.md when it says so)"
}

case "${1:-}" in
  1) shift; step1 "$@" ;;
  2) shift; step2 "$@" ;;
  3) step3 ;;
  "") status ;;
  *) die "usage: $0 [1 [keyword] | 2 [--full] | 3]" ;;
esac
