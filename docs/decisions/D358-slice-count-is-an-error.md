# D358 - `.count` on a slice is the error T0228 (docs/70 phase 3a)

**Status:** shipped. Follows D354, which introduced the warning W0042.

## Context

D354 typed host members and found that `--target dotnet` accepted `xs.count`
on a `slice[T]` (lowered to the host array's `Length` member) while
`--target jvm` rejected it. The member is `.length`; `.count` is the size member
of `List`, `Map` and `Set`. D354 made the dotnet-only acceptance the warning
W0042 so the sources could migrate.

## Decision

`.count` on a slice is the error T0228. The read is still typed `Int`, so one
mistake is one diagnostic. The one source that needed migrating,
`lyric-grpc/src/_kernel/jvm/grpc_kernel.l` (`entries.count` on the slice
`Types.decodeMetadata` returns), reads `.length`. The compiler, the stdlib, the
library manifests (dotnet and JVM), the examples and the stdlib tests report no
other W0042 site.

W0042 is retired (the appendix table says so); an error needs a T-series code.

## Tests

`typechecker_self_test.l`: `slice.count` is T0228 and `slice.length` is clean.
