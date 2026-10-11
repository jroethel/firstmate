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

Derived from `git log --no-merges upstream/main..main` on 2026-10-11, against upstream `b675126a` (the fork's last sync merge base is `fb75c1f9`, so upstream has since moved four commits).
Each entry says what the fork carries, why, and whether it was offered upstream.
Upstream pull requests were searched by keyword on that date; "not offered" means this fork has opened no upstream pull request for it.
The only upstream pull request this fork has opened is #6926 below.
Where an unrelated upstream pull request covers the same problem, it is cited as related so a later sync can drop the fork's copy when upstream lands its own.

### The fork's own tooling

- `bin/jr-fm-*` (`jr-fm-sync-upstream.sh`, `jr-fm-land.sh`) and this ledger.
  Why: the fork carries its own commits, which upstream's `/updatefirstmate` flow does not model; the scripts make a sync and a landing one repeatable path (fork issue 8).
  Upstream: not offered, fork-specific by design; the `jr-fm-` prefix never collides with upstream's `fm-*`.
- `docs/loop/`, `docs/briefs/`, `docs/plans/`, `docs/reviews/`, and `docs/archive/`: the captain's jrit-loop planning records for the fork migration, the theming surface, and the harness-drift brief.
  Why: working records for fork work, classified in `docs/documentation-audiences.json`.
  Upstream: not offered, not product documentation.

### Features

- Bearings themes: `bin/fm-theme.sh`, the `stng` and `stng-lcars` themes, and board layout and mode support (fork pull requests 10 and 12, fork issue 1).
  Why: a themeable board with layout, type, and color axes, scoped upstream-friendly in fork issue 1.
  Upstream: not offered; the open theme issues (fork issues 2 to 7, 9, and 11) track follow-up.
- The thread-board mod (`.claude/mods/firstmate-thread-board`, the `.agents/skills/firstmate-thread-board` link) and the Calm boat slot it needs in `.claude/mods/firstmate-calm` (abdc4eea, 1cd52f88, fork issue 17).
  Why: a two-row bar above the prompt that keeps open conversation threads, with the last reply, a ticker, and a slot for Calm's boat.
  Upstream: not offered; the model keeps threads through a thread tool that upstream does not ship.

### Fixes that upstream lacks

- Background-moved Claude session lock (0981ba29, f8dc1147, e49fd6cd): a conversation moved to the background gets a new session id, so its Stop auto-arm stood down silently against a live front-end owner.
  Offered upstream as https://github.com/kunchenguid/firstmate/pull/6926, still open: the fork carries it ahead of upstream (`fm_session_lock_handed_off_to_self` in `bin/fm-session-lock-lib.sh`, its `bin/fm-lock.sh` and Stop auto-arm callers, and the live guard `tests/fm-session-lock-background-move-live-e2e.test.sh`).
  Related but not the same fix: https://github.com/kunchenguid/firstmate/pull/6719 (closed).
  Drop the fork's copy at the sync after upstream merges #6926.
- Auto-arm never defers to another session's claim (a57500be, 8fe6aab6, 04e10f6d, ffc7c988): a claim records the session lock it was taken under, so a session that ended while its Stop hook tree kept running no longer blocks the replacement session from arming its own cycle.
  Why: found live, the finished worker never woke the current session.
  Upstream: not offered.
  Related, same symptom with a different mechanism (descent from the lock holder): https://github.com/kunchenguid/firstmate/pull/5939 (open); if it lands, reconcile the two at that sync rather than carrying both.
- Claude workers on Herdr: steering and exit (b2885701, fork issue 16): a session name drawn into the composer rule, the slash-command menu's leading glyph, Claude's background-work exit picker, and the ctrl+o transcript view each blocked `fm-send` doorbells or `fm-control exit` and `relaunch` on real Claude Code 2.1.294.
  Why: every Claude worker on Herdr was unsteerable and could not be relaunched.
  Upstream: not offered; searches for the composer, picker, and transcript-view symptoms found no upstream pull request.
- Remote job identity by kernel start ticks (09ae140e): `ps lstart` moves under WSL2 clock drift, so a live remote job worker stopped matching its own record and its job was reclaimed.
  Upstream: not offered by the fork; several open upstream pull requests fix the same problem, for example https://github.com/kunchenguid/firstmate/pull/6440, https://github.com/kunchenguid/firstmate/pull/5632, and https://github.com/kunchenguid/firstmate/pull/5395.
  Drop the fork's copy when one of them lands, taking upstream's version.
- Repeatable `--allow-red` merge waiver (aa08e3b9): `fm-pr-merge.sh` accepts the flag more than once, one exact check name each.
  Why: a merge with several known-red checks could not be waived in one call.
  Upstream: not offered by the fork; https://github.com/kunchenguid/firstmate/pull/5224 and https://github.com/kunchenguid/firstmate/pull/5232 are open and propose the same, so take upstream's at the sync that lands either.

### CI and test hygiene

- Herdr timing JSON in the CI aggregate (1dc669c4): the aggregate's artifact glob skipped the Herdr lane's nested timing file.
  Upstream: not offered.
- Dispatch tests ignore ambient `DISABLE_AUTOUPDATER` and `TYPESAFE_API_KEY` (167c7ae7, fork issue 15): `tests/fm-dispatch-resolve.test.sh` and `tests/fm-spawn-dispatch-profile.test.sh` failed whenever either variable was exported.
  Upstream: not offered.
- Event-based waits instead of wall-clock budgets in `tests/fm-remote-secondmate-lifecycle-e2e.test.sh` (b9a36f56) and a structure-based watcher stop and stamp order in `tests/fm-home-summary-refresh.test.sh` (c88f677a): both failed on any slower runner.
  Upstream: not offered; upstream pull requests https://github.com/kunchenguid/firstmate/pull/6468 and https://github.com/kunchenguid/firstmate/pull/6471 touch the same home-summary tests (open), so prefer theirs when they land.
- Supervision-host cases stop their processes when each ends (#14) and the test-only parts of the real-Herdr CI fix (#13): leftover watchers starved later cases of CPU, and the focus-flash sampler raced.
  Upstream: not offered; the product half of #13 was dropped for upstream's resume default (see above).

## Pending harness-drift items

From the harness-drift brief (`docs/briefs/2026-10-07.molt-harness-drift-brief.md`): prose patch, `.pi/skills` symlink, decision-hold removal.
Its composer fix (fork issue 16) and test-hygiene patch (fork issue 15) are done and listed above.
The rest waits on the brief's own issue once its scope is agreed.
