# D141 — Bare names resolve only through the file's imports (docs/01 §9.2)

**Status:** accepted, implemented

Resolves #7463 and #6703. Follows D140, which made JVM constructor scope
mirror a checker that was wider than the language reference.

## Context

docs/01 §9.2 lists three import forms (whole, selective `import P.{f}`,
aliased `import P as Q`) and says every imported name is explicit. The type
checker did not enforce any of it. `symTableTryFindOne` resolved a bare name
in three tiers: the current package, any imported package whatever the import
form, then any loaded package at all (last-registered-wins). So a selective
import exposed every name of its package, an aliased import exposed them
bare as well as through the alias, and a name from a package the file never
imported still resolved (#6703; an earlier attempt to close that in #6287 was
reverted because of the undeclared `Std.Core` prelude, since addressed by
D-progress-0902's `import Std.Core` sweep and the §9.1 prelude text).

## Decision

A bare name used in a file resolves to a declaration from another package
only when the file's imports make it visible:

1. **Whole import** (`import P`): every name of `P`, and transitively every
   name of each package `P` imports (the kernel/host idiom:
   `Std.Collections` imports `Std.CollectionsHost`).
2. **Selective import** (`import P.{f, T}`): only the listed names, plus the
   cases of a listed union or enum type. An item renamed with `as` is
   visible under both names.
3. **Aliased import** (`import P as Q`): no name bare; `Q.f` as before.
4. **Prelude**: `Option` and `Result` from `Std.Core`, with their cases.

A pattern names a case of the scrutinee's own type whatever the imports: a
match over an aliased package's enum still writes `case Dotnet ->`. Before
this rule a hidden case name would have parsed as a fresh binding.

A name that exists but is hidden is **T0020** (**T0010** in type position)
with a hint: `(declared in P; add import P or import P.{f})`, `(declared in
P, imported as Q; write Q.f)`, or, for a kernel host package, `(declared in
Std.CollectionsHost; add import Std.Collections)`. A hidden name is never a
candidate for the T0123 ambiguity check.

The rule applies to the file being checked. An imported package's own
signatures are resolved without it: they were checked under the rule when
that package was compiled.

## Implementation

- `SymbolTable` carries the rule (`importRulePkg`, `importVisiblePkgs`,
  `importVisibleNames`, `importAliases`), installed by
  `installImportRule` in `checkWithImportedPackagesCore`.
- `symTableTryFindOne` and `symTableAmbiguousImportPackages` skip hidden
  candidates; `findDirectSig` filters bare function candidates with
  `symTableBareFuncVisible`, since functions resolve through the signature
  map.
- The JVM constructor scope counts whole imports only (`~ctor-pkgs~`,
  reversing D140's "every import form"); a selective import resolves its
  listed names and the cases of a listed union (`~ctor-import~`,
  `~ctor-sel~`); the packages the whole imports reach come last
  (`~ctor-tpkgs~`).  Specialised copies of another package's generics get
  the same keys for their origin package (`~wimport~`, `~selimport~`).
- The MSIL backend's bare-name resolvers (union cases, types, free
  functions) search in the checker's order: whole imports and selective
  imports first, then the packages the whole imports reach; aliased imports
  are left out (`CodegenCtx.pkgBareImports`, `bareImportsOfMsil`).  A
  selectively imported package admits only its listed names, and a union's
  cases when the union is listed (`bareImportAdmitsMsil`).  A type is taken
  from a direct import before a transitive one.  A qualified case
  (`MA.Square`, rewritten to `EPAx.Marks.Square`) prefers the case declared
  in the package its qualifier names.
- MSIL enum case ordinals follow the declared type: a qualified annotation
  (`val m: B.Mode`) records `EPEn.B::Mode`, so a bare `case Fast ->` over it
  resolves in that package; a simple name is looked up through the bare
  imports, then every import (an enum reached through an alias is still
  named by its annotation).
- An `impl` of another package's interface checks the interface's method
  signatures resolved in the interface's own package, not in the
  implementing file's scope.
- `Lyric.AliasRewriter` now rewrites alias-qualified lambda parameter types
  (`{ c: TlsHost.CertHandle -> ... }`), which only resolved before through
  the permissive tier.
- A `where` constraint written through an alias (`where T: Log.Logger`) no
  longer collapses to the bare `Logger` (#1874), which the rule hides; it
  becomes `Std.Log.Logger` and the checker resolves it in that package.
  Resolved bounds record each interface constraint package-qualified, so a
  call site checks it against the declaring package's interface whatever the
  caller imports.
- The restored-dependency packages handed to the checker carry the imports
  their contract records (`Contract.imports`), not only those of the
  synthesised source, so the transitive rule reaches through a restored
  library (`import Grpc` reaches `Grpc.Types`).

## Consequences

Tree-wide, the rule needed:

- Stdlib: `import Std.Collections` in `path.l`, `console.l` and `hash.l`;
  alias-qualified names in `_kernel/http_server.l` and the regex tests.
- Compiler: about 210 alias-qualified references in `Lyric.Cli`,
  `Lyric.Emitter`, `Lyric.Pipeline` and `Lyric.Discovery` (including
  `Mf.ManifestError.message(...)`, which the unimported-receiver check now
  reports), and imports added to the programs embedded in the project-level
  self-tests.
- Ecosystem: `lyric-i18n` (`File.readText`), `lyric-web` (`import
  Std.Iter`), `lyric-forms`, `lyric-ui` and `examples/ui-customers` (`import
  Std.Collections`), and `lyric-testing`'s tests (`StdTesting.` names).

The reverted-harsher-rule caveat in docs/01's T0123 paragraph is gone.
#7512 records a separate gap found on the way: a package-qualified call does
not report an argument that fails an interface parameter.
