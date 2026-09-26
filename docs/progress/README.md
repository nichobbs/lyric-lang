# Progress log — one file per entry

Each shipped change that needs a progress note gets **one Markdown file in
this directory**, instead of an entry appended to
`docs/10-bootstrap-progress.md`. The log section of that file (everything from
"Active session decisions" to the end) is the **frozen historical archive**:
do not append to it. Its status sections at the top (bootstrap stages, the
status table against `05-implementation-plan.md`) stay live, and are still
where a shipped item's tier status is updated in place.

## Why per-file

Every PR used to append its entry to the end of the same file, so any two PRs
in flight conflicted there, and each collision forced a rebase and a full CI
rerun. The decision log moved to one file per entry for the same reason
(`docs/decisions/README.md`). Two PRs now add two different files and never
touch the same bytes.

## Adding an entry

1. Create `docs/progress/<YYYY-MM-DD>-<kebab-slug>.md`, dated the day the
   change is written, e.g. `docs/progress/2026-09-26-native-process-run.md`.
   The date orders entries; there is no number to allocate, so nothing can
   collide.
2. Use one top-level heading with the title and the PR or issue, then the
   body, in the same shape as the archive's entries:

   ```markdown
   # Short description of what shipped (#PR)

   What changed, what it fixes, how it was verified. Link the decision
   entry when there is one (D-progress-NNN).
   ```

3. If the change also moves an item in the status sections of
   `docs/10-bootstrap-progress.md`, edit that section in place as before.

Two entries written the same day only need different slugs.
