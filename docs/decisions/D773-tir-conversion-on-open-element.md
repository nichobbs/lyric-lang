# A numeric conversion on any expression the builder types as a primitive (docs/70 phase 3a, #8613; extends D754)

**Status:** shipped; builder only.

## Context

D754 made `Character.toUpperCase(c).toInt()` build: a conversion member on a receiver the checker left untyped and `openHostChainTy` types as a primitive is that primitive's own built-in. `copied[0].toInt()` (`auto_ffi_self_test`, 341), where `copied` is a local bound to an untyped host `byte[]` result, has an open receiver of another shape: an index of an open local. `openHostChainTy` does not type it, so the gate still stopped the body.

## Decision

`buildConvMethodOnOpenPrim` takes the receiver's type from `exprOrOpenTy`, which covers every expression the builder types (a host chain, an index or a read of an open local, a host constant), not only a host chain. The guards are unchanged: no arguments, a conversion member, a receiver the checker recorded no type for, a numeric or `Char` primitive.

## Consequences

`auto_ffi_self_test` 341 builds. Test: `tir_build_self_test.l`.
