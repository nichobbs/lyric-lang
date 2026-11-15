# D473 - An `@externTarget` function is a TIR declaration with no body (docs/70 §6.2, #8613)

**Status:** shipped.

## Context

The stdlib's JVM kernels declare host-implemented functions as `@externTarget("java.util.ArrayList.<init>") pub func newList[T](): List[T] = ()`: the `()` is a placeholder body that is never run and that the checker never types (`checkFunctionBody` skips an `@externTarget` function). The builder tried to build the placeholder and recorded I0002 "the checker recorded no type for expression node" for it. The stdlib closure is built once per file, so the same ~19 kernel bodies (`newList`, `newMap`, `newSet`, `mapKeys`, `hostAppend`, ...) counted once per JVM self-test: about 1,200 of the wide census's 1,969 self-test I0002 (found by main builder part 10's re-measurement).

## Decision

`buildPackage` describes an `@externTarget` function by its signature alone (`buildFnSigDecl`): a `TFnDecl` with `body = None`, as the language treats it (the target is the host's, not the source's). It counts as built. `hasExternTargetAnnotation` is exported from the checker for it.

## Not covered

The census script still counts each stdlib body once per file; deduplicating sites across files is a script change (D474 or later).
