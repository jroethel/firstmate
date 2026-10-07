#!/usr/bin/env bash
# Sync this fork's main with kunchenguid/firstmate. Run it, read the last line,
# and run it again if it says to; it resumes wherever it stopped.
#   jr-fm-sync-upstream.sh [--push] [--quick]
# Stops, in order, at: dirty tree, unresolved conflicts, failed checks.
#   fetch -> merge upstream/main on scratch branch sync-upstream -> (you resolve
#   conflicts, then rerun) -> doc + lint + the tests that cover files both sides
#   touched -> fast-forward main -> push only with --push.
# --quick skips the tests that need real Herdr (about 12 minutes); a plain run
# includes them. git rerere replays a conflict resolution recorded earlier.
set -euo pipefail
cd "$(dirname "$0")/.."
PATH="$HOME/.local/bin:$PATH"  # pinned actionlint lives here (bin/fm-install-actionlint.sh)
BR=sync-upstream PUSH=0 QUICK=0
for a in "$@"; do
  case "$a" in
    --push) PUSH=1 ;;
    --quick) QUICK=1 ;;
    *) echo "usage: $0 [--push] [--quick]" >&2; exit 2 ;;
  esac
done
die() { echo "error: $*" >&2; exit 1; }
cur=$(git branch --show-current)

push_if_asked() {
  local ahead
  ahead=$(git rev-list --count origin/main..main)
  [ "$ahead" -gt 0 ] || { echo "origin/main is current."; return 0; }
  if [ "$PUSH" = 1 ]; then
    git push origin main
    echo "pushed. Other hosts: git pull --ff-only origin main"
  else
    echo "main is $ahead commit(s) ahead of origin. Rerun with --push to publish."
  fi
}

if [ "$cur" = main ]; then
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes on main; commit or stash first"
  git config rerere.enabled true
  git fetch -q upstream
  git fetch -q origin
  behind=$(git rev-list --count main..upstream/main)
  echo "commits behind upstream: $behind"
  if [ "$behind" -eq 0 ]; then
    echo "already up to date with upstream."
    push_if_asked
    exit 0
  fi
  git show-ref --verify --quiet "refs/heads/$BR" && die "$BR exists but you are on main; git switch $BR to resume it, or git branch -D $BR to drop it"
  git switch -c "$BR"
  git merge upstream/main || true
elif [ "$cur" != "$BR" ]; then
  die "on $cur; git switch main first"
fi

# On $BR: stage what is resolved, commit the merge, then check and finish.
if [ -f "$(git rev-parse --git-path MERGE_HEAD)" ]; then
  still=
  for f in $(git diff --name-only --diff-filter=U); do
    if grep -qE '^(<<<<<<<|>>>>>>>) ' "$f"; then
      echo "conflict markers remain in: $f" >&2
      still=1
    else
      git add "$f"
    fi
  done
  [ -z "$still" ] || die "resolve the files above, then rerun $0"
  git commit --no-edit -q
  echo "merge committed."
fi
[ -z "$(git status --porcelain --untracked-files=no)" ] || die "uncommitted changes on $BR"
git merge-base --is-ancestor upstream/main HEAD || die "$BR does not contain upstream/main"

# Tests: files both sides changed since the merge base, plus each one's own test.
base=$(git merge-base main upstream/main)
overlap=$(comm -12 <(git diff --name-only "$base" main | sort) <(git diff --name-only "$base" upstream/main | sort))
tests=()
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
  # DISABLE_AUTOUPDATER and TYPESAFE_API_KEY leak into the dispatch tests (docs/jr-fm-drift.md)
  excl=()
  [ "$QUICK" = 0 ] || excl=(--exclude-family real-herdr-gated)
  env -u DISABLE_AUTOUPDATER -u TYPESAFE_API_KEY bash bin/fm-test-run.sh ${excl[@]+"${excl[@]}"} "${tests[@]}"
fi

git switch main
git merge --ff-only "$BR"
git branch -d "$BR"
echo "main synced to upstream."
push_if_asked
