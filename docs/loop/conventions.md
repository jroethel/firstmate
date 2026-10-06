# Loop conventions

Machine-readable keys live in `docs/loop/pointer.md`; this file is the prose surface.
The tracker for this repo is GitHub issues on jroethel/firstmate.

## agent: labels

Exactly one of these is active on an issue at a time:

- `agent:todo` - open and unclaimed.
- `agent:working` - claimed and in progress.
- `agent:needs-input` - blocked on a human answer.
- `agent:review` - work done, awaiting review.
- `agent:done` - reachable only through the receipt helper's `done` verb.

Other labels: `idea` (parked backlog item, not active work) and `wayfinder:map` (wayfinder mapping item).

## Filename grammar

Files in `docs/handoffs/`, `docs/briefs/`, `docs/plans/`, `docs/reviews/`, and `docs/archive/` are named `YYYY-MM-DD.<descriptor>.md`.
The date comes first, segments are dot-separated, and the descriptor is a short slug with optional tracker-token segments (for example `.I6` for issue 6).

## Archive and graduation

Finished or superseded work moves into `docs/archive/` with its name unchanged.
An `idea` graduates by dropping the `idea` label and gaining `agent:todo`.

## Verbose announce

Before acting, each loop skill states in one line which pointer keys and tracker reads it resolved.
