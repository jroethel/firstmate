# Import triage, 2026-10-07

Import sweep run by loop-setup on jroethel/firstmate, skipping `projects/` and the governed lanes (`docs/briefs/`, `docs/plans/`, `docs/reviews/`, `docs/loop/`).

| source-doc             | item                                   | class | verdict     | evidence | action              |
| ---------------------- | -------------------------------------- | ----- | ----------- | -------- | ------------------- |
| docs/jr-fm-drift.md    | Fix the dispatch-test env leak         | issue | outstanding | -        | file, keep (living) |
| docs/jr-fm-drift.md    | Fix steering blocked by composer/exit  | issue | outstanding | -        | file, keep (living) |
| docs/jr-fm-drift.md    | Apply the molt prose patch             | idea  | outstanding | E1       | drop                |
| docs/jr-fm-drift.md    | Add `.pi/skills` for Pi skill listing  | idea  | outstanding | E1       | drop                |
| docs/jr-fm-drift.md    | Remove the decision-hold shim          | idea  | outstanding | E2       | drop                |
| VISION.md, GROK_BOT.md | upstream reference prose               | -     | noise       | E3       | leave in place      |
| docs/*.md (about 60)   | upstream reference docs                | -     | noise       | E3       | leave in place      |

Evidence for dropped rows:

- E1: the item belongs to `docs/briefs/2026-10-07.molt-harness-drift-brief.md`, which is filed as one issue with `/loop-track` once its scope is agreed; filing it here too would track the work twice.
- E2: upstream's own stub `.agents/skills/decision-hold-lifecycle/SKILL.md` says it will be removed one release after the collapse, so a fork-side removal only adds a merge conflict.
- E3: reference material identical to kunchenguid/firstmate, or upstream text carrying fork edits, with no actionable item.

Filed: #15 (env leak), #16 (composer and exit-dialog fix).
