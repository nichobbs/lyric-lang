# Decision log — one file per entry

New design decisions are recorded here as **one Markdown file per decision**,
instead of appending to the single `docs/03-decision-log.md`. That file is the
**frozen historical archive** (entries up to `D-progress-885` and the legacy
`DNNN` / `D-N-NNN` decisions); do not append to it.

## Why per-file

Every PR used to append a `D-progress-N` entry to the *same* file at
end-of-file, so any two in-flight PRs conflicted there — and each collision
forced a rebase + renumber + a full (multi-hour) CI rebuild, which fast-moving
`main` then out-churned. One file per entry means two PRs add two *different*
files and never touch the same bytes, so an append is never a conflict and a
green PR merges without a rebuild.

(A `.gitattributes merge=union` on the archive remains as belt-and-suspenders
for the frozen file; with per-file entries there is nothing left to append to
it.)

## Adding a decision

1. Pick the next number: one past the highest id across **all** of: this
   directory on `main`, the archive (`docs/03-decision-log.md`), and every open
   PR that adds a file here (search the open PRs for `docs/decisions/`). Ids use
   the same prefix family as their neighbours (`D<n>` for design decisions,
   `D-progress-<n>` for the legacy progress series).
2. Create `docs/decisions/D-progress-<zero-padded-4-digit-N>-<kebab-slug>.md`,
   e.g. `docs/decisions/D-progress-0886-graph-service-retry-outbox.md`.
3. Inside, use a single top-level heading that carries the id and title, then
   the body — same shape as an archive entry:

   ```markdown
   # D-progress-886 — Short imperative title (#PR)

   **Status:** shipped | accepted | superseded

   … context / decision / rationale …
   ```

4. Cross-reference other decisions by their id (`See D-progress-885`,
   `SUPERSEDED by D-progress-886`) — ids resolve across the archive and this
   directory, so links keep working regardless of which file an entry lives in.

## Numbering races

Numbers are allocated by convention, not by a lock, so two PRs opened close
together can pick the same id. Because slugs differ both files would land, but
ids are referenced textually (`See D207`), so a shared id makes every such
reference ambiguous. CI therefore enforces uniqueness:
`scripts/ci/check-decision-ids.sh` (run in the `actionlint` job) fails when two
files here share an id.

If it fails on your PR, renumber your entry to the next free id: rename the
file, change the id in its heading, and update every reference to it in `docs/`,
`book/`, code comments and scripts. Read each reference first: while the id was
shared, some of the existing references may mean the other entry.

`scripts/ci/decision-id-allowlist.txt` lists the ids that were already
duplicated when the check landed (the `D-progress-NNNN` series, #7141), with the
most files each may keep. It can only shrink: the check also fails on a listed
id that no longer has duplicates, so remove its line when you reconcile it.

## Superseding an archive decision

Leave the archive entry byte-frozen. Record the reversal as a *new* file here
that names the superseded id (`Supersedes D-progress-NNN`), the same forward-link
convention the append-only log used — just in a new file rather than by editing
the tail.
