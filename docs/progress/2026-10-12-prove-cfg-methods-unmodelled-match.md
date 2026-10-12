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
interface is resolved as the type checker resolves it — in the proved
package, then in its imports and the prelude, read from source — as the
review follow-ups below describe.

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
  scope (#8264).  The verifier now does the same (`bareNameBinds`, in
  its final form after the review follow-ups below).  `name @ p` now matches
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

## Review follow-ups

An adversarial review of the first cut found three false "discharged"
results and several rough edges, all fixed:

* **Bare `Some`/`None`/`Ok`/`Err`.**  The first `bareNameBinds` knew only
  the file's cases and `None`, so `case Err -> true; case _ -> false`
  proved `ensures: result`.  The rule now follows the type checker
  exactly: it reads a bare name as a case whenever one of that name is in
  scope, and rejects a case that cannot match (T0129) unless the scrutinee
  is a record, enum or type parameter.  So a bare name binds against a
  primitive, slice, tuple or `Unit`; against `Option`/`Result` unless it is
  one of their cases; against a union the verifier read unless it is one
  of its cases; and against anything else only when no case of that name
  is in scope and every package in scope was read.  `lyric prove` now
  gives the verifier the declarations it needs (`PackageScope.imports`,
  `ImportScope`): the standard library's sources, as the build for
  `--target` loads them, and every package of the projects whose
  manifests list the file.
* **A same-named interface of another package.**  In the directory-tree
  fallback, a sibling file of another package contributed its interfaces;
  an `impl` then inherited the wrong interface's `requires:`.  Only files
  of the proved package (or with no `package` line) contribute now.  The
  interface is resolved as the type checker resolves it
  (`resolveImplInterface`): qualified (an alias included), in the proved
  package, then in its imports and the prelude, read from source.  An
  interface without clauses gives none; one that cannot be read (a
  dependency restored as a compiled assembly) or is ambiguous is V0033,
  and so is a method its interface does not declare at that arity —
  never "nothing inherited".
* **A bare call in an inherited clause** (`ensures: result >= limit()`)
  bound to a free function `limit`; it is now the interface's method on
  `self` (`resolveMemberExpr` over the interface's method names).
* A record method written `self: in Self` gets the record type, at its own
  type parameters, and a sibling method called on `self` has its declared
  result type (an interface default's `n() + n()` was V0033).
* A goal not discharged only because a `@pure` callee's body was not
  unfolded (its value comes from an unmodelled match) is V0027, not a
  counterexample (`unfoldSkippedMarker`: the goal is decided without the
  body, and reported as depending on it when that fails).
* A goal a V0033 construct already fails no longer gets a second V0027.
* A file two builds compile differently labels each goal with its build
  (`[target=dotnet features=a] f$post`); the `@proof_required` items no
  build compiles are listed (`1 item(s) not proved: inactive under this
  build (@cfg): limit`).

A second review found one more false "discharged": the union rule keyed
unions by their simple name, so a scrutinee typed with a dependency's
`HttpError` (restored as a compiled assembly, so unread) took the cases of
the standard library's `Std.Http.HttpError`, which the verifier did read.
A type name now resolves to a union only as the type checker resolves it
— the package's own, else the one import (or the prelude) that declares
it, with every package in scope read — and an ambiguous or unread one
falls back to the general rule, which fails closed.  Also: the
"every case known" fact needs the package's other files known; a V0027
on a `@pure` callee that the solver refutes without the body says "may be
false" and shows that model; each goal's diagnostic in a multi-build file
names its build; an inactive `@cfg` twin is listed as a variant whose
same-named declaration is proved, apart from items no build compiles; and
a project file's scope is built from the other files of its entries, read
once each, so its own declarations never count twice.

## Tests

* `verifier_self_test.l`: 23 new tests — `@cfg` feature and target twins
  proved per build, F0012 stops the proof, multi-build labels and the
  inactive items; bare enum/union cases, bare `Some`/`None`/`Ok`/`Err`, a
  bare name against a sibling's type, an imported union's case against a
  record, and bindings that bind only when every case in scope is known;
  an unused unmodelled match is no error, `k @ 5` matches only 5; record
  methods (`self: in Self` included), a generic `impl` method, sibling
  calls on `self`, interface clauses inherited (renamed and swapped
  parameters, a bare call in a clause), an interface in a sibling file, of
  another package in the same directory, of an imported package (with and
  without clauses, aliased), an unread package, a method or arity the
  interface lacks; interface default methods; a `@pure` callee with an
  unmodelled match; an item no build compiles versus an inactive twin.
  198/198 pass.
* `scripts/ci/prove-items.sh` (wired into CI next to `prove-type-check.sh`)
  over `examples/prove-cfg/`, `examples/prove-unmodelled-match/` (a union
  in a sibling file, bare `Err`, a `@pure` callee) and
  `examples/prove-methods/` (a failing `impl` assertion, methods that
  hold, `Std.Stream`'s `ByteReader` clauses inherited, another package's
  same-named interface ignored, a bare call in an inherited clause), a
  JVM-only item listed as not proved, and a restored dependency's union
  named like the standard library's (built in a copy): 22 checks, each
  failing on `main`.

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
