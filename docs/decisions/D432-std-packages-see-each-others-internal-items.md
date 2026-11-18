# D432 - A `Std.*` package sees the `internal` items of the other `Std.*` packages (docs/70 phase 3a, #8613)

**Status:** shipped; the checker's import filter and the JVM and native stdlib loaders change, the language does not (docs/01 section 3.1 already makes `internal` visible across a project).

## Context

`Std.Tls` declares `internal func Identity.rawHandle` and `Certificate.rawHandles`, the kernel-boundary accessors the TLS kernels (`Std.HttpServer`, `Std.HttpHost`, `Std.TcpHost`) call. The JVM and native bridges built each source-loaded stdlib package's importable items with `pipeIsCrossPackageItem`, which keeps `pub` functions only, so when `Std.HttpServer` was checked those accessors had no signature. The call got no callee and no type, a silent `TyError` that broke the I0001 policy; the same shape worked in a two-package project because project siblings use the `internal`-admitting rule.

## Decision

- The JVM bridge (`stdlib` item lists for the entry and per-package loads) and the native bridge build a stdlib package's items with `pipeIsCrossPackageItemProject`, which also admits `internal`.
- The checker filters on the way in (`itemsVisibleToImporter`): the `internal` functions and values of a `Std.*` package are dropped unless the importing package is also `Std.*`. The standard library is one project; a user package, or any other importer, still sees `pub` items only, so the accessors stay out of application code (`user_internal_hidden` in `tir-builder-shapes-e2e.sh`).
- Packages that are not `Std.*` pass through unchanged: their bridge already applied the project rule or the `pub` rule that fits them.

The MSIL bridge is unchanged: its stdlib comes from the bundled DLL's `pub` method table, and an `internal` function has no cross-assembly binding to call through.

## Results

`Std.HttpServer::buildIdentityKeyStore` and `buildClientCaKeyStore` build on `--target jvm` (they were unbuilt), as do `Std.HttpHost::applyTlsOptions` and `requestHeaders`. `tir-builder-shapes-e2e.sh` gains `std_internal_sigs` and `user_internal_hidden`.
