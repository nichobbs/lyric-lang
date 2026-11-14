# D483 - The builder reads open type arguments from context, converts branches and constructions, and records package-qualified callees (docs/70 phase 3a, #8613)

**Status:** shipped; extends D481 and D482.

## Context

After D482 the compiler census (dotnet, per-package emit) had 11708 -> 12152 of 12767 bodies built. The 600 left were not the
named `no builder case` kinds but bodies failing with "the checker gave no usable type for an expression ... `<error>`": the
checker records an open type argument as a hole when only the context fixes it, and the builder failed on the hole.

## Decision

- **Open type arguments.** A generic call whose recorded arguments are holes reads them off the type its context fixes
  (`unifyOpenArgs` over the signature's return type and the settled `Ty`) and the parameter types under those arguments
  (`substOwnerArgs`, new in `Lyric.Tir`), carried to argument building in `BuildEnv.ptyOverride`. An annotated binding settles
  its initializer to the annotation before building it (`buildInit`), as an argument settles to its parameter.
- **A branch or construction at another type.** `convertValue` also takes a union-case construction used at the same union with
  other type arguments (`Some(value = x)` of an `Option[Sub]` where an `Option[Iface]` is expected, `None`): the case is built
  again at the target's arguments, each field converted there (`retypeConstruct`). A branch takes the same conversions as an
  argument (an interface upcast).
- **Never completing.** A `match` or `if` whose every branch leaves (`return`, `throw`, `break`, `continue`) has no join type;
  the builder types it `Never`.
- **Callees.** `recordCalleeSite` records `Pkg.Type.f(x)` and `Alias.Type.f(x)` (a dot-named function written through its
  package); a package-qualified distinct factory `Pkg.Type.tryFrom(s)` builds. A `Task[T]` handle passed as the host's `Task` is
  a `CvBoxToHost` node in any argument. A literal default of a source-loaded package with no registered interface builds from
  the literal's own type (`buildForeignLiteralDefault`).
- Conversion messages name the types (`renderTyNamed`); the census prints up to 60 first errors per package.

## Results

Compiler census: 12152 -> 12673 of 12818 bodies built, I0003 0. `scripts/ci/tir-builder-shapes-e2e.sh` (run by
`tir-census.sh`) builds and runs one program per shape.

## Not covered

The remaining bodies are in the kinds other sessions own (host members and extern calls, `Option`/`Result` accessors, opaque
constructions) and extern-signature nodes in the `_kernel` files; the census lists them per kind.
