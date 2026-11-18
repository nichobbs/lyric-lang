# D434 - A local bound to a host result is a host chain receiver, a void host call is `Unit`, and a `java.util.concurrent` result is a plain host class (docs/70 phase 3a, #8613)

**Status:** shipped; extends D444 and D445. The checker is unchanged: docs/01 section 2.11 still leaves a host result unchecked.

## Context

`Std.HttpServer.startListener` does `val server = JHttpServer.create(addr, 0)`, then `server.createContext(..)`, `server.setExecutor(JExecutors.newVirtualThreadPerTaskExecutor())` and `server.start()`. The checker records no type for `server` or for any call on it. Three gaps left the body counted.

## Decision

- **Local receiver.** `hostChainReceiver` takes, beside a recorded host type and a chain's own type, a local whose declared type is a host class (`openLocalTy`), so a call on `server` resolves against the host's metadata.
- **Void members.** `hostChainResult` types a host method that returns `void` as `Unit` instead of giving up; the call builds as before.
- **`java.util.concurrent` results.** `isPlainHostResult` no longer excludes every `java.util.concurrent` class. The checker maps only the future and task names (`isHostTaskName`), which `hostNameHasLyricType` already excludes; an `ExecutorService` is a plain host class, so `Executors.newVirtualThreadPerTaskExecutor()` is typed from its static candidate and passed to `setExecutor`.

## Results

`Std.HttpServer` builds 54 of 54 bodies on `--target jvm` (52 before). `tir-builder-shapes-e2e.sh` gains `jvm_host_local_receiver`, built and run. `make self-test NAME=tir_build`: all pass.
