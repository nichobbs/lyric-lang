# D865: a default method copied into an impl has its own span

Status: accepted (#9454, part of #7791).

## Decision

`Lyric.ImplDefaults` copied an interface's default method into an `impl` as a verbatim `FunctionDecl`, with the interface member's own span. For an `impl[T] Holder[T] for Box[T]`, a concrete call of the inherited default (`b.twice(9)` on a `Box[Int]`) then had no recorded callee on any target (I0002 "the builder has no case for a call the checker did not resolve", and "no usable type for a type parameter with no registered binder: T"): member lookups match a signature by its span, and the interface's member and the copy were one to them. The same member written out by hand worked.

The copy now gets its own span, from the impl's start to the member's end, which differs from the interface member's and between copies. Its body keeps its spans, so diagnostics inside it still point at the interface's source.

## Verification

`generic_interface_self_test.l` calls the inherited default on `Wrapped[Int]` and `Wrapped[String]` (dotnet and JVM); the native fixture `genericifaces_generic_impl.l` does the same on native (D864).
