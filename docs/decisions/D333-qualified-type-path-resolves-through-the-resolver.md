# D333 - A qualified type path in the checked package resolves through `Lyric.Resolve` (docs/70 phase 2c, #8612)

**Status:** shipped. Follows D330; the last lookup of 2c that D315 and D322 left
on the checker's owner scan.

## Context

`resolveTypePath` resolved `Owner.Name` in type position by asking for every
symbol named `Name` (`symTableTryFindAllNamed`) and picking the one whose
`originPackage` matched the written owner, then, for a re-exporting owner,
the one declared by a package `Owner` re-exports, then a second all-symbols
scan to prefer a type over a same-named non-type. `qualifiedTypeOwnerAccepts`
accepted a symbol whose package the owner re-exports through
`tbl.packageImports`. All of that is the question `Lyric.Resolve.resolvePath`
answers by §4.3: the owner is an alias, a package the file imports or its own
package, and the member is what that package declares or re-exports (D311).

## Decision

1. **`symTableQualifiedType`** asks `resolvePath` in the scope of the file being
   checked (its siblings next, every file for a synthesised item) and returns
   the type symbol it names. `resolveTypePath` tries it first, after a
   dependency's own scope (D322).
2. **The owner-matching scan, the re-export scan and the second type-preference
   scan are deleted**, and with them the `packageImports` clause of
   `qualifiedTypeOwnerAccepts`. What remains of that function serves the two
   cases the resolver has no declaration for: a host-namespace qualifier on an
   extern type (`System.Text.StringBuilder`) and a contract surface the checker
   synthesised.
3. **A package-private type named through its package stays T0097**, imported
   or not (#7548): the resolver reports an unimported owner as unresolved, so
   this one rule is kept as an explicit lookup (`symTableTryFindInPackage`
   restricted to a package-private binding), and `symbolToType` reports it.

## Consequences

- No source change was needed: the full stdlib, compiler and ecosystem bundle
  builds, the reject corpus and every self-test pass with the scans removed.
- `symTableTryFindAllNamed` loses its largest caller. What remains is what D315
  lists as program-wide by design.

## Not done in 2c

`Lyric.TypeAliasResolve` (`alias X = T` substituted into the tree) is not folded.
Its alias table is keyed by simple name and consumed by three backend bridges
that run it on files with no resolver context, and the MSIL and JVM code
generators keep their own cross-package alias layers (its module doc, #6413).
Making it a scope entry means backends asking the resolver for an alias's
target, which is phase 2d's "backends receive resolved names". The plan is
recorded on #8612.
