# Stdlib kernel — JVM target

Per D041, this directory is the JVM-target counterpart of
`stdlib/std/_kernel/`.  The build driver selects this directory when
`--target=jvm` is active; package names are identical to the .NET
kernel so the safe-API layer (`stdlib/std/`) needs no changes.

## What lives here

Every JVM-target extern binding for a Lyric stdlib module that cannot
be expressed in pure Lyric — console/file I/O, transcendentals, regex,
JSON parsing, HTTP, threading primitives, IEEE 754 corner cases.

Files shadow their .NET counterparts by package name.  The emitter
loads from this directory when compiling for JVM and from `_kernel/`
otherwise; a file present in both directories means the JVM version
wins when `--target=jvm` is active.

## Routing strategy

Two routing patterns appear throughout this directory:

1. **Direct JVM target** — `@externTarget("java.lang.Math.sin")`.
   Used when the JVM standard library provides a direct static method
   or static field with semantics matching the Lyric declaration.

2. **Shim class** — `@externTarget("lyric.stdlib.jvm.FooHost.bar")`
   or `extern package lyric.stdlib.jvm.FooHost { ... }`.  Used when
   the JVM API differs structurally: throws-on-failure vs Bool+out,
   `long` vs `Double` parameters, multi-step operations, or absent
   equivalents (`tau`, `log2`, `truncate`, `tryGetValue`).  The shim
   classes in `lyric.stdlib.jvm` are the Phase 6 Java-side
   deliverable; their signatures are determined by the `@externTarget`
   strings here.

## What does NOT live here

Native Lyric code.  Pure-Lyric algorithms belong in the parent
`stdlib/std/` directory.  If you find yourself writing `@externTarget`
in a non-kernel file, move the declaration here.

## Hard cap

Same 150-declaration cap as the .NET kernel (D038 / D041).  Count
must stay below the cap before the JVM target ships.  A parallel
`KernelBoundaryTests` probe must be added to
`bootstrap/tests/Lyric.Emitter.Tests/KernelBoundaryTests.fs` before
release (tracked in D041).

## See also

- `stdlib/std/_kernel/README.md` — .NET kernel (same structure)
- `docs/03-decision-log.md` D041 — this directory's rationale
- `docs/18-jvm-emission.md` — JVM lowering strategy
- `docs/18-jvm-emission.md` Q011 — JVM stdlib API surface (deferred)
