# D557 — Std.Task, Std.HttpServer, Std.TcpHost and Std.Jvm are experimental at v1.0

**Status:** accepted

Context: these four packages live in `lyric-stdlib/std/_kernel/` and are
imported directly by programs, but had no stability annotation (#8928). PR #8955
annotated every `pub` item in them, including their `_kernel_jvm/` and
`_kernel_native/` twins, `@experimental` as a default, pending the project
lead's choice.

Decision (project lead, 2026-11-09): accept that default. `Std.Task` (the
docs/68 API is unbacked), `Std.HttpServer` (in flux with the docs/61 engine
work), `Std.TcpHost` and `Std.Jvm` are `@experimental` at v1.0 and outside the
SemVer guarantee. Promoting one later is an annotation change plus a move
between the tables of `lyric-stdlib/STABILITY.md`, and is a minor-version
change.
