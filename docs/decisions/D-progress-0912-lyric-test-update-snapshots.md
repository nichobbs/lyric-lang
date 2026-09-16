# D-progress-912 — `lyric test --update-snapshots` ships (#678 item 3)

**Status:** shipped

**Context.** #678 tracked four v2 test-runner items; item 2 (`--manifest`
multi-file discovery) had already shipped, leaving doctests,
`--update-snapshots`, and cross-package non-`pub` access open. This lands
item 3.

**Design.** `Std.Testing.Snapshot.snapshotIn` already had the exact
semantics `--update-snapshots` needs for the "file doesn't exist yet" case
(write `actual`, return `Ok(true)`) — the flag just needed to make every
call take that branch unconditionally. Rather than thread a new parameter
through `snapshotIn`/`snapshotMatchIn`/`snapshot`/`snapshotMatch` (and every
call site), `snapshotIn` now also takes that branch when the
`LYRIC_UPDATE_SNAPSHOTS` env var is `"1"`. `cmdTest` sets it via
`Environment.setVar` when `--update-snapshots` is passed, before compiling
the test. This is a real OS-level environment variable (`Environment.setVar`
→ `System.Environment.SetEnvironmentVariable`, an OS `setenv()` call), so it
propagates to whatever child process the compiled test runs as — `dotnet
exec`, `java -jar`, or a native binary — with zero additional plumbing
needed on any target, and it composes for free with project-mode
`--manifest` suites (every `[project.tests]` entry's compiled binary
inherits the same env var).

**Verification.** Two new tests in `cli_test_self_test.l` build a snapshot
fixture with a deliberately stale baseline (`"old-hello"` on disk, actual
value `"new-hello"`): without `--update-snapshots` the run fails (`not ok`,
with the mismatch diff) and the file on disk is untouched; with
`--update-snapshots` the run passes and the file is rewritten to
`"new-hello"`. Both run via `Cli.main(...)` in-process, the same entry point
`lyric test` itself runs through. `book/chapters/15-testing.md` already
documented `--update-snapshots` prose (§15.4) ahead of implementation —
this entry makes that prose accurate rather than aspirational; the
`docs/24-test-runner-plan.md` "still v2" list is updated accordingly.

**Not done here:** doctests (#678 item 1) and cross-package non-`pub`
access (#678 item 4) remain open — the prior status comment on #678 called
cross-package access "the most invasive of the four," and that's still the
right read; doctests need a markdown-fenced-block extractor over doc
comments (Q-test-4, `docs/24-test-runner-plan.md` §7) that doesn't exist
yet either.
