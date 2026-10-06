# Loop pointer

This file is the machine surface: the line-anchored keys below are what the loop skills read.
Prose conventions live in the sibling `docs/loop/conventions.md`.

pointer-version: 1
tracker: github
autonomy-default: auto
rubix-autorun: on
handoffs-home: docs/handoffs/
briefs-home: docs/briefs/
plans-home: docs/plans/
reviews-home: docs/reviews/
archive-home: docs/archive/

## Lanes

| Lane      | Home                               | How                                             |
| ---       | ---                                | ---                                             |
| Issues    | the tracker, open, no `idea`       | Read with `gh` or `glab` directly; no mirror.   |
| Backlog   | the tracker, label `idea`          | Read with `gh` or `glab` directly; no mirror.   |
| Wayfinder | the tracker, label `wayfinder:map` | Read with `gh` or `glab` directly; no mirror.   |
| Handoffs  | `docs/handoffs/`                   | Per unit and per session.                       |
| Briefs    | `docs/briefs/`                     | One file per brief.                             |
| Plans     | `docs/plans/`                      | One file per plan.                              |
| Reviews   | `docs/reviews/`                    | One file per review run.                        |
| Archive   | `docs/archive/`                    | Moved work lands here.                          |

Files in the doc-tree homes above share one filename grammar: `YYYY-MM-DD.<descriptor>.md`, date first, dot-separated, the descriptor a short slug with optional tracker-token segments (e.g. `.I6` for issue 6).
The loop-drive resume pointer (`YYYY-MM-DD.<unit-slug>.resume.md`) and the loop-auto batch-review journal (`YYYY-MM-DD.<tokens>.<slug>-batch-review.md`) are the two fixed instances of that grammar.

The tracker is the single source of truth; no generated mirror files exist.
Claim, done, status, and next-eligible run through the receipt helper shipped inside the loop-drive skill.
