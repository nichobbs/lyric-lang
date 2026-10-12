# `lyric prove` checks the program as the build does, and keeps a quantifier body's side conditions (#8227, #8223, #8216)

## A quantifier's side conditions are obligations for every bound value (#8223)

The verifier translated a `forall`/`exists` body and its `where` clause and
then threw away their side conditions: a callee's `requires:`, a divisor that
must be non-zero, a payload selector's variant.  Nothing checked them, so

```
@pure
func inv(x: in Byte): Byte
  requires: x != 0u8
{ 100u8 / x }

func f(): Bool
  ensures: forall (k: Byte) inv(k) == inv(k)
{ true }
```

was proved although `inv(0u8)` violates `inv`'s precondition, and
`forall (k: Byte) 10u8 / k >= 0u8` was proved although it divides by zero.

Root cause: `translateQuantifier` (`verifier/vcgen.l`) built its
`TranslateResult` with empty `sideConds`.  It now states each side condition
under the quantifier's own binders: a `where` clause's as `forall x. dom(x)
implies side(x)`, the body's as `forall x. dom(x) and where(x) implies
side(x)`, with `dom` the binder's range and width (#8214).  `exists` gets the
same, since its body may run for every value before a witness is found.  The
facts the body brings are not lifted out of the binder.

Side conditions now keep evaluation order: each one holds under the facts of
everything evaluated before it in the same expression (`afterFacts`), so the
flat list means `side_1 and (fact_1 implies side_2) and ...`.  A call's
precondition is checked under its arguments' facts, an argument's side
conditions under the earlier arguments' (and a method's receiver's), a binary
operator's right operand under the left one's, and the operator's own (a
divisor, an overflow bound) under both.  A call's own `ensures:` still never
justifies its own `requires:` (#8102).  So `forall (k: Byte) inv(nz(k)) >=
0u8`, with `nz` ensuring a non-zero result, is proved, as it was before the
side conditions were checked.

Checking those side conditions exposed a related, older hole: a `requires:`
clause is assumed at entry with its side conditions, so a clause no argument
can meet (`requires: inv(0u8) >= 0u8`, the same under a quantifier, or
`requires: z == 0u8 and forall (k: Byte) where k == z { inv(k) >= 0u8 }`,
whose quantified side condition holds only where its first conjunct fails)
made every obligation of the function hold vacuously.  The side conditions
stay the caller's obligation (#8102: `requires: x == 0 or pos(x) > 0` asks the
caller for `x == 0 or x > 0`), and each clause now also carries a goal,
`GKPreconditionDomain`, that some argument meets it, side conditions, facts
and value together, under the parameters' facts and the clauses before it; the
solver refuting "no argument does" is its proof.  A clause no call can meet is
the new error V0035 ("this precondition of f can never hold"), which also
catches a plainly unsatisfiable `requires: x > 5u8 and x < 3u8`.  When an
earlier clause cannot be met, only it is reported.  The check guards against vacuity and is
not one of the function's obligations: when the solver cannot decide it (a
nonlinear clause), the function's goals keep their outcome and the clause gets
warning V0036, "could not rule out that this precondition can never hold",
instead of a V0007 error that would fail a proof that passed before.

`verifier_self_test.l` covers a precondition and a division under `forall` and
`exists`, in the `where` clause, under nested quantifiers and independent of
the binder (each refuted unguarded, proved guarded); an argument's, a
divisor's and an earlier clause's facts (proved), a call's own `ensures:`
(refuted); and vacuous preconditions, plain, quantified, by division and
contradicted by an earlier clause, unmet where the clause holds, or plainly
unsatisfiable (reported, the earlier clause alone when two are), next to
partial and satisfiable ones some argument meets (proved, and a partial one
refuted at a caller that does not meet it).

## `lyric prove` stops on a program the build rejects (#8227)

`lyric prove` parsed the file and handed it straight to the verifier, so a file
`lyric build` rejected (`T0032`, say) was still proved, and the verifier could
read a name differently from the type checker.  `lyric prove` now runs the
build's checks first, through the mode check, and proves nothing when one of
them reports an error:

- a file that no manifest lists is checked alone, as `lyric build <file>` is;
- a file a manifest's `[project.packages]` or `[project.tests]` entry lists is
  checked with each project that builds it (`Lyric.Discovery.entriesContainingSource`):
  its own package and every project package it imports, directly or not, and
  not the rest, so `lyric prove examples/ledger/src/accounting.l` still proves
  the accounting package without the service packages' dependencies;
- project mode (`--manifest` or discovery) checks every `[project.packages]` entry;
- `--target dotnet|jvm|native`, `--features`, `--no-default-features`,
  `--all-features` and `--define` select the build the check is, as for
  `lyric build` (default dotnet; no manifest key declares another), so a
  JVM-gated package is proved with `--target jvm`;
- the project's dependencies are resolved only when a checked package imports
  a package that is neither the standard library's nor the project's, and then
  a dependency that is not restored or built stops the proof (`B0001`, "run
  `lyric restore` or `lyric build` first") rather than letting the program
  through unchecked.  Messages from the shared resolution now carry the
  `prove:` prefix (`resolveManifestDependenciesAs`, `readProjectPackageSourcesAs`).

The diagnostics print as the build prints them, followed by `prove: <file>
fails the build's checks; no proof obligation was attempted`, and the exit
status is 1.  `--json` puts them in `diagnostics`, with no goals; each
diagnostic object now also names its `file` (docs/15 A.3, an additive key).
The language server's proofs are not gated: its own check does not load the
standard library (#8304).

The check is the build's own code, not a copy: `Lyric.Pipeline.pipeCheckFront`
is the front of `pipeCheckAndMono` (type check, checked desugarings, effect and
`[layers]` rules, mode check) with its diagnostics sent to a `DiagSink` that
prints or collects; `pipeParseAndEraseCollect`/`pipeExpandAndRewriteCollect`
are the collecting forms of the parse/erase and expand/rewrite passes;
`Msil.Bridge.projectFrontEnd` is the project build's front half, shared with
`checkProjectTypes`; `Lyric.Emitter.typeCheckProject`/`typeCheckSource` share
the package merge and restored-dependency loading with `emitProject`.
`lyric build` output is unchanged.

Cost: the check parses the target's standard library and checks the program,
so a proof of a small file now takes one to a few seconds (1.1 s and 2.5 s measured) where it took about 0.2 s
(`lyric-stdlib/std/core_proof.l`); a project proof pays it once.

The proof-only examples and `examples/prove-package-scope` fixtures still prove
(or are refused) as before, except `otherpkg`, whose package the build rejects
with `B0013`: prove now refuses it too.  `examples/rbac`, `examples/jobqueue`
and `examples/product-catalog` pass the checks; their proofs fail as on main.
`scripts/ci/prove-type-check.sh` (run with the proof-only examples in CI)
covers an ill-typed file in plain, `--explain` and `--json` mode, a package
whose sibling file does not type-check (single-file and `--manifest`), a
JVM-gated and a feature-gated package with and without the flag, an unbuilt
path dependency, the ledger's documented command, their type-correct twins,
and the #8223 fixtures `examples/prove-quantifier-sides/`.

## Bare field name beats a module `val` in an `in`-receiver method (#8216)

Fixed on main by #8290 (`Lyric.SelfFields`); verified on dotnet, the JVM and
native (`P(n = 2).get()` is `2`).  `member_local_shadow_self_test.l` gains the
issue's exact form, an explicit `self: in` receiver with an expression body, on
all three targets.
