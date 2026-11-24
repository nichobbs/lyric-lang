# Stdlib kernel

Per `docs/14-native-stdlib-plan.md` §3 and Decision F (D038), this
directory is the audited extern boundary for `Std.*`. Files here may
contain `@externTarget("System.X.Y")` and
`extern type T = "System.Foo"` declarations that bottom out at the
.NET BCL or other host runtime surfaces.

## What lives here

Every Lyric stdlib module that depends on a host operation that
cannot be expressed in pure Lyric — syscalls (file/network/console),
hardware-tuned BCL primitives (transcendentals, regex, JSON
tokenizer, TLS), threading primitives, IEEE 754 corner cases.
Anything else lives in the parent `lyric-compiler/lyric/std/` directory
as a native Lyric implementation.

## `Std.HttpServer` and `Std.HttpServerHost` (D786, D788, D789, D790, docs/73 slices S2 to S5)

`http_server.l` is **not a dotnet kernel**: since slice S3 it is the shared HTTP
server driver (dotnet since D788, the JVM since D789, native since D790), written once over `Std.HttpEngine`, `Std.TcpHost` and the
per-target seam `Std.HttpServerHost`, and it contains no extern and no
`@axiom`. It lives under `_kernel/` only because the source loaders shadow a
`_kernel/<name>.l` by the `_kernel_jvm/` and `_kernel_native/` file of the same
name and never a top-level `std/<name>.l`. The JDK kernel was deleted in slice
S4 (D789) and the native one in slice S5 (D790), so every loader reads the one
driver, which therefore lives at `lyric-stdlib/std/http_server.l` (D780). On native
the driver frees its locks and semaphores for real (the seam's `release*`
functions); see D790 for the lifetime rules (`waitingPullers`, the h2 link and
exchange counts).

`http_server_host.l` is the seam: `startTask` and `tryStartTask`, `Mutex`
(reentrant), `Semaphore`, `runGuarded`, `WorkerSet`, `ensureThreadCapacity`,
`defaultMaxConnections` and `acceptOutcome`, with the same package and public
surface in `_kernel_jvm/` and `_kernel_native/`. dotnet uses `Task.Run`,
`Monitor` and `SemaphoreSlim`; native reuses `lyric_mutex_*`, `lyric_sem_*`,
`lyric_thread_create`/`lyric_thread_join` and `lyric_thread_spawn_detached`,
retaining every closure it hands to a thread (#6797). The contracts are listed
in the file header and pinned by `lyric-stdlib/tests/http_server_host_tests.l`
on all three targets; the driver's own contract (stop, pull queue, limits,
h2) by `http_server_tests.l` and `http_server_stop_tests.l`.

## What does NOT live here

Native Lyric code. Pure-Lyric algorithms over `slice[T]`, primitives,
records, sum types, and other kernel modules belong in the parent
directory. If you find yourself writing `@externTarget` in a
non-kernel file, the convention is broken — move the declaration
here and `import` it from your safe-API module.

## Hard cap

Decision F sets a v1.0 release gate of **150 extern declarations
across the whole kernel**. Auditing 150 is tractable; auditing 500
is not. PRs that push the count toward the cap should justify each
new declaration in their description.

## Enforcement (the ratchet)

`bootstrap/tests/Lyric.Emitter.Tests/KernelBoundaryTests.fs` runs
on every CI build:

- **`extern declarations outside _kernel/ never grow`**: hard
  assertion. Any PR that adds `@externTarget`, `extern type`, or
  `extern package` outside `_kernel/` flips the test red. Migrate
  the declaration here instead.
- **`kernel total reported`**: today informational. Reports the
  combined extern surface; Decision F's hard cap of 150 becomes a
  blocking assertion at v1.0.

When a PR moves declarations into `_kernel/` (or rewrites them in
pure Lyric), it should also drop `outsideCeiling` in
`KernelBoundaryTests.fs` so the ratchet stays meaningful.

## Discovery

The build/test machinery (`Emitter.fs::locateStdlibFile`,
`Cli/Program.fs::locateStdlibFiles`,
`tests/Lyric.Emitter.Tests/StdlibSeedTests.fs::loadStdlibBody`)
recurses into this subdirectory. Top-level files shadow same-name
kernel files on collision so a future native rewrite of a kernel
module wins without manual cleanup.

## See also

- `docs/14-native-stdlib-plan.md` §3 — kernel contents & rationale
- `docs/14-native-stdlib-plan.md` §6 P0 — migration log
- `docs/03-decision-log.md` D038 — umbrella decision (Resolution F)
- `docs/06-open-questions.md` Q022 — language work for `pub use`
  proper and opaque wrapping with generic params (partially
  resolved: the practical collections.l blocker is fixed without
  these features)
