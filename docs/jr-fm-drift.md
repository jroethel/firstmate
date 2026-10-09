# jr-fm drift ledger

Where this fork (jroethel/firstmate) deliberately differs from kunchenguid/firstmate, and every upstream decision it accepted over its own.
Read this before resolving a sync conflict, and add a row whenever a sync forces a choice.

## Sync runbook

One fork, one clone: `jroethel/firstmate` is a public GitHub fork of `kunchenguid/firstmate`, and its main has one writer, the project clone `projects/firstmate`, through `bin/jr-fm-land.sh`.
An upstream sync is an ordinary local-only worker task on the Firstmate project, never a step run in a home.

1. In the worker copy, on the task's own `fm/<id>` branch, run `bin/jr-fm-sync-upstream.sh "keyword"`; it refuses on `main`.
   It lists what upstream added, searches upstream's open PRs and issues for the keyword so you do not rebuild a fix that already exists, and merges `upstream/main` into the branch.
2. It stops on conflicts, naming the files; resolve them using the decisions below, add a row here for each new choice, and rerun the script, which stages the resolved files and commits the merge.
   git rerere replays resolutions recorded earlier in the clone's shared `.git/rr-cache`.
3. It then runs the doc and lint checks plus the tests for every file both sides changed, and stops.
   The real-Herdr tests (about 12 minutes) run only with `--full`.
4. Firstmate lands the approved branch with `bin/jr-fm-land.sh <id>`, the landing for every Firstmate change, not only syncs.
   It fetches origin, refuses unless `origin/main` is an ancestor of the task branch, fast-forwards the clone's main through `bin/fm-merge-local.sh`, pushes it to origin, and prints the `/updatefirstmate` reminder.

Outside the scripts:

- Every home, on every host, is pull-only: its tracked files change only through `/updatefirstmate` (it runs `bin/fm-update.sh`; reread `AGENTS.md` when it says so), never a raw `git pull`, a commit, a merge, or a push.
- The delta against upstream is the compare view <https://github.com/kunchenguid/firstmate/compare/main...jroethel:main>.
- GitHub's Sync fork button, the `merge-upstream` API, and `gh repo sync --force` are never used: the first two stop on any conflict and run none of the worker merge's checks, and the last hard-resets fork main to upstream.
- Tool prerequisites: `bin/fm-install-actionlint.sh ~/.local/bin` (the script puts that on PATH); `ruby` for `tests/fm-test-run.test.sh`.

## Accepted upstream over the fork

### 2026-10-07 - resume under session-lock contention

- Fork change (#13, d0ad4f8b): a recovering spawn waited up to 120 s (`attempts=1200`) for the shared Herdr presentation lock, so homes resuming together queued instead of refusing.
- Upstream change (#6649, 23e71b3d): a resume refuses by default; `fm-spawn.sh --herdr-resume-lock-wait` opts into waiting.
- Decision: take upstream's default, so `bin/fm-spawn.sh` and `docs/herdr-backend.md` match upstream for this feature and carry no fork delta.
- The fork's own test changes for it (#13: a held-lock queueing case and a read-only tmp cleanup) are dropped too, so `tests/fm-backend-herdr-presentation-e2e.test.sh` matches upstream and upstream's own lock-wait tests cover the behavior.
- Consequence: a real resume that meets a held lock refuses unless the caller passes the flag.
- Revisit if: homes resuming together after a restart start refusing in practice; then the fix is passing the flag at the restart call site, not re-forking the default.

## Fork-only changes still carried

- `bin/jr-fm-*`: the captain's own scripts, prefix `jr-fm-`, never colliding with upstream's `fm-*`.
- Everything in `git log upstream/main..main`: at last sync, the Bearings themes (#10, #12), the thread-board mod, and the test-only parts of the CI fixes (#13, #14).
- The background-move session-lock fix, offered upstream as https://github.com/kunchenguid/firstmate/pull/6926 and still unmerged: the fork carries it ahead of upstream (`fm_session_lock_handed_off_to_self` in `bin/fm-session-lock-lib.sh`, its `bin/fm-lock.sh` and Stop auto-arm callers, and the live guard `tests/fm-session-lock-background-move-live-e2e.test.sh`).
  Drop it at the sync after upstream merges it.
- Pending from the harness-drift brief (`docs/briefs/2026-10-07.molt-harness-drift-brief.md`): prose patch, `.pi/skills` symlink, decision-hold removal, composer fix.
  Filed 2026-10-07: the composer fix as #16 and the environment leak below as #15; the rest waits on the brief's own issue once its scope is agreed.

## Known environment leak

`tests/fm-spawn-dispatch-profile.test.sh` and `tests/fm-dispatch-resolve.test.sh` fail when `DISABLE_AUTOUPDATER` or `TYPESAFE_API_KEY` are exported; run them with both unset until the brief's test-hygiene patch lands.
