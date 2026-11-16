# D493 - A host class result is typed as the extern type that names it (docs/70 phase 3a, #8613)

**Status:** shipped; refines the host-result rule of D365.

## Context

`externMemberResult` left every host class result unchecked (`tyErrorHost`), on the reasoning that a kernel may bind a host method's class result at a different declared type (`generateCertificate`'s `Certificate` as an `X509Certificate`). The consequence for TIR is that a chain of host calls (`Instant.now().atOffset(z)`, `SB.new().Append("a").Length`) has an untyped receiver for every call after the first: the second call records no callee and the whole body stays counted (I0002, "a call the checker did not resolve"). The kernels (`Std.TimeHost`, `Std.HttpHost`, `Std.HashHost`, `Std.RegexHost`, ...) are full of such chains.

## Decision

A host class result is typed as the `extern type` in scope whose host name matches it exactly (the lookup a `for` loop over an extern type already used, `findExternTypeForHost`). A host class with no `extern type` naming it, the root object type, the host string and the primitives Lyric has no type for stay unchecked, as before.

## Results

The standard library census goes from 2434 to 2443 of 2563 function bodies built, 0 I0003, and no program in the census newly fails to type-check, so the downcast case the old comment feared does not occur in the standard library, the compiler or the ecosystem. `tir-builder-shapes-e2e.sh` gains `host_class_result_chain` (a `StringBuilder` chain continued through its `Length` property, exit 3).

Still counted: a host `String` result (`Typ.GetType(..).ToString()`), because the host string may be null and the checker has no nullable `String` result type; typing it is a separate decision.
