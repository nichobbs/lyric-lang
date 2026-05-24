# Tier 3 — Self-Hosted Compiler Correctness

## Issues
- **#1124** — `isCfgGatedOut` generates duplicate package declarations for directory packages with multiple source files
- **#1123** — `isCfgGatedOut` heuristic produces false positives for line comments containing `@cfg`
- **#1082** — `BootstrapCliShim` adds path-discovery logic to the forward-only AOT entry point
- **#1022** — Typed extern boundary redesign: replace JSON-blob protocol with typed native parameters (session, jobs, storage kernels)
- **#858** — Band 5: cross-package + value-generic monomorphizer extensions

## Prompt

You are working on the **lyric-lang** repository. Read `CLAUDE.md` fully before doing anything else. Pay particular attention to the F# surface-freeze rules: all new logic goes in `.l` files; the only acceptable F# changes are thin `@externTarget` wiring, test infrastructure shims, and bootstrap entry-point corrections.

Your task is to fix all five issues listed above. Work on a new branch named `fix/tier3-compiler-correctness`. Open a **draft** PR immediately after your first commit. Keep it draft until every acceptance criterion below is green. Rebase onto `main` at the start of each work session and before marking ready. Push after every coherent batch of changes.

---

### #1124 — `isCfgGatedOut` duplicate package declarations

The `isCfgGatedOut` heuristic in the self-hosted MSIL emitter incorrectly generates duplicate `package` declarations when a directory package spans multiple source files and one or more of them is `@cfg`-gated. Locate `isCfgGatedOut` in `lyric-compiler/msil/` (or `lyric-compiler/lyric/`) and fix the deduplication logic.

The fix must handle: a package with files `a.l` and `b.l` where `b.l` is gated with `@cfg(feature = "foo")` — only one `package` declaration must appear in the emitted output regardless of which files are included.

Add a self-test (`msil_self_test_mXX.l` or bridge test) that exercises a directory package with a gated source file and verifies the output compiles without duplicate-declaration errors.

---

### #1123 — `isCfgGatedOut` false positives for line comments

`isCfgGatedOut` uses a text heuristic to detect `@cfg` annotations. It produces false positives when a line comment contains the literal text `@cfg` (e.g. `// this was @cfg(feature = "x") before we removed it`). Code that should be included is incorrectly treated as gated out.

**Fix:** Restrict the `@cfg` heuristic to lines where `@cfg` appears before any `//` comment marker, or switch to a proper token-level check rather than a raw string search. The fix should be in the self-hosted compiler (`.l` file), not in any F# file.

Add a test: a source file with `@cfg` in a line comment and no actual `@cfg` annotation must not be treated as gated out.

---

### #1082 — `BootstrapCliShim` path-discovery in AOT entry point

`bootstrap/src/Lyric.Cli.Aot/` is the forward-only trampoline that calls `Lyric.Cli.Program.main`. It must not contain path-discovery or DLL-location logic. `BootstrapCliShim` has added such logic, violating the contract.

**Fix:** Remove the path-discovery logic from the AOT entry point. If the discovered path is needed by the self-hosted CLI, pass it via an environment variable or command-line argument set by the CI/build script, not by F# logic in the entry point. The AOT entry point must remain a pure trampoline: parse args, call `Lyric.Cli.Program.main`, exit.

This IS an acceptable F# change (it is the bootstrap entry point, not domain logic), but the change direction is removal, not addition.

---

### #1022 — Typed extern boundary: replace JSON-blob protocol

The kernel files for `lyric-session`, `lyric-jobs`, and `lyric-storage` currently use `@externTarget` + stub bodies that bridge to F# hosts via JSON strings as the wire format. The F# hosts then parse that JSON themselves — domain logic in F#, which is prohibited. The correct architecture has:

1. **Lyric public layer** — owns all serialisation, validation, and business rules
2. **Lyric kernel (`_kernel/net/*.l`)** — declares typed native `@externTarget` externs (strings, ints, `slice[Byte]`, etc.)
3. **F# host** — receives already-decoded native types; calls BCL APIs directly; contains zero JSON parsing

**For `lyric-session`:**
- Change session kernel externs to accept `sessionId: String` and `data: slice[Byte]`
- `lyric-session/src/session.l` serialises/deserialises session state using `Std.Json`
- `bootstrap/src/Lyric.Session.Host/RedisStore.fs` receives raw bytes, calls `IDatabase.StringSet/Get` — delete `parseSessionId` and any other JSON parsing from F#

**For `lyric-jobs`:**
- Change jobs kernel externs to accept typed parameters (job type name, serialised payload as `slice[Byte]`, delay/cron as primitives)
- `lyric-jobs/src/jobs.l` owns all job serialisation
- `bootstrap/src/Lyric.Jobs.Host/JobsHost.fs` receives and stores raw typed values — no JSON parsing

**For `lyric-storage`:**
- Verify `storage_kernel.l` is already wired (Tier 1 fix). If not, wire it first.
- Refine the extern signatures: raw file metadata (size, lastModified as epoch millis, content as `slice[Byte]`) — no JSON blobs crossing the boundary
- `lyric-storage/src/storage.l` owns all metadata formatting and serialisation

After each library refactor, run `lyric test --manifest <library>/lyric.toml` to verify no regressions.

---

### #858 — Band 5: cross-package + value-generic monomorphizer

`lyric-compiler/lyric/mono.l` currently monomorphises only same-package generics. Band 5 requires:

1. **Cross-package generic specialisation** — when a call site references a generic function from an imported package, monomorphise across the package boundary. Read the imported package's source (or IR) to generate the specialisation in the calling package.

2. **Value generic parameters (`GPValue`)** — e.g. `func ones[N: Nat](): Array[Int, N]`. Specialise per concrete value argument, generating distinct concrete functions for each value.

3. **Constraint propagation** — when a generic function has a `where T: SomeTrait` clause, propagate the constraint through the specialisation chain so the resulting concrete instantiation satisfies the trait dispatch requirements.

Work in `lyric-compiler/lyric/mono.l`. Extend the existing monomorphiser pass; do not replace it. Ensure the `mono_self_test.l` self-test is extended with cases covering all three capabilities.

Parity requirement: test that the same generic cross-package call produces typed IL (`MClass(...)`) rather than falling back to `MObject` in both `--target dotnet` and `--target jvm` paths.

---

## Acceptance Criteria

- [ ] Directory package with a `@cfg`-gated source file emits exactly one `package` declaration (no duplicates)
- [ ] Source file containing `@cfg` in a line comment is not incorrectly gated out
- [ ] Self-tests for both `isCfgGatedOut` fixes pass
- [ ] `BootstrapCliShim` contains no path-discovery logic; AOT entry point is a pure trampoline
- [ ] `bootstrap/tests/Lyric.Cli.Tests` pass after the AOT entry point fix
- [ ] `lyric-session` kernel externs accept typed native params; no JSON parsing in `RedisStore.fs`; `parseSessionId` deleted
- [ ] `lyric-jobs` kernel externs accept typed native params; no JSON parsing in `JobsHost.fs`
- [ ] `lyric-storage` extern interface uses typed metadata (not JSON blobs)
- [ ] `lyric test --manifest lyric-session/lyric.toml` passes
- [ ] `lyric test --manifest lyric-jobs/lyric.toml` passes (or tests added if none exist)
- [ ] `lyric test --manifest lyric-storage/lyric.toml` passes
- [ ] Cross-package generic specialisation works: imported generic function produces typed IL at call site
- [ ] Value generic parameters (`GPValue`) are specialised per concrete value
- [ ] Constraint propagation threads `where T: Trait` through specialisation chain
- [ ] `mono_self_test.l` extended with cross-package, `GPValue`, and constraint cases; all pass
- [ ] `dotnet run --project bootstrap/tests/Lyric.Emitter.Tests` passes
- [ ] `dotnet run --project bootstrap/tests/Lyric.Cli.Tests` passes
- [ ] No new F# domain logic; F# changes limited to removal or thin wiring only
- [ ] No disabled or skipped tests
- [ ] PR is draft until all criteria above are green; then marked ready for review
- [ ] Branch rebased onto `main` immediately before marking ready
