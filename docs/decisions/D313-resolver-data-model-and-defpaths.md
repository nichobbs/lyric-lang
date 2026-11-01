# D313 - `Lyric.Resolve`: the data model, DefPaths for every declaration, and the lookup (docs/70 phase 2c, #8612)

**Status:** shipped (the resolver package and its lookup; the checker does not
consume it yet, see Consequences). Step 3 of docs/70 §13 phase 2c, after D309
and D311.

## Context

docs/70 §4.3-§4.4 make one pass, `Lyric.Resolve`, the authority for every name
diagnostic (T0010, T0020, T0097, T0123, T0148). Today the type checker answers
the same questions with a stateful symbol table: a "current scope" set before
each item, a tier scan that ranks a candidate by whether the file imports the
candidate's package in any form (`symTableTryFindOne`,
`symTableBareFuncTier`, `symTableAmbiguousImportPackages`), and "find any symbol
named x" entry points (`symTableTryFindAll`). #8709 is the visible defect: a
selective or aliased import promotes every name of the package to the direct
tier. D306 gave types a DefPath but left functions and values to this step,
because overloads need a discriminator and the resolver is their first
consumer.

## Decision

1. **Identity lives in `Lyric.Symbols`, a leaf package.** `SymbolId`,
   `DefPath`, `defPathKey`, `typeDefPath`, `externTypeDefPath` and
   `symbolIdEq` moved there from `Lyric.TypeChecker`, with the interner
   (`DefPathInterner`, `internDefPath`, `freshSymbolId`, `defPathKeyOf`) that
   was a pair of fields on the symbol table. The resolver runs before the
   checker and both mint and read ids, so neither can own the type. The
   checker re-exports the package (`pub use Lyric.Symbols`), so importers of
   `Lyric.TypeChecker` still see `SymbolId`, and its symbol table now holds a
   `DefPathInterner` it shares with the resolver.
2. **DefPaths for every declaration kind.** The path is the declaring package
   and segments, rendered with `::`.
   - A type, value, constant, wire, config, aspect or scope kind:
     `Pkg::Name`. An extern type with a host name: `extern::<host name>`
     (D306, unchanged).
   - A union or enum case: `Pkg::Type::Case`, with the owner as its parent.
   - A function: `Pkg::name(P1,P2)`. The **overload discriminator is the
     parameter types as written**, comma-separated and without whitespace or
     modes, with aliases left unexpanded (`renderTypeExprKey`). The path of
     `func norm(p: in Point, k: in Int)` is `P::norm(Point,Int)`.
   - A method (in a record, protected type or interface body, or
     `func Type.method`): `Pkg::Type::name(P1)`. An impl method:
     `Pkg::Target::$impl(Iface)::name(P1)`.
   - A function of an `extern package` block: under the block's own path, the
     spelling its callers use.
3. **Why the parameter types as written, and not an ordinal or a hash.** An
   interface artifact (docs/70 §9.2) records declarations by DefPath, and a
   consumer compiled against one version of a library must find the same
   declaration in the next. An ordinal (`norm#2`) changes when someone adds an
   overload above it. A hash of the resolved signature changes when an alias
   changes meaning, and cannot be read by a person in a diagnostic or a dump.
   The text of the declared types depends on nothing but the declaration. The
   cost is that renaming a parameter type renames the path; that is also a
   source-incompatible change for a caller that names the type, and the
   interface already records the signature that the path abbreviates. Two
   overloads that differ only in parameter modes or in generic parameter names
   are not distinct overloads in the language and are rejected today as
   duplicates, so the key does not need to tell them apart.
4. **`Lyric.Resolve` has no unfiltered lookup.** `DeclTable` is filled by
   `registerItems`; the only reads are `resolveBare` and `resolvePath`, and both
   take the `FileScope` of the file the name is written in. A `FileScope` is
   built from that file's own imports (`buildFileScope`), so a package's
   files have separate scopes (docs/70 §4.1).
5. **The rule (§4.3), including the tier rule of #8709.** A bare name in file
   F of package P resolves to, in order:
   1. a local (the caller's walk answers this first);
   2. a declaration of P, from any file of P;
   3. a name F imports, ranked by **how F sees it**:
      - *direct*: the declaring package is imported whole by F, or the name is
        listed by F's selective import (a listed union or enum brings its
        cases; a renamed one does not), under its rename if it has one, or it
        is an `import extern` binding;
      - *re-exported*: the declaring package is reached only through the
        `pub use` of a package F imports whole.
      A direct candidate shadows a re-exported one. A selective or aliased
      import of a package therefore makes only the listed names, or none,
      direct. This replaces the rule "the file imports the candidate's package
      in any form".
   4. the prelude (`Option`, `Result` and their cases).
   Candidates from two packages at one step are **T0123**. Overloads of one
   package at a step are one overload set (`ROverloads`), not an ambiguity. A
   candidate that is not `pub` or `internal` and is in another package is
   **T0097** when nothing else matches; otherwise **T0020** (**T0010** in
   type position) with the hint that names the declaring package and how to
   import it, the checker's text.
6. **Paths.** `resolvePath` takes a dotted path. A leading run that is an alias
   of F, F's own package, or the full path of a package F imports in any form
   names that package; the next segment is a name it declares or re-exports
   (a declaration of the package itself wins over a re-exported one), and the
   remaining segments are members left to the checker (§4.5). A package that is
   loaded but not imported by F is **T0020**, even when an imported package
   imports it.
7. **Registration is idempotent by DefPath.** A package registered twice (as a
   source and as a dependency) interns each declaration once, and a lookup
   returns the newest registration of each, so a duplicate registration is never
   a second candidate (the cause of 36d2734).

## Plan from here

The checker is switched in two steps, so that no rule rejects code the current
compiler accepts without a census (docs/70 §12.2):

1. **Differential mode.** The resolver walks every body beside the checker
   (binding locals, parameters, generic parameters and pattern bindings) and
   every disagreement between a resolution and the checker's lookup is a test
   failure, across the compiler, the stdlib, the ecosystem libraries and the
   examples. This surfaces the places where the checker's rule and §4.3 differ,
   and each is either a resolver bug or a recorded rule change.
2. **Consumption.** The checker takes resolutions from `ResolvedPackage` and
   its own lookups (`symTableTryFindOne`, `symTableTryFindAll`,
   `symTableBareFuncTier`, `symTableAmbiguousImportPackages`,
   `symTableHiddenImportHint`) are deleted. `Lyric.AliasRewriter` and
   `Lyric.TypeAliasResolve` fold into the resolver, aliases and `import ... as`
   becoming scope entries. Backends keep resolving bare names package-wide
   until 2d.

## Consequences

- No source or behaviour change in this step. `Lyric.TypeChecker` gained the
  `pub use` and the shared interner; every id and diagnostic is as before.
- #8709 stays open until step 2 above, where the checker consumes the tier
  rule; this entry records the rule it will consume.
- `DeclTable.decls` is readable, so the "no unfiltered lookup" rule is
  structural for the lookup functions but not enforced against enumeration; the
  consumers added in the next steps do not enumerate it.

## Verification

`resolve_self_test`:
- DefPaths: a type, union and enum cases, overloaded functions (distinct
  paths and one overload set), record methods and impl methods, an extern
  type declared and imported (one id).
- The rule: own package first; whole, selective, renamed (cases of a renamed
  union not bare) and aliased imports; the re-export reach and the
  direct-over-re-export tier; #8709's case; T0097, T0020 with its hint, T0010,
  T0123 and its alias exemption, overloads versus a cross-package collision;
  qualified names through an alias and through a re-export; an unimported
  package; the prelude.
- Per-file scopes: one scope per file, a name resolved in one file and not in
  its sibling, two files importing different packages for one bare name, and
  an alias bound two ways.

`typechecker_self_test` and the rest of the suite pass unchanged.
