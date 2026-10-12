# Generic records in proofs; duplicate names never throw; the editor proves what `lyric prove` proves (#8340, #8341, #8342)

## Generic records are parametric datatypes (#8340)

`goalsForFileInScope` registered every non-generic record as an SMT datatype
and skipped generic ones, so `Box[T]` stayed an uninterpreted sort of arity
one and a field read on it (`b.n`, `self.n` in a method, `result.v` of a
`Box[Int]`) became the uninterpreted `$field.n`, whose sort `field.n` clashed
with the field's declared sort: V0033, in functions and (since #8231 verifies
them) methods alike.

A generic record is now one parametric datatype, a sort parameter per type
parameter: `(declare-datatypes ((Box 1)) ((par (Box!T) ((Box (Box__n Int)
(Box__v Box!T))))))`.  This is the encoding the verifier already used for
the standard `Result`/`Option` (`Lyric!Result`, `Lyric!Option` in the
preamble), and it fits the existing sort representation: `SDatatype` already
carries type arguments, and `Box[Int]` already rendered as `(Box Int)`.  One
sort per closed instantiation was the alternative; it would need every
instantiation collected up front, and could not model `Box[T]` inside a
generic function or a method of `Box`, where `T` is an uninterpreted sort,
without a second mechanism.

- `DeclDatatype` gains `params`; the SMT renderer emits the `par` form, and
  the sort parameters are named `<Record>!<T>` so no source sort (a type the
  file declares, a function's type parameter, already declared with
  `declare-sort`) is shadowed — cvc5 rejects that shadowing outright.
- A field read instantiates the field's declared sort at the receiver's type
  arguments (`instantiateRecordSort`); a receiver whose sort does not apply
  the record to one argument per parameter falls back to the old
  uninterpreted read, which fails closed.
- A constructor's type arguments are inferred from its field values
  (`matchSortParams`); a type argument no field determines (a phantom
  parameter) or two fields bind differently fails closed with V0033 rather
  than taking an arbitrary sort.
- z3 4.8 resolves a constructor of a parametric datatype only at an instance
  it has already seen (the reason #8108 declares a `lyric!inst!<k>` constant
  per `Result`/`Option` instance); without it the query was malformed.  Every
  applied sort's instance is now declared the same way.
- A generic record named `Result` or `Option` keeps its old uninterpreted
  treatment (its sorts are renamed apart from the preamble's).
- Equality on generic records stays unmodelled (fails closed), and a field
  whose type is a type parameter carries no width or range fact even at an
  instance that would give it one — both conservative.

## Duplicate names never throw (#8341)

The verifier, its mode check and its stability check each built a
`Map[String, ...]` keyed by item name with `add`, which throws on a second
key.  `lyric prove` type-checks first (#8227), but the language server proves
without that gate (#8304), so a file with a duplicate declaration crashed the
request.  Worse, the same tables threw on top-level functions overloaded by
arity, which the language admits: `lyric build` of any `@proof_required` file
with such overloads failed with "MSIL codegen failed: An item with the same
key has already been added" (the mode checker's callee table).

- Mode check: the callee table holds every declaration of a name, and a call
  is checked against those it may reach — the declarations taking exactly its
  argument count, else the first that fills the rest from defaults
  (`calleeCandidates`, the type checker's overload choice); same-named fields
  and types keep their first declaration.
- Stability check (`S0001`): the same overload choice
  (`callReachesExperimental`), with each `CallRef` now carrying its argument
  count.
- VC generation (`registerFileFunctions`): a name declared once is reachable
  as before.  Overloads are each proved and reachable only as
  `name/<arity>`; a call (bare, `P.f`, or a dot-named method call) reaches the
  overload taking exactly its arguments, and one that would reach a
  declaration only through defaults fails closed (V0033) — resolving that
  case was not needed to stop the crash and is left conservative.  Two
  declarations of one name and arity are reported (V0033, naming T0001): no
  declaration of that arity is proved and a call reaching one fails closed.  A type
  declared twice leaves every sort of that name ambiguous, so the file proves
  nothing (V0033 at the second declaration).  Duplicate protected-type
  members are registered under neither key (no call reaches a member through
  that table).

## The language server proves what `lyric prove` proves (#8342)

`analyzeAndStore` proved every document with `proveSourceInScope`, the
default build (dotnet, no features) and an empty import scope, while `lyric
prove <file>` proves under each manifest's build and reads the standard
library's and the projects' declarations.  The build selection is now one
function: `Lyric.Manifest.resolveFeatureSelection` (moved from the CLI's
`resolveManifestFeatures`, which delegates to it, so `lyric build`, `test`
and `prove` all use it), `Lyric.Discovery.sourceBuildsForFile` /
`manifestSourceBuild` (the builds that compile a file), and
`Verifier.proveBuildConfigsForSource` over them, which both `cli_prove.l` and
the server call.  The import scope is shared the same way
(`Verifier.importScopeWithManifests`, `Lyric.Discovery.manifestsListingSource`);
the server reads the standard library's declarations once per process
(`LspState.stdlibScope`) and only for `@proof_required` documents.  The server
proves with `lyric prove`'s defaults (`--target dotnet`, each manifest's
default features), labels goals by build when there are several, publishes
the erasure's F0012/F0013 with the verifier's diagnostics, and reports each
item no build compiles as an LSP Information diagnostic at its declaration,
where `lyric prove` lists it after its output.

#8339 (the build/prove disagreement for a file under a manifest that does
not list it, and `lyric build`'s silently ignored `--features` for a file with
no manifest) is not changed here: `lyric build <file>` deliberately takes the
nearest manifest's dependencies and features for an unlisted file (D123),
while `lyric prove` and its type check build such a file alone.  Making them
agree means choosing one of those semantics for both commands and changing
`typeCheckForProveFile` with it, which is a design decision rather than a
consequence of sharing the selection function.

## Tests

- `verifier_self_test.l`: generic-record field reads in a generic function,
  at a closed instance and of a type-parameter-typed field; methods of a
  generic record; construction, a two-parameter swap and the phantom
  parameter that fails closed; duplicates (functions, types, fields,
  protected members) reported without throwing; overloads by arity, a
  qualified overload, a call through defaults failing closed, and `S0001`
  choosing the overload by arity.  The #8231 `generic-impl-field` case, which
  pinned the old fail-closed read, now expects a refutation.
- `modechecker_self_test.l`: overloads and duplicates checked without
  throwing; `calleeCandidates`' choice.
- `lsp_self_test.l`: a document under a manifest whose default features
  select a `@cfg` twin is proved under that feature (no refutation, the
  inactive twin reported), and refuted without it; a duplicate declaration
  is published as V0033, not thrown on.
- `scripts/ci/prove-items.sh` with `examples/prove-generic-records/` and
  `examples/prove-overloads/`.
