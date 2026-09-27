# JVM `Std.Environment.setVar` overlay; dotnet T0115 on self-qualified distinct-type factories (#7546)

Two gaps found while working on #7478.

## `Std.Environment.setVar` was a silent no-op on the JVM

`_kernel_jvm/environment_host.l`'s `hostSetEnvironmentVariable` did nothing —
the JVM exposes no portable `setenv(3)` equivalent. A JVM program that set a
variable before calling library code that reads it (`DOCKER_HOST`, TLS
config) silently saw the old value. Fixed with a process-wide overlay,
`envOverlay` (a `ConcurrentHashMap<String, String>`), that `hostGetVarOpt`
consults (via `containsKey`, before falling back to `System.getenv`) and that
`Std.ProcessHost` / `Std.ProcessCaptureHost` / `Std.ProcessPipedHost` copy
onto every spawned child's `ProcessBuilder.environment()` — matching the
.NET/native kernels, where `setVar` mutates the real process environment
block a child already inherits.

Along the way: verified (not assumed) that `System.Environment
.SetEnvironmentVariable(key, "")` on real .NET sets the variable to an empty
string, it does not remove it — a `dotnet run` repro against net10.0/Linux
showed `GetEnvironmentVariable` afterwards still returns `""`, never `null`.
The JVM overlay and native's pre-existing `setenv(3)`-only kernel both
already match this contract; no unset path exists on any target.

Full details and the exact-FQN-match design rationale for both fixes are in
`docs/decisions/D-progress-1010-jvm-env-overlay-msil-self-qualified-tryfrom.md`.
Resolves Q-JVM-001 in `docs/06-open-questions.md`.

**Files:** `lyric-stdlib/std/_kernel_jvm/environment_host.l`,
`lyric-stdlib/std/_kernel_jvm/process_host.l`,
`lyric-stdlib/std/_kernel_jvm/process_capture_host.l`,
`lyric-stdlib/std/_kernel_jvm/process_piped_host.l`,
`lyric-stdlib/std/_kernel/environment_host.l` (doc only),
`lyric-stdlib/std/_kernel_native/environment_host.l` (doc only),
`lyric-stdlib/std/environment.l` (doc), `lyric-stdlib/tests/environment_tests.l`
(new set/get/overwrite/empty-value/child-inheritance cases).

**Consumer unblocked:** `lyric-docker`'s `basic_operations_tests.l` — the 5
`DOCKER_HOST=tcp://` routing tests that were the only JVM failures (91/96)
now pass (96/96); `lyric-docker` joins `scripts/ci/jvm-ecosystem-suites.sh`.

## Dotnet T0115 on a call qualified by the file's own package name

`Lyric.Pkg.Port.tryFrom(n)` inside package `Lyric.Pkg` failed to compile on
dotnet with `error[T0115]: cannot resolve qualified reference
'Lyric.Pkg.Port'`, even though the unqualified `Port.tryFrom(n)` resolves.
The JVM already accepted this (and cross-package forms like
`Std.Http.Url.tryFrom(x)`) after #7478.

Root cause: a distinct/range-subtype's synthesized `from`/`tryFrom` factory
is registered in the MSIL bridge under a separate map
(`distinctFromTokens`/`distinctTryFromTokens`, keyed by bare FQN) that
`lowerMethodCallMsil` only consulted when the receiver was a single-segment
`EPath` — true for a bare `Port` but never for a qualified chain, which
always parses as nested `EMember`s. None of the function's other qualified-
call fallback tiers apply either, since a distinct-type factory is
registered in neither `funcTokens` nor `recordCtorTokens`.

Fixed with a pre-check in `lowerMethodCallMsil` that flattens the receiver
(handling both `EPath` and `EMember` chains) and retries the factory
resolution when the last segment names a distinct/range-subtype type AND the
whole flattened chain exactly equals that type's FQN — the exact-match guard
means a real value's field-access chain that merely ends in a distinct
type's bare name can never misfire.

**Files:** `lyric-compiler/msil/codegen.l` (`tryLowerDistinctFactoryCallMsil`
extracted helper + the new pre-check), `lyric-compiler/lyric/distinct_ops_self_test.l`
(new regression case, dotnet/JVM/native).
