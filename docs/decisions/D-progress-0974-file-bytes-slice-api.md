# D-progress-974 — `Std.File.readBytes`/`writeBytes` take and return `slice[Byte]` (#7305)

**Status:** shipped

## Problem

`docs/10-stdlib-plan.md` specifies the byte-mode file API as

- `File.readBytes(path: in String): Result[slice[Byte], IOError]`
- `File.writeBytes(path: in String, bytes: in slice[Byte]): Result[Unit, IOError]`

but what shipped used `List[Byte]` for both. On `--target dotnet` and
`--target jvm` the read side then copied the host's `byte[]` into a fresh
`List[Byte]` one element at a time, and nearly every caller immediately
called `.toArray()` to get a `slice[Byte]` back. The metadata readers in
`Msil.MetadataReader` read ~80 reference-pack assemblies on every MSIL
compile this way; profiling a linked `lyric test lexer_self_test.l` put
about 8 s of a 16.5 s compile in that copy.

## Decision

Change both functions to the planned signatures (a breaking change to the
public `Std.File` surface), rather than adding a second slice-returning
reader beside `readBytes`:

- **Kernels, all three targets.** `hostReadBytesResult` returns
  `Result[slice[Byte], IOError]` and `hostWriteBytesResult` takes
  `slice[Byte]`. On .NET and the JVM the read wraps `hostReadAllBytes`
  directly (no copy) and the write passes the slice straight to the host.
  On native, `slice[T]` and `List[T]` share one representation (D-N-015),
  so `rtReadBytes`/`rtWriteBytes` are re-declared over `slice[Byte]` with no
  runtime change, and `hostReadAllBytes` no longer copies the buffer.
- **Callers.** Code that read bytes and then called `.toArray()` drops the
  copy (`Std.Tls`, `lyric-web` static files, the 15 `Msil.MetadataReader`
  sites). Read-only byte consumers take `slice[Byte]` (`Lyric.AppHost`'s
  `bindAppHost`/`findBytes`, `Jvm.Reader`). Code that builds bytes
  incrementally in a `List[Byte]` (the MSIL and JVM emitters, the numbered
  backend self-tests) calls `.toArray()` once at the `writeBytes` call,
  which is the same copy the kernel previously made internally.

A second function would have left two readers with different return
types, the plan and the shipped API still disagreeing, and read-then-write
code converting in both directions.

### Supersedes the `readByteSlice`/`writeByteSlice` pair

While this change was in review, #7360 (#7284) landed the alternative this
entry rejects: `@experimental` `readByteSlice`/`writeByteSlice` beside a
`List[Byte]` `readBytes`/`writeBytes`, with `docs/10-stdlib-plan.md` edited
to describe both. With `readBytes`/`writeBytes` now slice-typed, the pair
is the same two functions under a second name, so both are removed along
with their kernel twins (`hostReadByteSliceResult`,
`hostWriteByteSliceResult`, native `rtReadByteSlice`/`rtWriteByteSlice`).
Their callers call `readBytes`/`writeBytes`, their tests now exercise
`readBytes`/`writeBytes`, and the plan is restored to the single
slice-typed pair. They were `@experimental`, so removal carries no
stability obligation.

## Result

`lyric test lexer_self_test.l` (linked compiler DLLs): 16.5 s to about
11 s on a 4-vCPU sandbox, following #7220 and #7289, which took it
from 123 s to 16.5 s.
