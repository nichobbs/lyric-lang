# D-progress-1010 — JVM `setVar` overlay; MSIL self-qualified distinct-type factory calls (#7546)

**Status:** shipped

Two independent gaps found while working on #7478.

## 1. `Std.Environment.setVar` was a silent no-op on the JVM

Java exposes no portable `setenv(3)` equivalent without unsafe reflection, so
`_kernel_jvm/environment_host.l`'s `hostSetEnvironmentVariable` did nothing.
A JVM program that called `setVar("DOCKER_HOST", ...)` before using library
code that reads it (`lyric-docker`'s `basic_operations_tests.l`, `lyric-web`'s
`webtls_config_tests.l`) silently saw the old (usually absent) value.

### Decision

Back `setVar`/`getVar` on the JVM with a process-wide overlay instead of
returning an error or leaving the no-op undocumented: a single
`ConcurrentHashMap<String, String>` (`envOverlay`) that `hostGetVarOpt`
consults (via `containsKey`, before falling back to the real
`System.getenv`) so an overlaid value — even an empty one — always wins.
`Std.ProcessHost` / `Std.ProcessCaptureHost` / `Std.ProcessPipedHost` copy
the overlay onto every spawned child's `ProcessBuilder.environment()` map
before `start()`, so a child process observes the same variables `getVar`
reports in the parent — observably equivalent to the .NET/native kernels,
where `setVar` mutates the real process environment block a child already
inherits. The one visible gap against the real kernels: a tool outside this
process (`ps`, `jps`) inspecting this process's real environment block from
the outside will not see the overlay — documented on `Std.Environment.setVar`.

**Empty-value semantics — verified, not assumed.** The obvious design
(`setVar(key, "")` unsets, mirroring `.NET`'s null-value overload) turned out
to be wrong: a small `dotnet run` repro against `System.Environment
.SetEnvironmentVariable(key, "")` on net10.0/Linux showed the variable is set
to an empty string, not removed (`GetEnvironmentVariable` afterwards returns
`""`, not `null`) — the two-argument overload Lyric's non-nullable `String`
parameter can call has no way to pass the null value the *three*-argument
overload's docs describe as removing it. There is therefore no portable way
to unset a variable through `Std.Environment.setVar` on any target. The JVM
overlay matches this: `envOverlay.containsKey` (not a non-empty-string check)
distinguishes "overlaid with an empty value" from "not overlaid at all", so
`setVar(key, "")` still makes `getVar` report `Ok("")`, exactly like the real
BCL. Native's `setenv(3)`-backed kernel already matched this (it always
called `setenv`, never `unsetenv`) and needed no change once the JVM design
settled on the same contract.

### Files

- `lyric-stdlib/std/_kernel_jvm/environment_host.l` — `envOverlay`,
  `hostSetEnvironmentVariable`, `hostGetVarOpt`, `hostForEachOverlayVar`
  (the iteration helper consumed by the process kernels).
- `lyric-stdlib/std/_kernel_jvm/process_host.l`,
  `process_capture_host.l`, `process_piped_host.l` — apply the overlay to
  each spawned child's `ProcessBuilder.environment()`.
- `lyric-stdlib/std/_kernel/environment_host.l`,
  `lyric-stdlib/std/_kernel_native/environment_host.l`,
  `lyric-stdlib/std/environment.l` — doc comments only, recording the
  verified empty-value contract (no behaviour change on dotnet or native).

Resolves Q-JVM-001 (`docs/06-open-questions.md`).

## 2. Dotnet T0115 on a call qualified by the file's own package name

On dotnet, `Lyric.Pkg.Port.tryFrom(n)` inside package `Lyric.Pkg` failed to
compile with `error[T0115]: cannot resolve qualified reference
'Lyric.Pkg.Port'`, even though the unqualified `Port.tryFrom(n)` resolves
fine. The JVM already accepted this shape after #7478
(`qualifiedDotNamedSigJvm`).

### Root cause

A distinct/range-subtype type's synthesized `from`/`tryFrom` static factory
is registered in the MSIL bridge (`lyric-compiler/msil/codegen.l`) under
`distinctFromTokens`/`distinctTryFromTokens`, keyed by the type's bare FQN —
a *separate* map from `funcTokens` (which holds ordinary functions and
hand-written `func Type.method` UFCS declarations). `lowerMethodCallMsil`
only ever consulted those two maps inside a `match recv.kind { case
EPath(path) -> ... }` arm. A bare, unqualified receiver (`Port`) always
parses as a single-segment `EPath`, so that arm fires. A *qualified*
receiver (`Lyric.Pkg.Port`, or an imported `Std.Http.Url`) parses as nested
`EMember`s (`EMember(EMember(EPath(["Lyric"]), "Pkg"), "Port")`), never a
multi-segment `EPath` — so the `case EPath` arm's factory lookup never ran,
and none of the function's other qualified-call fallback tiers (free
function, same-package/imported dot-named UFCS function, union-case
constructor, record constructor) apply either, since a distinct-type
factory is registered in neither `funcTokens` nor `recordCtorTokens`. The
call fell through to generic value evaluation of the receiver chain, which
`diagnoseUnresolvedQualifiedValueMsil` flags as T0115.

This differs from JVM's equivalent gap (fixed in #7478): the JVM backend
registers a distinct type's `from`/`tryFrom` directly into the same
`funcSigs` map ordinary dot-named functions use, so `qualifiedDotNamedSigJvm`
(a `funcSigs`-only lookup) already covers it. MSIL keeps factories in a
separate map, so the equivalent fix has to retry that separate lookup
directly, not just extend the funcTokens-based fallback tiers.

### Decision

Add a pre-check at the top of `lowerMethodCallMsil` that flattens `recv`
(`flattenPathExprSegs`, handling both `EPath` and `EMember` chains
uniformly) and, when the chain has 2+ segments and the last one resolves via
`typeFqnByName` to a distinct/range-subtype type whose FQN *exactly* equals
the whole flattened chain, retries the same factory resolution the
unqualified path uses (factored into a shared `tryLowerDistinctFactoryCallMsil`
helper). The exact-FQN-match guard (rather than "last segment matches some
type") is deliberate: a real local value's own field-access chain that
happens to end in a distinct type's bare name (`config.section.Port`) can
never misfire, because its prefix (`config.section`) will never equal
`Port`'s real declaring package. The chain is also required not to start at
a real local/hoisted-cell/capture slot, mirroring JVM's
`qualifiedDotNamedSigJvm` guard.

### Files

- `lyric-compiler/msil/codegen.l` — `tryLowerDistinctFactoryCallMsil`
  (extracted helper) and the new pre-check in `lowerMethodCallMsil`.
- `lyric-compiler/lyric/distinct_ops_self_test.l` — regression test
  (`"package-qualified Type.from/tryFrom resolves the same as unqualified"`),
  run on dotnet, JVM, and native in CI.
