# D-progress-885 — #6537's two residual `externTypeNames` bare-name-collision sites confirmed already fixed by PR #6981; regression tests added

**Status:** shipped

**Context.** #6537 tracked two residual `cctx.externTypeNames`
unscoped-bare-name-lookup sites (same bug class as #6041/#6536, out of
scope for that PR): `resolveFfiClassTypeRef` (used by `bufFfiType` for
`@externTarget` FFI signature-blob encoding) and
`lookupDeclaredClrFqnForTypeExpr`/`resolveValueTaskGenericMsilType` (the
`ValueTask<T>`-shaped extern return-type special case). Investigated while
working the group's #6029/#5525/#3369/#4601 batch.

**Found already fixed.** PR #6981's Gap 1 work (D-progress-883) had
independently added a `hasLyricTypeCandidateInScope` guard to both of
these EXACT functions while hardening the GENERICINST-parameter path — the
existing code comments even cite "#6537 residual site 1" and "#6537
residual site 2" verbatim, confirming the connection was made at the time
but the issue itself was never explicitly closed. No further code change
was needed; this entry supplies the missing regression coverage.

**Tests added** to `msil_project_bridge_self_test.l` (mirroring #6041's
existing two-package hijack tests):

- **Site 1:** an `@externTarget` wrapper (`System.Console.WriteLine`,
  `@externStatic`) declares its parameter as `Foo`, an unrelated package's
  *plain Lyric record* whose bare name collides with a THIRD package's
  `extern type Foo = "System.Text.StringBuilder"` alias. Before the fix,
  the bare-name collision made `resolveFfiClassTypeRef` misencode the
  parameter as `StringBuilder` in the MemberRef signature, matching no
  real `Console.WriteLine` overload (`MissingMethodException` at
  runtime). Verified by asserting the actual BCL overload is reached: the
  record's default `ToString()` (its FQN) prints first, proving the call
  resolved correctly, followed by the program's own `"done"`.
- **Site 2:** a plain (non-extern) Lyric function returns `Handle`, a
  record whose bare name collides with an unrelated package's `extern
  type Handle = "System.Threading.Tasks.ValueTask\`1[System.Int32]"` alias
  (used elsewhere for genuine async-unwrap purposes). Before the fix, the
  collision would misroute this function's ordinary record return through
  the ValueTask-shaped codegen path. Verified end-to-end: constructs the
  record, reads a field back through it, asserts the value round-trips.

**Verification.** Both new tests plus the full existing
`msil_project_bridge_self_test.l` suite: 55/55 pass (compiled and run
directly against the already-built `./bin/lyric` from PR #6981's `make
lyric` — no compiler-source changes in this entry, only test additions,
so no rebuild was needed).

**Related:** #6537 (closed by this entry — code fix already shipped in PR
#6981/D-progress-883, tests added here), #6041/#6536 (the original bug
class and its first-wave fix), D-progress-799 (the #6536 scope-boundary
decision that deferred these two sites).
