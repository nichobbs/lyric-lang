# `lyric prove` type-checks first, and keeps a quantifier body's side conditions (#8227, #8223, #8216)

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
`TranslateResult` with empty `sideConds`, discarding `bodyR.sideConds` and the
`where` clause's.  It now states each of them under the quantifier's own
binders: a `where` clause's side condition as `forall x. dom(x) implies
side(x)`, the body's as `forall x. dom(x) and where(x) implies side(x)`, with
`dom` the binder's range and width (#8214).  The same holds for `exists`, whose
body may run for every value before a witness is found.  A side condition that
names a call result that does not vary with the binder is checked for every
value of that result, which is sound and only less precise.  The facts the body
brings (a callee's `ensures:`) are still not kept: lifted out of the
quantifier, a fact about such a result would be claimed for every bound value
at once.

`verifier_self_test.l` covers a precondition and a division under `forall` and
`exists`, in the `where` clause, under nested quantifiers and independent of the
binder, each refuted unguarded and proved guarded.

## `lyric prove` stops on a program the type checker rejects (#8227)

`lyric prove` parsed the file and handed it straight to the verifier, so a file
`lyric build` rejected (`T0032`, say) was still proved, and the verifier could
read a name differently from the type checker.  `lyric prove` now type-checks
the program first, the way a `--target dotnet` build checks it, and proves
nothing when any pass up to and including the type check reports an error:

- a file that no manifest lists is checked alone, as `lyric build <file>` is;
- a file a manifest's `[project.packages]` or `[project.tests]` entry lists is
  checked with each project that builds it (`Lyric.Discovery.entriesContainingSource`),
  against the project's other packages and its resolved dependencies;
- project mode (`--manifest` or discovery) checks every `[project.packages]` entry.

The diagnostics print as the build prints them, followed by `prove: <file> does
not type-check; no proof obligation was attempted`, and the exit status is 1.
`--json` puts them in `diagnostics`, with no goals; each diagnostic object now
also names its `file` (an additive key, allowed by the frozen v1 schema).  The
language server's proofs are not gated: its own check does not load the
standard library, so on any file that uses it the check reports `T0010`/`T0020`
for `Std` names, and gating on it would turn proofs off in the editor.

The check reuses the build's front end rather than copying it:
`Lyric.Pipeline.pipeParseAndEraseCollect`/`pipeExpandAndRewriteCollect` return
the passes' diagnostics instead of printing them (the printing forms now wrap
them), `Msil.Bridge.projectFrontEnd` is the project build's front half shared by
`compileProjectToMsilWithRestoredAndVersionDiag` and the new
`checkProjectTypes`, and `Lyric.Emitter.typeCheckProject`/`typeCheckSource`
share the package merge and restored-dependency loading with `emitProject`.
`Lyric.DiagnosticUtil.LocatedDiagnostic` attributes a merged package's
diagnostic to its own file and line.

The proof-only examples and `examples/prove-package-scope` fixtures still prove
(or are refused) as before, except `otherpkg`, a package one of whose files
declares another package: the build rejects it with `B0013`, and so does prove
now. `scripts/ci/prove-type-check.sh` (run with the proof-only examples in CI)
covers an ill-typed file in plain, `--explain` and `--json` mode, a package whose
sibling file does not type-check (single-file and `--manifest`), their
type-correct twins, and the #8223 fixtures `examples/prove-quantifier-sides/`.

## Bare field name beats a module `val` in an `in`-receiver method (#8216)

Fixed on main by #8290 (`Lyric.SelfFields`); verified on dotnet, the JVM and
native (`P(n = 2).get()` is `2`).  `member_local_shadow_self_test.l` gains the
issue's exact form, an explicit `self: in` receiver with an expression body, on
all three targets.
