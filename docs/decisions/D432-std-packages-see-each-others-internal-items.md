# D432 - A stdlib package sees the `internal` items of the other stdlib packages (docs/70 phase 3a, #8613)

**Status:** shipped; the checker's import filter and the JVM and native stdlib loaders change, the language does not (docs/01 section 3.1 already makes `internal` visible across a project).

## Context

`Std.Tls` declares `internal func Identity.rawHandle` and `Certificate.rawHandles`, the kernel-boundary accessors the TLS kernels (`Std.HttpServer`, `Std.HttpHost`, `Std.TcpHost`) call. The JVM and native bridges built each source-loaded stdlib package's importable items with `pipeIsCrossPackageItem`, which keeps `pub` functions only, so when `Std.HttpServer` was checked those accessors had no signature. The call got no callee and no type, a silent `TyError` that broke the I0001 policy; the same shape worked in a two-package project because project siblings use the `internal`-admitting rule.

## Decision

- The JVM bridge (`stdlib` item lists for the entry and per-package loads) and the native bridge build a stdlib package's items with `pipeIsCrossPackageItemProject`, which also admits `internal`.
- `ImportedPackage` carries `stdlib: Bool`, set by the bridges for a package they loaded from the standard library's own root. The standard library is one project, and its identity is where the package was loaded from, never its name: a user package named `Std.MyOwn` is not the standard library (`user_std_named` in `tir-builder-shapes-e2e.sh`).
- The checker filters on the way in (`itemsVisibleToImporter`): the `internal` functions, values and extern functions of a stdlib package are dropped unless the package being checked is itself a stdlib package (`importerIsStdlibPackage`). The bridges list every user package, the entry and each sibling, unflagged under its own name and leave the stdlib package being checked out of its own import list, so a package with an unflagged entry is a user package whatever its name, and any other checked package was loaded from the stdlib root. Every other importer still sees `pub` items only, so the accessors stay out of application code (`user_internal_hidden`).
- Packages that are not stdlib packages pass through unchanged: their bridge already applied the project rule or the `pub` rule that fits them.

The MSIL bridge is unchanged: its stdlib comes from the bundled DLL's `pub` method table, and an `internal` function has no cross-assembly binding to call through.

## Results

`Std.HttpServer::buildIdentityKeyStore` and `buildClientCaKeyStore` build on `--target jvm` (they were unbuilt), as do `Std.HttpHost::applyTlsOptions` and `requestHeaders`. `tir-builder-shapes-e2e.sh` gains `std_internal_sigs`, `user_internal_hidden` (which also asserts the call is reported unresolved) and `user_std_named`.
