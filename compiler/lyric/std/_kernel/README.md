# Stdlib kernel

Per `docs/14-native-stdlib-plan.md` §3 and Decision F (D038), this
directory is the audited extern boundary for `Std.*`. Files here may
contain `@externTarget("System.X.Y")` and
`extern type T = "System.Foo"` declarations that bottom out at the
.NET BCL or other host runtime surfaces.

## What lives here

Every Lyric stdlib module that depends on a host operation that
cannot be expressed in pure Lyric — syscalls (file/network/console),
hardware-tuned BCL primitives (transcendentals, regex, JSON
tokenizer, TLS), threading primitives, IEEE 754 corner cases.
Anything else lives in the parent `compiler/lyric/std/` directory
as a native Lyric implementation.

## What does NOT live here

Native Lyric code. Pure-Lyric algorithms over `slice[T]`, primitives,
records, sum types, and other kernel modules belong in the parent
directory. If you find yourself writing `@externTarget` in a
non-kernel file, the convention is broken — move the declaration
here and `import` it from your safe-API module.

## Hard cap

Decision F sets a v1.0 release gate of **150 extern declarations
across the whole kernel**. Auditing 150 is tractable; auditing 500
is not. PRs that push the count toward the cap should justify each
new declaration in their description.

## Discovery

The build/test machinery (`Emitter.fs::locateStdlibFile`,
`Cli/Program.fs::locateStdlibFiles`,
`tests/Lyric.Emitter.Tests/StdlibSeedTests.fs::loadStdlibBody`)
recurses into this subdirectory. Top-level files shadow same-name
kernel files on collision so a future native rewrite of a kernel
module wins without manual cleanup.

## See also

- `docs/14-native-stdlib-plan.md` §3 — kernel contents & rationale
- `docs/14-native-stdlib-plan.md` §6 P0 — migration log
- `docs/03-decision-log.md` D038 — umbrella decision (Resolution F)
