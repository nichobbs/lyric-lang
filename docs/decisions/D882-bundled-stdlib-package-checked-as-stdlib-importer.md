# D882 - A bundled stdlib package is checked as a stdlib importer, and the trace says why a function has no TIR body

**Status:** accepted, implemented in `Lyric.LlvmBridge` (docs/70 phase 3c, §12.2; follows D347)

## Decision

1. **`bundledTirOf` checks a bundled stdlib package with its own entry in the imported list.** The checker shows an importer the `internal` declarations of the other stdlib packages (the kernel-boundary accessors of `Std.Tls`, docs/01 §3.1) only when it finds the importer's own entry, flagged `stdlib`, in the list it is given (`importerIsStdlibPackage`). `stdlibImportClosure` leaves the package itself out, so `Std.TcpHost` and `Std.HttpHost` were checked as if they were user packages: `Tls.Identity.rawHandle(id)` and `Tls.Certificate.rawHandles(c)`, both `internal`, did not resolve, the builder had no case for the unresolved call (I0002), and `buildServerCtx`, `applyClientIdentity` and `resolveTrust` kept the AST path ("no TIR body"). The list now carries the package's own entry.
2. **`LYRIC_NATIVE_TIR_TRACE=1` prints a bundled package's builder failures** (`native via-TIR: bundled <pkg> cannot build <fn>: <first message>`), since the census prints builder errors for the user package only and a bundled function with no TIR body was silent.

## Effect

The three functions lower from TIR on native. Any bundled stdlib function that still cannot build names its reason under the trace flag.
