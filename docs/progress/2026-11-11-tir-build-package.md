# TIR builder: `buildPackage`, a checked file as a whole package (D570, #8613)

Docs/70 phase 3a: `Lyric.Tir.Build.buildPackage` returns a `PackageBuild` (a `TPackage` with one `TFnDecl` per
built function keyed by symbol, the failed bodies by name with their I0002 messages, a DefPath key per symbol and
the cases of each union in declaration order). It is the entry point the native backend's TIR path (phase 4a)
builds against; `buildCensus` is now a caller of it. Top-level functions only; methods, impl members and protected
entries follow. Phase 3a is not complete: I0002/I0003 do not stop the build yet.
