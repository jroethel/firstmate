#!/usr/bin/env bash
# Merge upstream/main into this fork's main on a scratch branch, check it, then
# fast-forward main. Never pushes: the push is the captain's to fire.
#   jr-fm-sync-upstream.sh           start: fetch, branch, merge
#   jr-fm-sync-upstream.sh --finish  after resolving conflicts and committing: check, ff main
# git rerere (enabled here) replays a conflict resolution recorded earlier.
set -euo pipefail
cd "$(dirname "$0")/.."
BR=sync-upstream

if [ "${1:-}" = --finish ]; then
  [ "$(git branch --show-current)" = "$BR" ] || { echo "error: not on $BR" >&2; exit 1; }
  [ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "error: uncommitted changes; finish the merge commit first" >&2; exit 1; }
  git merge-base --is-ancestor upstream/main HEAD || { echo "error: $BR does not contain upstream/main" >&2; exit 1; }
  bash bin/fm-doc-audience-check.sh
  bash bin/fm-lint.sh
  git switch main
  git merge --ff-only "$BR"
  git branch -d "$BR"
  echo "synced. Run the owning tests, then push yourself: git push origin main"
  exit 0
fi

git config rerere.enabled true
[ "$(git branch --show-current)" = main ] || { echo "error: start from main" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || { echo "error: uncommitted changes on main; commit or stash first" >&2; exit 1; }
git fetch upstream
git rev-list --count main..upstream/main | sed 's/^/commits behind upstream: /'
git switch -c "$BR"
if git merge upstream/main; then
  echo "clean merge. Next: bin/jr-fm-sync-upstream.sh --finish"
else
  echo "conflicts above. Resolve, git add, git commit --no-edit, then: bin/jr-fm-sync-upstream.sh --finish" >&2
  exit 1
fi
