# D314 - The checker takes bare-name answers from `Lyric.Resolve` (docs/70 phase 2c, #8612, #8709)

**Status:** shipped for the checked package's own scope; the old lookup stays
for the cases listed under Consequences. Step 4 of docs/70 §13 phase 2c, after
D313.

## Context

D313 added the resolver and a differential mode that reported disagreements with
the checker's lookup; a census over every project found none. The checker still
answered every bare name from its own scan (`tryFindOneCore`, the tier rule of
`symTableBareFuncTier`, `symTableAmbiguousImportPackages`), so #8709 stayed open:
a selective or aliased import promoted every name of its package to the direct
tier.

## Decision

1. **The resolver context is always built**, not only under
   `LYRIC_RESOLVE_DIFF`. It is registered from the same items the checker
   registers, against the checker's interner.
2. **A resolved id maps back to a checker symbol by DefPath.** Types already
   carry the id. A union or enum case is its parent's key plus the case name; a
   function is `funcDefPath` of its package, name and parameters; any other
   declaration is `Pkg::Name`. `symbolOfDefId` indexes symbols lazily, newest
   registration winning, so registration order does not matter and `Symbol`
   itself gains no field.
3. **`symTableTryFindOne` asks the resolver first** for a name written in the
   checked package under its import rule: the file being checked
   (`resolverFileFor`), or file 0 of a single-file package. An overload set
   answers with its newest function (the overload pick stays the caller's). The
   checker's scan answers when the resolver does not: a built-in, an
   `import extern` binding, a name only a sibling file imports (T0219), or a
   synthesised item of a package of several files.
4. **Function tiers become membership.** `symTableBareFuncTier` is 0 for a
   function declared by a package among those the resolver binds the name to
   and -1 for any other, which is what the tier rule computed.
5. **Ambiguity is the resolver's T0123** for a single-file package
   (`symTableAmbiguousImportPackages`). A package of several files keeps the
   union of its files' imports, because backends resolve a bare name
   package-wide until phase 2d (#8690).
6. **Differential mode now compares the two answers.** `R0001` carries the span
   of the item being checked and labelled sides ("no declaration", the code, the
   declaring package). `scripts/ci/resolve-diff.sh` runs it over every project
   in CI and fails on any `R0001`.

## Consequences

- #8709 is fixed: `import Facade.{Cell}` with `import Host` makes `Row` Host's.
- Not yet deleted: the scan is the answer for a dependency package's signature
  scope (the resolver has scopes for the checked package only, until interface
  artifacts replace the synthesised dependency surface in phase 5), for the
  sibling-file and union cases, and for built-ins.
- The tier rule no longer exists for the checked package; the rest of the
  scan's tier code serves dependency scopes.
- Expansion-introduced names (docs/70 §4.4): an import a pass adds to the
  package is in every file's resolver scope (D313). Items an expansion
  synthesises carry no file and are judged by the union, as before; binding the
  names an expansion introduces by the id the generator chose is phase 3.

## Verification

`typechecker_self_test` (a case for #8709) and the existing 1056 cases,
`resolve_self_test`, the reject corpus, and the census (`resolve-diff.sh`).
