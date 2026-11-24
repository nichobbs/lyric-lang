# `Std.HttpServerHost` seam on three targets (docs/73 slice S2, D786)

Slice S2 of `docs/73-jvm-pure-lyric-server-plan.md`; design and name decisions in `docs/decisions/D786-http-server-host-seam.md`.

## What shipped

- `Std.HttpServerHost` in `lyric-stdlib/std/_kernel/`, `_kernel_jvm/` and `_kernel_native/` (`http_server_host.l`): `startTask`, `Mutex`, `Semaphore`, `runGuarded`, `WorkerSet`, `ensureThreadCapacity`. Registered in `lyric-stdlib/lyric.full.toml`. Nothing imports it yet; S3 does.
- `lyric-stdlib/tests/http_server_host_tests.l`: 12 tests (startTask, 300 closures handed over from a returned frame, mutual exclusion with 8 workers x 2000 increments, reentrancy, semaphore counting and `semTryWait`, a blocked wait woken by a later post, a post before the wait, nested worker join, set reuse, `runGuarded`, a panicking worker still joined). The guard and panic cases are `@cfg(target = "native")` no-ops on native, which cannot catch a panic.
- CI wiring through scripts only (`ci.yml` untouched): `scripts/ci/stdlib-net-tests.sh` (dotnet and JVM steps already exist) and the two native lists `native-platform-tests.sh` and `native-backend-self-tests.sh`.
- `scripts/ci/http-server-benchmark.sh`: the copied `lyric-web/tests/zz_bench_server_web.l` is now also removed by an EXIT trap, so a failed Undertow build under `set -e` no longer leaves it behind (S0 review cleanup).

## How it was verified

`make lyric` cannot finish in this container (AOT step needs .NET 11, SDK 10 only). The toolchain was the v0.7.15 release compiler with `lib/std` replaced by this tree's `lyric-stdlib/std` and `Lyric.Stdlib.dll` rebuilt from this tree's `lyric.full.toml` (107 packages); the native runtime is v0.7.15's `lyric_rt.a`, which already has every primitive used. All 12 tests pass on `--target dotnet`, `--target jvm` and `--target native`. An ASan native stress driver was clean. The CI scripts were edited but not run end to end.

## Notes for S3

- The JVM test run prints a stack trace for the deliberately panicking worker (virtual thread uncaught exception); the test still passes.
- `lyric fmt` here is v0.7.15's, not the tree's.
