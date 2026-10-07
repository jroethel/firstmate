# jr-fm drift ledger

Where this fork (jroethel/firstmate) deliberately differs from kunchenguid/firstmate, and every upstream decision it accepted over its own.
Read this before resolving a sync conflict, and add a row whenever a sync forces a choice.

## Sync runbook

One command: `bin/jr-fm-sync-upstream.sh [--push] [--quick]`.
Run it whenever you want upstream's changes, from `main` with a clean tree and an idle fleet (a live session re-reads `AGENTS.md`).
It is safe to rerun at any point and resumes where it stopped; it says "already up to date" when there is nothing to pull.

It fetches, merges `upstream/main` on scratch branch `sync-upstream`, runs the doc and lint checks plus the tests for every file both sides changed, fast-forwards `main`, and pushes only when you pass `--push`.
`--quick` skips the real-Herdr tests (about 12 minutes).

The only time it needs you: it stops on conflicts, naming the files.
Edit them using the decisions below, then rerun the same command; it stages the resolved files and commits the merge itself.

Outside the script:

- Other hosts: `git pull --ff-only origin main`.
- Running firstmate home: `/updatefirstmate` (it runs `bin/fm-update.sh`; reread `AGENTS.md` when it says so).
- Tool prerequisites: `bin/fm-install-actionlint.sh ~/.local/bin` (the script puts that on PATH); `ruby` for `tests/fm-test-run.test.sh`.

## Accepted upstream over the fork

### 2026-10-07 - resume under session-lock contention

- Fork change (#13, d0ad4f8b): a recovering spawn waited up to 120 s (`attempts=1200`) for the shared Herdr presentation lock, so homes resuming together queued instead of refusing.
- Upstream change (#6649, 23e71b3d): a resume refuses by default; `fm-spawn.sh --herdr-resume-lock-wait` opts into waiting.
- Decision: take upstream's default, so `bin/fm-spawn.sh` and `docs/herdr-backend.md` match upstream for this feature and carry no fork delta.
- What kept the fork's CI fix: `tests/fm-backend-herdr-presentation-e2e.test.sh`, concurrent cross-home recovery case, now passes `--herdr-resume-lock-wait` to both resumes.
- Consequence: a real resume that meets a held lock refuses unless the caller passes the flag.
- Revisit if: homes resuming together after a restart start refusing in practice; then the fix is passing the flag at the restart call site, not re-forking the default.

## Fork-only changes still carried

- `bin/jr-fm-*`: the captain's own scripts, prefix `jr-fm-`, never colliding with upstream's `fm-*`.
- Everything in `git log upstream/main..main`: at last sync, the Bearings themes (#10, #12), the thread-board mod, and the test-only parts of the CI fixes (#13, #14).
- Pending from the harness-drift brief (`docs/briefs/2026-10-07.molt-harness-drift-brief.md`): prose patch, `.pi/skills` symlink, decision-hold removal, composer fix.

## Known environment leak

`tests/fm-spawn-dispatch-profile.test.sh` and `tests/fm-dispatch-resolve.test.sh` fail when `DISABLE_AUTOUPDATER` or `TYPESAFE_API_KEY` are exported; run them with both unset until the brief's test-hygiene patch lands.
