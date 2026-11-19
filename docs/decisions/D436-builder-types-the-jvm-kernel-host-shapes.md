# D436 - The builder types the host shapes of the JVM environment, hash and registry kernels (docs/70 phase 3a, #8613)

**Status:** shipped; extends D431, D434 and D445. The checker is unchanged. Under docs/01 section 2.11 a kernel binds an unchecked host result at a declared type, which is how `Std.EnvironmentHost` now spells its locals.

## Decision

- **Declared locals.** `hostIsWindows`, `hostGetVarOpt` and `hostSetEnvironmentVariable` (and, in `lyric-ws`'s JVM kernel, `WsCloseListener.handleEvent`, `WsOriginGuard.handleRequest` and `WsConnectCallback.onConnect`) declare the host result they bind (`val name: String = JSystem.getProperty("os.name") ?? ""`, `val raw: String? = envOverlay.get(key)`); the checker then types the local and the builder converts the host result.
- **Erased `Object` as `String?`.** `hostResultIsCallType` takes the host `Object` of a `String` map's read or put as the `String?` the context declares, as it already does for `String` and for a host class.
- **`Object` as a primitive argument.** `erasedHostKind` converts the host `Object` to a Lyric primitive or `String` argument with `CvFromHost` (`action(e.getKey(), e.getValue())` on a raw `Map.Entry`).
- **`.length` of an untyped local.** `buildExpr` and `builtinPropertyName` read the `length` of a local the checker left untyped (`var chunk = fis.readNBytes(n)`) from the type the local was declared at.
- **`Object` read as a record.** A host collection's erased `Object` result read as the Lyric record or union stored in it (`val state: RegistryState = registryMap.get(key)`) converts with `CvFromHost` (`Ws.Kernel.Jvm::lookupRegistry`).

## Results

`Std.EnvironmentHost` and `Std.HashHost` build all their bodies on `--target jvm`; `Auth.Kernel.Jvm::hmacSha256`, `Web.Kernel.Runtime::serve` and `Ws.Kernel.Jvm::lookupRegistry` build with 0 I0003. `serveTls` and `startWorkerLoop` are tracked in the progress entry.
