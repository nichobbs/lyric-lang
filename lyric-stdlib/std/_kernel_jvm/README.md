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

2. **Pure Lyric over the JVM auto-FFI** — `extern type` aliases for
   real JDK classes plus ordinary Lyric bodies (instance calls,
   `.new(args)` constructors, static-field/enum-constant reads).  Used
   when the JVM API differs structurally from the Lyric declaration:
   throws-on-failure vs Bool+out, multi-step operations, or absent
   equivalents (`tau`, `log2`, `truncate`, fixed-point formatting).

A third, historical pattern — shim classes under `lyric.stdlib.jvm.*` —
was retired entirely: those classes were never built, so every binding
against them crashed on first call (`NoClassDefFoundError` /
`VerifyError`; docs/44 m-89, docs/59 F-1c).  The last two holdouts,
`http_host.l` (over `java.net.http.HttpClient`) and `http_server.l`
(over `com.sun.net.httpserver.HttpServer`), were rewritten onto pattern
2 as part of #2663; no `lyric.stdlib.jvm.*` binding remains in this
directory.  The only JVM-side gaps left in those two files fail loudly
by design (Unix-socket clients and `https://` listener prefixes, which
the JDK's client/server APIs cannot express here — see the file
headers).

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
