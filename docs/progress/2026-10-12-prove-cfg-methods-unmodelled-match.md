# `lyric prove`: the build's `@cfg` items, methods verified, unmodelled match arms fail closed (#8325, #8231, #8230)

Three ways `lyric prove` reported something other than the program the
build compiles.

## The proof is of the build's `@cfg`-erased items (#8325)

The verifier driver (`Lyric.Verifier.proveSourceInScope`) parsed the source
and went straight to the mode check, the stability check and VC generation,
all of which key items by name (`Lyric.ModeChecker.calleeTableOfFile`,
`Verifier.checkCallGraph`, the VC generator's callee table).  `@cfg` erasure
ran only in the build's front end (`Lyric.Pipeline.pipeParseAndErase`), so
two declarations of one name gated by exclusive predicates
(`@cfg(feature = "a")` / `@cfg(not(feature = "a"))`, or a `target` pair)
were both present and `lyric prove` crashed with "An item with the same key
has already been added".  It did so on every file with such twins, whatever
its verification level, because the stability check runs before the level
is looked at: 13 files of lyric-storage, lyric-mail, lyric-jobs,
lyric-search, lyric-aws-secrets and lyric-web (`src/web.l` and three test
files) crashed on `main`.

The driver now takes the build it proves (`ProveBuildConfig`: target,
active features, declared features) and runs `Lyric.Cfg.applyCfgErasure`
with the target pseudo-feature (`Cfg.withTargetFeature`) right after
parsing, before any other pass; a malformed predicate or undeclared feature
(`F0012`/`F0013`) stops the proof.  `lyric prove` passes the builds its type
check (#8227) already uses: for a file, one per manifest whose entries list
it, with that manifest's features resolved for the flags given
(`resolveManifestFeatures`, as `lyric build` resolves them), or the target
alone for a file no manifest lists (`lyric build <file>` ignores
`--features` there too); for `--manifest`/project mode, the project's.  A
file two builds compile differently is proved under each
(`proveSourceForBuilds`).  The language server's proofs use the default
build (`dotnet`, no features).

## Methods are verified (#8231)

`goalsForFileInScope` generated goals for top-level functions and protected
types only: a method in a record body, an `impl` method and an interface's
default method were never verified, so their `assert`s, the preconditions of
the calls they make and their `ensures:` were unchecked while the file
reported success.  They are now verified like functions
(`goalsForMethod`): the receiver `self` is a parameter of its declared type
(`Self` read as the `impl` target), the type's parameters are in scope beside
the method's own, a field named without `self.` is resolved to `self.<field>`
with the type checker's scoping (`Lyric.SelfFields`, so a parameter or local
of the field's name shadows it), and a bare call of a sibling method is the
call on `self`.  `self` itself (`ESelf`) is translated as that parameter;
before it was an unmodelled expression.  Goals are labelled
`<Type>.<method>`.

An `impl` method is also checked against the `requires:`/`ensures:` of the
interface method it implements (docs/01 §6.1.1), matched to its parameters
by position: the clauses are translated with the interface's parameter
names bound to the implementation's terms (`withInterfaceParamNames`, which
reads every binding before making any, so swapped names stay apart).  The
interface is looked up among the file's declarations and those of the
package's other files (`PackageScope.interfaces`, collected with the
sibling type names of #8108).  An interface declared in another package has
clauses the verifier cannot see, so such an `impl` fails closed (`V0033`), as
does an interface name declared more than once.

A method's contract is still not assumed at its calls (a call on a
receiver stays an uninterpreted function) — the other half of #8110, which
stays open with the heap-model question.  A generic record's field is not
modelled, so reading one in a method fails closed (`V0033`), as it does in a
function.

## A goal on an unmodelled `match` arm fails closed (#8230)

Two defects made a postcondition over a `match` provable when it was false:

* `matchCondKind` read every bare pattern name as a binding, which matches
  unconditionally, so `case R -> true; case G -> false` on an enum proved
  `ensures: result`: the first arm was taken for every value.  The type
  checker reads a bare name as a case whenever a case of that name is in
  scope (#8264).  The verifier now does the same with what it can see
  (`bareNameBinds`): a name that is a case of an enum or union the file
  declares, or `None`, is a case; otherwise it binds where the scrutinee's
  type has no case it could name (a primitive, slice, tuple, `Unit`, the
  standard `Option`/`Result`, a type parameter, a record, protected, enum or
  union type the file declares).  Against a type another file or package
  declares it may be a case, so it is not modelled.  `name @ p` now matches
  where `p` does, rather than unconditionally (the rest of #8142).
* An arm whose pattern is not modelled (V0027) was dropped from the match's
  value, with only a warning.  The match's value is now wrapped in a marker
  (`unmodelledPatternMarker`, beside the V0033 `untranslatableMarker`): every
  goal it reaches is never discharged and gets error `V0027` at the goal
  ("postcondition of f depends on the value of a match with an arm whose
  pattern the verifier does not model; not proved"), while the arm itself
  keeps a `V0027` warning.  A match whose value reaches no goal — a function
  without a postcondition returning it — is no error, so
  `examples/ledger/src/accounting.l` still proves.  A `@pure` body with such
  a match is not unfolded at its calls.

## Tests

* `verifier_self_test.l`: 14 new tests — `@cfg` feature and target twins
  proved per build, F0012 stops the proof; bare enum/union cases and `None`
  fail closed, a bare name against a sibling's type fails closed, an unused
  unmodelled match is no error, bare bindings on primitives/records/enums
  still bind, `k @ 5` matches only 5; record methods (false `ensures:`
  refuted, bare field read as `self.<field>`, a local shadowing a field,
  `assert`/`requires:` in a method), a generic `impl` method's assertion
  refuted with the impl's type parameter in scope, interface clauses
  inherited (refuted, proved, renamed and swapped parameters), an interface
  in a sibling file, an unseen interface failing closed, and an interface
  default method.  189/189 pass.
* `scripts/ci/prove-items.sh` (wired into CI next to `prove-type-check.sh`)
  over `examples/prove-cfg/` (target twins in a single file; feature twins
  in a project, refuted by default and proved with `--features wide`, in
  single-file and `--manifest` mode), `examples/prove-unmodelled-match/`
  (the #8230 repro: a union declared in a sibling file) and
  `examples/prove-methods/` (an `impl` method's failing assertion refuted;
  record and `impl` methods that hold).  Every case fails on `main` (the
  first with the crash).

## Behaviour changes in existing proofs

Swept with `lyric prove` over every file outside `lyric-compiler/` that
carries `@proof_required` (38 on `main`) and compared with `main`'s binary:
every outcome is unchanged except `examples/product-catalog/src/domain.l`,
which already failed (V0033) and now also reports `V0027` for
`categoryToString`'s `ensures:` over a match of bare enum cases (previously
read as a binding that matched every value) and checks the bodies of all
seven arms.  No `@proof_required` file under `lyric-*/src` or
`lyric-stdlib/std` (only `std/core_proof.l`, 9/9) declares a method, an
`impl` or a match the change affects.
