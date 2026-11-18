# D425 - A union case constructed through an alias or a re-export has a callee (docs/70 phase 3a, #8613)

**Status:** shipped; extends D420 (the same for records) and D388.

## Context

`L.Circle(r = 3)`, with `import Pu as L` and `Circle` a case of a union declared in `Pu.Client` and re-exported by `Pu` (`pub use Pu.Client`), was typed by the checker but recorded no callee and no signature: `unionCaseSymbolOf` matched a qualifier only as the declaring package or as the parent union's name, and `L` is neither. The builder counted the construction as "a call the checker did not resolve" (I0002): `Pu.Main::main` in the native project self-tests.

## Decision

`unionCaseSymbolOf` also asks the resolver for the qualified name (`symTableQualifiedCase`, which follows an alias and a package's re-exports, docs/70 section 4.3) after its own tiers fail, and accepts a union case it names. The checker's use of the result is unchanged, so the construction records its callee and signature like an unqualified one.

## Results

The new `facade_qualified_case` shape in `scripts/ci/tir-builder-shapes-e2e.sh` builds a three-package project whose consumer constructs a case through the facade's alias: every body builds with no I0003 (one of one bodies of the consumer; it did not build before).
