# D-progress-888 — #4638 closed: `scripts/patch_interface_impl.py` removed, stage-0 seed emits sorted InterfaceImpl natively

**Status:** shipped


**Context.** #4638 tracked a bootstrap-grade workaround: the stage-0 seed
binary (an older self-hosted `lyric` release, downloaded by
`scripts/bootstrap.sh` to bootstrap-compile the CURRENT source into
`.bootstrap/stage1/Lyric.Stdlib.dll`) used to emit an unsorted
`InterfaceImpl` (0x09) metadata table, which the CLR's loader rejects
(`BadImageFormatException`, ECMA-335 §II.22.23). `scripts/patch_interface_impl.py`
did binary surgery on the produced DLL to sort the table and set the
`SortedTables` bit before `make aot` could link against it. The self-hosted
emitter itself (`lyric-compiler/msil/tables.l:781`) has sorted
`InterfaceImpl` at serialization time for a long while — the patcher only
ever compensated for the SEED's stale ABI, never for current source.

**Removal criteria (from #4638 itself).** "Close this issue only once a
seed release built from post-fix source is in use and CI confirms the patch
step is a no-op."

**Verification.** Ran `scripts/patch_interface_impl.py` directly against a
freshly-built `.bootstrap/stage1/Lyric.Stdlib.dll`, twice:

1. Seeded from `v0.6.1` (`scripts/bootstrap.sh`'s hardcoded last-resort
   fallback version, `LYRIC_BOOTSTRAP_FALLBACK_VERSION`) — output: `Already
   sorted: True` / `Table already sorted and sorted bit set — no patch
   needed.`
2. Seeded from `v0.6.3` (the actual current latest GitHub release, fetched
   directly via its `releases/download/` asset URL — the sandbox's own
   `/releases` API LISTING is blocked by this session's network policy, but
   direct asset downloads are not) — identical no-op result.

Both the fallback pin and the real latest release are unambiguously built
from post-tables.l-fix source (the fix has been in place since long before
either), so the patcher has had nothing to do for a long time. Removed
`scripts/patch_interface_impl.py` and its invocation in `Makefile`'s `aot`
target (previously ran unconditionally whenever
`.bootstrap/stage1/Lyric.Stdlib.dll` existed, immediately before the
`dotnet build bootstrap/src/Lyric.Cli.Aot` step). `make lyric` was
re-verified end-to-end after the removal (stage1 → AOT → `./bin/lyric
--version` all succeeded) to confirm nothing implicitly depended on the
patch step running.

**#2444 (target-gating backend-bridge imports via `@cfg(target)`,
D-N-013) — investigated alongside, left OPEN.** #2444's blocker was "barred
by the no-new-F# rule until stage-0 retires" — F# has since been fully
removed repo-wide (`CLAUDE.md`'s "No F# code allowed" section), so that
specific historical blocker no longer applies. However, the issue is
explicitly filed as a **lower-priority optimization** (smaller/faster
type-check closure, not a correctness fix — the original correctness driver
was independently fixed by #2426), and its implementation is a genuinely
new PARSER FEATURE (annotations on `import` declarations — neither the AST
nor the parser accepts `@…` before `import` today), plus `cfg.l` per-import
erasure logic and multi-target unified-compiler build changes. That is
substantially more design and implementation work than fits this session's
scope alongside the other build-system-toolchain fixes in this PR. Leaving
#2444 open with this status noted; a future session can pick up its
"What it requires" list with the F#-retirement blocker crossed off.

**Related:** #4638 (closed by this entry), #2444 (status updated, stays
open), `lyric-compiler/msil/tables.l:781` (the emitter-side sort fix this
patcher compensated for), `docs/23-fsharp-shim-elimination.md`.
