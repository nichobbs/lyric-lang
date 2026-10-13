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
  the sort parameters are named `Lyric!sortparam!<Record>!<T>` so no source
  sort (a type the file declares, a function's type parameter, already
  declared with `declare-sort`) is shadowed — cvc5 rejects that shadowing
  outright — and no synthesized name is either (`record Lyric[Unit]` would
  otherwise have named `Lyric!Unit`).
- A field read instantiates the field's declared sort at the receiver's type
  arguments (`instantiateRecordSort`); a receiver whose sort does not apply
  the record to one argument per parameter falls back to the old
  uninterpreted read, which fails closed.
- A constructor's type arguments are inferred from its arguments
  (`matchArgSortParams`) before they are given their fields' sorts, so a
  `Some(x)`/`Ok(x)` argument binds the parameter its payload fixes and then
  takes the instantiated field sort (an `Option[T]` field coerced at its
  uninstantiated sort made the query malformed); a type argument the
  arguments do not determine (a phantom parameter, or one only `None`
  stands for) or bind differently fails closed with V0033 rather than taking
  an arbitrary sort.
- A generic record whose fields name the record itself (`next:
  Option[Node[T]]`) stays an uninterpreted sort: a parametric datatype
  nested through another is rejected by z3 as not well-founded, and since
  every goal declared every datatype, one such record made every goal of the
  file malformed.  A goal's query now also declares only the datatypes its
  claim reaches (`reachedDatatypes`), so a declaration no obligation needs
  can never break an unrelated goal.
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
  is checked against those it may reach — the declarations taking exactly
  its argument count, else every one that fills the rest from defaults
  (`calleeCandidates`).  Which of several default-filling declarations the
  type checker binds is not a rule the language states (its signature table
  is in effect last-declared-wins), so every one is taken as reachable, the
  conservative choice; same-named fields and types keep their first
  declaration.  It sees the proved file only; the build's mode check, which
  `lyric prove` runs first, sees the merged package.
- Stability check (`S0001`): the same candidates (`callReachesExperimental`),
  with each `CallRef` now carrying its argument count.
- VC generation (`registerFileFunctions`): names are counted over the whole
  package — the proved file's functions and the other files'
  (`ScopeDecls.functions`, read from the package's files) — because the
  build merges them and the type checker resolves a call among all of them.
  A name the package declares once is reachable as before.  Overloads are
  each proved and reachable only as `name/<arity>`: a call (bare, `P.f`, or
  a dot-named method call) reaches the proved file's declaration taking
  exactly its arguments; one whose declaration of that arity is in another
  file, or that would reach one only through defaults, fails closed (V0033).
  Without the package-wide count, `add(x)` in a file declaring `add(x, y =
  100)` was proved against that declaration's contract although the program
  binds another file's `add(x)` — a false discharge the first version of
  this change made reachable (it had crashed before).  Two declarations of
  one name and arity in the package are reported (V0033, naming T0001): no
  declaration of that arity is proved and a call reaching one fails closed.
  A type declared twice in the file leaves every sort of that name
  ambiguous, so the file proves nothing (V0033 at the second declaration).
  Duplicate protected-type members are registered under neither key (no
  call reaches a member through that table).

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
(`LspState.stdlibScope`) and only for `@proof_required` documents, and each
document's builds, package file set and import scope once per path
(`LspState.docContexts`).  Each analysis compares a cheap disk snapshot
(the enclosing manifests' presence and modification times, and the `.l`
files of the package's directories) and reads the context again when it
changed, so a client that never sends `workspace/didChangeWatchedFiles` no
longer keeps a stale package (a sibling file created after the document was
opened was invisible, giving an editor-only false "all proved").  The
context is also dropped on that notification: the VS Code extension now
watches `**/lyric.toml` as well as `**/*.l`, and a client that advertises
`dynamicRegistration` is asked for both (`client/registerCapability`).  The
server proves with `lyric prove`'s defaults (`--target dotnet`, each
manifest's default features), labels goals by build when there are several,
publishes the erasure's F0012/F0013 with the verifier's diagnostics, and
reports each item no build compiles as an LSP Information diagnostic at its
declaration, where `lyric prove` lists it after its output.  Its own type
check of the document runs on what `@cfg` erasure keeps for each build
(diagnostics merged), so `@cfg` twins are no longer a T0001 duplicate there.
A document whose builds cannot be known (an enclosing `lyric.toml` that
cannot be read) is refused with B0001, as `lyric prove` refuses it, instead
of being proved standalone, and its check under the no-feature fallback is
not reported.  Two differences remain and are documented:
the server proves a document its check rejects (its check does not load the
standard library, #8304), and reports undecided goals as warnings.

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
  qualified overload, a call through defaults failing closed, `S0001`
  choosing by arity and counting every default-filling declaration, an
  overload in another file of the package (the call fails closed; the
  exact arity in this file still resolves; the same arity in two files is
  reported), `Some`/`Ok`/`None` constructor arguments, a self-nesting
  generic record beside an unrelated goal, and a record/parameter pair
  whose names join to a preamble sort's.  The #8231 `generic-impl-field` case, which
  pinned the old fail-closed read, now expects a refutation.
- `modechecker_self_test.l`: overloads and duplicates checked without
  throwing; `calleeCandidates`' choice.
- `lsp_self_test.l`: a document under a manifest whose default features
  select a `@cfg` twin is proved under that feature (no refutation, the
  inactive twin reported, no T0001 for the twins), and refuted without it; a
  document under an unreadable manifest is refused with B0001 and no type
  diagnostic; a sibling file created with no watched-files notification is
  seen on the next edit; a client advertising `dynamicRegistration` is sent
  the watched-files registration; a duplicate declaration is published as
  V0033, not thrown on.
- `scripts/ci/prove-items.sh` with `examples/prove-generic-records/`,
  `examples/prove-overloads/` and `examples/prove-overloads/sibling/` (the
  cross-file overload, in single-file and `--manifest` mode).
