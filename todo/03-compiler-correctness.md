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

### #1022 — Native Lyric extern boundary: replace JSON-blob protocol and F# host shims

The kernel files for `lyric-session` and `lyric-jobs` currently use `@externTarget` + JSON-blob wire format, with F# hosts parsing that JSON — domain logic in F#, which is prohibited. `lyric-storage` is handled by Tier 1.

The correct final architecture is **no F# host shims at all** for these libraries. Bind directly to the NuGet packages from Lyric using `extern package` declarations, own all serialisation in Lyric, and delete the F# host projects.

**For `lyric-session`:**

Replace `lyric-session/src/_kernel/net/session_kernel.l` with native `extern package StackExchange.Redis` bindings:

```lyric
extern package StackExchange.Redis {
  extern type StackExchange.Redis.ConnectionMultiplexer {
    static func Connect(config: String): ConnectionMultiplexer
    func GetDatabase(db: Int): IDatabase
  }
  extern type StackExchange.Redis.IDatabase {
    func StringSet(key: String, value: slice[Byte], expiry: Option[TimeSpan]): Bool
    func StringGet(key: String): Option[slice[Byte]]
    func KeyDelete(key: String): Bool
    func KeyExists(key: String): Bool
  }
}
```

`lyric-session/src/session.l` owns all serialisation/deserialisation of session data using `Std.Json`. No JSON parsing may appear in F#.

Delete `bootstrap/src/Lyric.Session.Host/RedisStore.fs` and remove the project from `Bootstrap.sln` once the `extern package` bindings and tests pass.

**For `lyric-jobs`:**

Replace `lyric-jobs/src/_kernel/net/jobs_kernel.l` with native bindings for each backend:

*Hangfire (`@cfg(feature = "hangfire")`)* — `extern package Hangfire`:
```lyric
extern package Hangfire {
  extern type Hangfire.BackgroundJob {
    static func Enqueue(methodCall: Expression): String
    static func Schedule(methodCall: Expression, delay: TimeSpan): String
  }
  extern type Hangfire.RecurringJob {
    static func AddOrUpdate(id: String, methodCall: Expression, cron: String): Unit
  }
}
```

*Quartz.NET (`@cfg(feature = "quartz")`)* — `extern package Quartz`:
```lyric
extern package Quartz {
  extern type Quartz.IScheduler {
    func ScheduleJob(detail: IJobDetail, trigger: ITrigger): DateTimeOffset
    func DeleteJob(key: JobKey): Bool
  }
  // ... remaining types
}
```

`lyric-jobs/src/jobs.l` owns all job type registration, payload serialisation, and scheduling logic. No JSON parsing or type-dispatch logic may appear in F#.

Delete `bootstrap/src/Lyric.Jobs.Host/JobsHost.fs` and remove the project from `Bootstrap.sln` once the `extern package` bindings and tests pass.

**Fallible BCL calls:** Wrap any BCL method that throws in a thin Lyric `try { } catch (e: Exception) { Err(e.Message) }` wrapper in the public `.l` layer. Do NOT use F# for exception handling.

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
- [ ] `lyric-session` kernel uses `extern package StackExchange.Redis` bindings; no `@externTarget` pointing to F# shims
- [ ] `bootstrap/src/Lyric.Session.Host/RedisStore.fs` deleted; project removed from `Bootstrap.sln`
- [ ] `lyric-jobs` kernel uses `extern package Hangfire`/`extern package Quartz` bindings; no `@externTarget` pointing to F# shims
- [ ] `bootstrap/src/Lyric.Jobs.Host/JobsHost.fs` deleted; project removed from `Bootstrap.sln`
- [ ] All session/jobs serialisation logic lives in `.l` files; zero JSON parsing or type-dispatch in F#
- [ ] No F# try/catch in session/jobs path; exception wrapping happens in Lyric
- [ ] `lyric test --manifest lyric-session/lyric.toml` passes
- [ ] `lyric test --manifest lyric-jobs/lyric.toml` passes (or tests added if none exist)
- [ ] `lyric-storage` extern boundary already addressed by Tier 1 fix; verify `lyric test --manifest lyric-storage/lyric.toml` still passes
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
