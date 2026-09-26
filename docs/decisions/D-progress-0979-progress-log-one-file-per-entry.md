# D-progress-979 — Progress log entries are one file per entry in `docs/progress/`

**Status:** accepted

## Problem

`docs/10-bootstrap-progress.md` mixed two things: status sections that are
edited in place (bootstrap stages, the status table against
`docs/05-implementation-plan.md`) and a running log that every PR appended to
at end of file. Any two PRs in flight conflicted on that append. #7305 hit the
conflict on almost every rebase while `main` moved, and each resolution cost a
push and a full CI run.

## Decision

Apply the decision log's fix (`docs/decisions/README.md`) to the progress log:

- The log section of `docs/10-bootstrap-progress.md` ("Active session
  decisions" to end of file) is frozen as the historical archive and is not
  appended to.
- New entries are one file each in `docs/progress/`, named
  `<YYYY-MM-DD>-<kebab-slug>.md`. A date orders them and needs no allocation,
  so there is no numbering race to reconcile (unlike `D-progress-N`).
- The status sections at the top of `docs/10-bootstrap-progress.md` stay live
  and are still updated in place when an item's tier status changes.

The archive is not split into per-entry files: its 700-odd entries have no
stable ids or consistent dates, and moving them would rewrite a 35k-line file
for no conflict benefit, since nothing appends to it any more.

No `merge=union` attribute is added for the file (the decision archive has
one): its status sections are edited in place, and a union merge of two
in-place edits would silently keep both versions of the edited lines.

CLAUDE.md's docs-sync rule, the README pointer, and `docs/progress/README.md`
describe the convention.
