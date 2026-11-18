# D420 - A qualified construction through an alias or a re-export has a callee (docs/70 phase 3a, #8613)

**Status:** shipped; extends D388 (the construction signature in the symbol table).

## Context

`L.Leaf(v = n)`, with `import Pu as L` and `Leaf` declared in `Pu.Inner` and re-exported by `Pu` (`pub use Pu.Inner`), was typed by the checker but recorded no callee and no signature: `constructorSymbolOf` looked the qualifier up as a package name (`L` is an alias, and `Pu` is not the declaring package), then fell back to a bare-name lookup only for a callee written as one path. The builder counted the construction as "a call the checker did not resolve" (I0002): `Pu.Main::leafOf` in the native project self-tests.

## Decision

`constructorSymbolOf` also asks the resolver for the qualified name (`symTableQualifiedType`, which follows an alias and a package's re-exports, docs/70 section 4.3) and accepts a record, exposed record, opaque or protected type it names. The checker's use of the result is unchanged, so the construction now records its callee and signature like an unqualified one.

## Results

`scripts/ci/tir-builder-shapes-e2e.sh` builds a three-package project whose consumer constructs a record and calls a function through an alias of a re-exporting package: every body builds and the verifier reports nothing (the shape fails on the compiler without this change, one of two bodies built).
