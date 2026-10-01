# D156 — Renamed selective imports (`import P.{f as g}`)

**Status:** accepted, implemented

Resolves #7564. Builds on D155 (qualified constructor calls).
Supersedes the T0138 rule of D141 ("renaming a listed item is not
supported").

## Context

The grammar has always accepted `import P.{f as g}`, but no part of the
compiler bound `g`. D141 (#7557) made the form a clear error, T0138, until
it could be implemented. Implementing it means:
- rebinding every kind of item (functions, values, types, record and
  union constructors, a renamed union's cases);
- shadowing by locals;
- the same behaviour on MSIL, JVM and native, in the LSP, and in a
  restored package's specialised generic bodies.

## Decision

1. **Meaning.** `g` is the bare name for `P.f`, and `f` itself is not
   visible bare. The rename applies everywhere a bare name can appear:
   values, calls, constructors, type references, generic heads and
   pattern heads.
2. **A renamed union or enum** is reached through its new name, cases
   included: `Shp.Circle(r = 1)` and `case Shp.Circle(r) ->`. As always, a
   pattern against a value of the type may name a case bare. The cases
   are not made visible bare, as listing the union by its own name would
   (D141). The rename exists to avoid a clash, and exposing the cases
   bare would reintroduce one.
3. **Lowering.** `Lyric.AliasRewriter`, which already runs for every
   backend and the LSP (`pipePrepareForCheck`), rewrites each use of `g`
   to the qualified `P.f`. Every qualified form already resolves on every
   backend, and constructors do so since D155. No backend needs
   rename-specific code.
4. **Shadowing is lexical.** A parameter, local, lambda parameter,
   pattern binding, `for`, `catch` or `scope` binding, or quantifier
   binder named `g` hides the rename for exactly its own scope. A local
   hides it from its declaration to the end of its block; its own
   initializer still sees the import.

   Package aliases keep their existing function-wide approximation
   (#6311). That approximation can only suppress a rewrite, so it is safe
   for them. For a bare name it would turn a legitimate earlier use into an
   unknown-name error.
5. **Collisions are T0148.** The new name must not also be a declaration
   of the current package, another import's bare name (listed or
   renamed), a public name or case of a package imported whole, a
   package alias, or the first segment of an imported package's path.
   Otherwise one spelling would have two meanings. The alias and
   path-head cases matter because `g.member` reads as a member of the
   rename `g`: without the diagnostic, a use meant for the alias `g`
   would silently resolve to the renamed item (#7928). The rewriter also
   leaves a multi-segment path to its alias when both share the head.
6. **Contract metadata.** A renamed item is not recorded in the
   contract's `selectedImports`. The rewritten bodies the contract carries
   already spell `P.f`, exactly as for an aliased import.

## Consequences

- **T0138 is retired.**
- **Tests:**
  - `typechecker_self_test.l` covers visibility, the three shadowing
    scopes and the T0148 collisions;
  - `import_rename_self_test.l` runs renamed functions, a renamed record
    constructor and a renamed union, with shadowing, on dotnet and the
    JVM.
- **Out of scope.** A selective import that lists a name its package
  does not declare is still not diagnosed at the import, renamed or not
  (#7926). A renamed one fails at its first use, as the qualified `P.f`
  that use becomes.
