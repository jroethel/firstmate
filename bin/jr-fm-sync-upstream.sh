#!/usr/bin/env bash
# Merge kunchenguid/firstmate's main into the current task branch, in a worker
# copy of the project clone. It refuses on main and on a detached HEAD: the
# merge is an ordinary worker change, published by the ordinary landing
# (bin/jr-fm-land.sh), and the task branch is the only progress state.
#   jr-fm-sync-upstream.sh [--full] ["keyword"]
# A first run fetches upstream, lists the commits the branch is behind (and,
# with a keyword, upstream's open PRs and issues matching it, so you do not
# rebuild a fix that already exists), then merges upstream/main. It stops on
# conflicts; resolve them by docs/jr-fm-drift.md and rerun, which stages the
# resolved files and commits the merge. Then it runs the doc audit, lint, and
# the tests for files both sides changed, and stops. The real-Herdr tests
# (about 12 minutes) need --full. Every run is safe to repeat.
# git rerere replays a conflict resolution recorded earlier in the clone.
set -euo pipefail
cd "$(dirname "$0")/.."
PATH="$HOME/.local/bin:$PATH"  # pinned actionlint lives here (bin/fm-install-actionlint.sh)
UP=kunchenguid/firstmate
die() { echo "error: $*" >&2; exit 1; }

FULL=0 KW=
for a in "$@"; do
  case "$a" in
    --full) FULL=1 ;;
    -*) die "usage: $0 [--full] [\"keyword\"]" ;;
    *) KW=$a ;;
  esac
done
cur=$(git branch --show-current)
case "$cur" in
  main) die "on main; run this on the task's own fm/<id> branch in a worker copy" ;;
  "") die "detached HEAD; run this on the task's own fm/<id> branch in a worker copy" ;;
esac
RR=(-c rerere.enabled=true)

if [ ! -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes on $cur; commit them first"
  git fetch -q upstream
  echo "commits behind upstream: $(git rev-list --count HEAD..upstream/main)"
  git log --oneline -30 HEAD..upstream/main
  if [ -n "$KW" ]; then
    echo "--- upstream open PRs matching \"$KW\""
    gh search prs --repo "$UP" --state open "$KW" --limit 10 --json number,title,url --template '{{range .}}#{{.number}} {{.title}} {{.url}}{{"\n"}}{{end}}'
    echo "--- upstream issues matching \"$KW\""
    gh search issues --repo "$UP" "$KW" --limit 10 --json number,state,title,url --template '{{range .}}#{{.number}} [{{.state}}] {{.title}} {{.url}}{{"\n"}}{{end}}'
  else
    echo "(no keyword given: pass one to also search upstream PRs and issues)"
  fi
  git "${RR[@]}" merge --no-edit upstream/main || true
fi

# Stage what is resolved and commit the merge, then check.
if [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
  still=''
  for f in $(git diff --name-only --diff-filter=U); do
    if grep -qE '^(<<<<<<<|>>>>>>>) ' "$f"; then
      echo "conflict markers remain in: $f" >&2
      still=1
    else
      git add "$f"
    fi
  done
  [ -z "$still" ] || die "resolve the files above by docs/jr-fm-drift.md, then rerun: $0"
  git "${RR[@]}" commit --no-edit -q
  echo "merge committed."
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes on $cur"
git merge-base --is-ancestor upstream/main HEAD || die "$cur does not contain upstream/main; rerun: $0"

# Tests: files both sides changed since the merge base of fork main (the
# branch's starting point) and upstream, plus each one's own test.
base=$(git merge-base origin/main upstream/main)
overlap=$(comm -12 <(git diff --name-only "$base" origin/main | sort) <(git diff --name-only "$base" upstream/main | sort))
tests=() excl=()
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
echo "$cur contains upstream/main and passed the checks; land it as an ordinary task (bin/jr-fm-land.sh)."
