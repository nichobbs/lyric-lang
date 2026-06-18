# 15 — Phase 4 Proof System Plan

> **Scope.** This document is the implementation plan for the Phase 4
> proof system. It picks up from the strategic outline in
> `docs/05-implementation-plan.md` §"Phase 4" and the operational
> semantics in `docs/08-contract-semantics.md` §§10–13, and tells the
> implementer *what to build, in what order, with what test
> obligations, and where to stop.*
>
> **Status.** Draft. Phase 4 is post-v1.0; nothing in this plan
> blocks v1.0 (Phase 3). The plan exists now so that v1.0 design
> choices that *would* compromise Phase 4 are caught at review time
> rather than at year five.
>
> **Authoritative inputs:**
> - `docs/01-language-reference.md` §6 (contracts), §13 (status of
>   Q011/Q012 deferrals).
> - `docs/03-decision-log.md` D013 (per-module verification level),
>   D033 (Z3 backend), D035 (M1.4 proof-obligation deferral).
> - `docs/05-implementation-plan.md` Phase 4.
> - `docs/08-contract-semantics.md` §§10–13.
> - `docs/09-msil-emission.md` §16 (contract metadata embedding).
>
> **Authority.** Where this document and the Phase 4 paragraphs of
> `05-implementation-plan.md` differ, `05` is the *strategic* truth
> (timing, budget, hiring) and this doc is the *tactical* truth
> (architecture, milestones, deliverables, exit criteria). Where this
> document and `08-contract-semantics.md` differ on the meaning of a
> contract, `08` wins and this document is updated.

---

## 1. Goal of Phase 4

Ship the SMT-backed verifier that the operational semantics in
`docs/08-contract-semantics.md` §10 *describes*. Concretely:

1. Make `@proof_required` modules produce compile-time verification
   conditions instead of runtime asserts.
2. Discharge those VCs with Z3 (D033) over the decidable fragment
   (`08-contract-semantics.md` §11).
3. Report counterexamples for failed proofs in a form a working
   programmer can act on.
4. Enforce the call-graph constraints that keep the proof sound:
   `@proof_required` callers may only call `@proof_required`,
   `@axiom`, or compiler-primitive callees; everything else is a
   diagnostic.
5. Embed contract metadata in `<P>.lyric-contract` (already shipped
   in M1.3 per D-progress-031) so cross-package proofs see the same
   contracts the runtime checker sees.
6. Ship enough documentation, examples, and counterexample UX that
   a verification-curious working programmer can prove the banking
   example's conservation property as their first day-one demo.

Non-goals (deferred to Phase 4 polish or later):

- Termination proofs for arbitrary recursive functions. The
  decidable fragment requires a structural measure for `@pure`
  recursion (`08-contract-semantics.md` §11).
- Proofs over `String` content beyond equality and length.
- Proofs over IEEE 754 floats beyond what Z3's FP theory decides
  in budget. We document the hazard; we do not solve it.
- Proofs over `async` interleavings or `protected type` schedule
  fairness. The proof story is sequential per-entry; concurrency
  is verified by the runtime barrier evaluator.
- Self-hosting the verifier. Phase 5 explicitly keeps the proof
  system in F# (`05-implementation-plan.md` §"Phase 5").

---

## 2. Phase 4 in one diagram

```
                     ┌──────────────────────────────┐
                     │  Lyric source (.l)           │
                     └──────────────┬───────────────┘
                                    │
                       (existing pipeline through M1.4)
                                    │
                                    ▼
                     ┌──────────────────────────────┐
                     │  Typed AST + Contract trees  │
                     │  (validator already ran;     │
                     │   §4.4 of `08-...md`)        │
                     └──────────────┬───────────────┘
                                    │
                                    ▼
   ┌──────────────────────────────────────────────────────────┐
   │  *** PHASE 4 NEW WORK STARTS HERE ***                    │
   │                                                          │
   │  ┌─────────────────────┐   ┌──────────────────────────┐  │
   │  │  Mode-dispatch      │   │  Loop-invariant gate     │  │
   │  │  (§4.1)             │   │  (§4.2)                  │  │
   │  └──────────┬──────────┘   └────────────┬─────────────┘  │
   │             ▼                           ▼                │
   │  ┌──────────────────────────────────────────────────┐    │
   │  │  VCGen — wp/sp calculus over Typed AST           │    │
   │  │  (§5; implements `08-...md` §10.2 table)         │    │
   │  └──────────────────────┬───────────────────────────┘    │
   │                         ▼                                │
   │  ┌──────────────────────────────────────────────────┐    │
   │  │  Lyric-VC IR  (§6)                               │    │
   │  │   typed first-order formulae;                    │    │
   │  │   solver-agnostic                                │    │
   │  └──────────────────────┬───────────────────────────┘    │
   │                         ▼                                │
   │  ┌──────────────────────────────────────────────────┐    │
   │  │  SMT-LIB v2.6 emitter + Z3 driver (§7)           │    │
   │  └──────────────────────┬───────────────────────────┘    │
   │                         ▼                                │
   │  ┌──────────────────────────────────────────────────┐    │
   │  │  Result router (§8)                              │    │
   │  │   unsat → VC discharged                          │    │
   │  │   sat   → counterexample (§9)                    │    │
   │  │   unknown → unverified-obligation diagnostic     │    │
   │  └──────────────────────┬───────────────────────────┘    │
   └────────────────────────┬┴───────────────────────────────┘
                            ▼
                Continue to MSIL emission as in M1.4,
                with proof-required clauses *elided*
                from runtime asserter (§10).
```

The Lyric-VC IR (§6) is the load-bearing intermediate representation:
it decouples the wp/sp calculus from any specific solver, which is
how D033's "Z3 first, swap to CVC5 if licensing forces it" promise
is kept.

---

## 3. Module modes and the call-graph contract

The four package-level modes in `08-contract-semantics.md` §3.1 are
fixed by Phase 0. Phase 4 makes the *enforcement* of the partial
order

> `axiom ⊐ proof_required(_unsafe) ⊐ runtime_checked`

real. Today the parser accepts `@proof_required` (per D035) but
does not check the call-graph rule.

### 3.1 New diagnostics

| Code  | When emitted | Severity | Recovery |
|-------|--------------|----------|----------|
| `V0001` | `@proof_required` package imports `@runtime_checked` package | error | upgrade callee or downgrade caller |
| `V0002` | `@proof_required` function calls non-`@pure` non-`@proof_required` callee | error | refactor / shift to `@runtime_checked` |
| `V0003` | `@proof_required(unsafe_blocks_allowed)` enters `unsafe { … }` without explicit `assert` at exit | error | add post-state `assert` |
| `V0004` | `@axiom` declaration on a function with a non-empty body | error | drop body or remove `@axiom` |
| `V0005` | `@proof_required` loop without `invariant:` clause | error | add invariant or rewrite as fold |
| `V0006` | Quantifier domain not in the decidable fragment | error | bound the domain or shift to `@runtime_checked` |
| `V0007` | VC unsolved within solver budget (`unknown`) | error (default) / warning (with `--allow-unverified`) | refactor or add `assume` |
| `V0008` | VC `sat` — proof failed | error | inspect counterexample (§9) |
| `V0009` | `assume` used in proof-required code without `unsafe { … }` | error | wrap or remove |
| `V0010` | Package declares conflicting verification annotations (`@proof_required` and `@runtime_checked`, etc.) | error | pick one |
| `V0011` | Unknown `@proof_required` modifier (only `unsafe_blocks_allowed` and `checked_arithmetic` are recognised) | error | drop or correct the modifier |
| `V0012` | `async func` or `yield`-bearing function appears in proof-required code | error | refactor into a sync core, or mark `@runtime_checked` |
| `V0031` | **Retired** in #336.  The self-hosted aspect weaver (`Lyric.Weaver.weaveFile`, ported from `bootstrap/src/Lyric.Emitter/Weaver.fs`) now runs in the verifier driver before VC generation, so proofs discharge against the woven wrapper's composed contracts — not the bare body.  The same-package limitation that previously made the warning incomplete is gone; cross-package aspect detection is still future work (imported aspect annotations don't fire weaving today, mirroring the original `V0031` cross-package gap). | — | — |

`V0007` defaults to *error* because allowing `unknown` to slide is
how every academic verifier's user community ends up tolerating
quietly-unverified proofs. The escape hatch is explicit and
narrowly scoped (`08-contract-semantics.md` §12 axiom rules apply).

### 3.2 Cross-package contract reading

Already partly shipped: `<P>.lyric-contract` (D-progress-031,
`09-msil-emission.md` §16) embeds requires/ensures as syntax trees.
Phase 4 adds:

- **Pure-function bodies** are also serialised when annotated
  `@pure` (`08-contract-semantics.md` §4.3). The proof of a caller
  may need to *unfold* a `@pure` callee (e.g. `amountValue(m)`
  in the conservation property `08-...md` §13.3). Without a
  serialised body the call rule (§10.4) gives only the postcondition,
  which is often weaker than equational reasoning would give.
- **Generic instantiation table.** Monomorphised generics
  (D035) means the `<P>.lyric-contract` for a callee that uses
  generic types must record contracts in their *unsubstituted* form
  with explicit type parameters. The VC generator substitutes at
  the call site.
- **Axiom whitelist.** `<P>.lyric-contract` lists every `@axiom`
  declaration in `P` and references its source location, so an
  audit can produce the full transitive axiom set for any
  proof-required build.

---

## 4. Pre-VC analyses

Two analyses run *before* VC generation and reject programs that
the VC generator could not handle cleanly. Failing here gives the
user a clearer diagnostic than failing inside the solver.

### 4.1 Mode-dispatch and pure-call check

Walks the Typed AST of every `@proof_required` function. For every
call site:

1. Resolve the callee's verification mode (queryable from
   `<P>.lyric-contract`).
2. Reject (`V0002`) if the callee is `@runtime_checked` and not
   marked `@pure`. Allow (`@pure` callees because the call rule
   §10.4 still works — only their postcondition is consulted.)
3. Reject `await` and `spawn` outright (`V0002`). Concurrency is not
   in the decidable fragment.

This pass also flags `unsafe { … }` blocks — they are *not* errors
in `@proof_required(unsafe_blocks_allowed)` mode, but the post-block
state must include an explicit `assert φ` whose `φ` becomes an
*assumed* postcondition for the surrounding wp computation
(`08-...md` §12).

### 4.2 Loop-invariant gate

`08-contract-semantics.md` §10.2 mandates an `invariant:` on every
loop in proof-required code. The grammar already admits the syntax;
the gate enforces presence, well-formedness (the invariant must
typecheck against state at the loop head, contain no `result`,
contain no `old(_)` referring to the function's pre-state unless
explicitly passed in), and *progress* — the invariant must be
strong enough that Z3 can use it.

Progress is undecidable in general; the gate's heuristic is:

- The invariant must mention every `var` mutated in the loop body, or
  the loop body must be a fold over an immutable iterator.
- Reject (`V0005`) otherwise with a fix-it suggestion that adds
  `invariant: <list every `var`>` as a starting point.

This is deliberately conservative; the user can always strengthen
the invariant. The point of the gate is to fail at parse-error speed
on the common "I forgot the invariant" case rather than at solver-
timeout speed.

---

## 5. The VC generator

The VC generator is the single new module
`bootstrap/src/Lyric.Verifier/VCGen.fs`. It implements the wp/sp
calculus tabulated in `08-contract-semantics.md` §10.2 *literally*:
the table there is the implementation specification.

### 5.1 Architecture

```
Lyric.Verifier/
  VCGen.fs           -- wp + sp; one `wp body Q` function per AST shape
  Theory.fs          -- maps Lyric types to Lyric-VC sorts (§6)
  Substitution.fs    -- capture-avoiding substitution over Lyric-VC
  Vcir.fs            -- the Lyric-VC IR (§6) and pretty-printer
  Loops.fs           -- loop encoding (§5.3)
  Calls.fs           -- call rule (§10.4) and contract instantiation
  Axiom.fs           -- @axiom registration; transitive listing
  Driver.fs          -- entry point: takes a TypedModule, returns
                      Result<DischargedProof, list<UnvCondition>>
```

### 5.2 Encoding choices

| Lyric type                | Lyric-VC sort                                | Notes |
|---------------------------|----------------------------------------------|-------|
| `Bool`                    | `Bool`                                       | trivial |
| `Int`, `Long`, `Nat`      | `Int` (mathematical integer)                 | overflow handled separately, see §5.4 |
| range subtype `T range a ..= b` | `Int` with implicit `a ≤ x ≤ b` axiom on every binder | preserves identity loss is fine in proof; CLR identity matters only for emission |
| `UInt`, `ULong`, `Byte`   | `(_ BitVec n)`                               | bitvector arithmetic, slow but decidable |
| `Float`, `Double`         | SMT `Real` (mathematical reals)              | sound approximation: avoids IEEE 754 FP theory and its rounding-mode complexity; linear arithmetic over reals is decidable and fast; division emits `/` (Real div) not `div` (integer) |
| `String`                  | uninterpreted sort with `length: String -> Int`, `==` | content reasoning out of scope |
| record                    | SMT-LIB datatype                             | one constructor, fields as selectors |
| union                     | SMT-LIB datatype                             | one constructor per variant |
| enum                      | SMT-LIB datatype, no payloads                | as union with arity-0 variants |
| `slice[T]` of compile-time-bounded length | array sort with separate length | length axiom asserts `0 ≤ length ≤ N` |
| `slice[T]` unbounded      | uninterpreted sort + length function          | `forall` over its elements requires explicit bound (§4.2 §11) |
| opaque type               | SMT-LIB datatype with one private field       | fields are not exported across packages — the VC generator inlines invariant facts but not the representation |
| function type             | uninterpreted sort + apply axiom (`@pure` only)| non-`@pure` functions cannot appear as values in contracts |
| `Result[T, E]`            | the standard Lyric-defined two-arm union; treated as datatype | |
| protected-type ref        | fields bound as symbolic `Real`/`Int`/… vars | per-entry sequential reasoning via `goalsForProtectedType`; `invariant:` clauses injected as `requires:` hypotheses on each entry; invariant preservation checked via explicit `assert` in the body |

Range subtype values lift to `Int` with the bound as a `forall`-
introduced hypothesis. This is the same trick SPARK uses; it lets
the solver carry the bound through arithmetic without a special
theory.

### 5.3 Loops

A loop `while c invariant: ι { S }` desugars to the standard Hoare
encoding:

> `assert ι (at loop entry)`
> `havoc all vars modified in S`
> `assume ι ∧ c`
> `S`
> `assert ι (preserved by body)`
> `assume ι ∧ ¬c`

The VC generator emits three sub-VCs: *establish*, *preserve*,
*conclude*. Each is reported separately so a failed proof points to
"the body does not preserve the invariant" rather than the lump
"the loop is wrong."

`for x in xs invariant: ι { S }` desugars to a `while` where the
implicit iterator state is `(remaining: slice[T], processed: slice[T])`
and the iteration step is `(processed.append(x), remaining.tail)`.
The user-written invariant is conjoined with the implicit
`xs == processed ++ remaining`.

### 5.4 Overflow

Range subtypes give bounded integers. Plain `Int`/`Long` are
unbounded mathematical integers in the proof but bounded `Int32`/
`Int64` at runtime. The mismatch is real and is handled in two
modes:

- **`@proof_required(unchecked_arithmetic)`** (default): the prover
  treats `Int`/`Long` as `Int`. Overflow is the user's problem.
  Programs that *would* overflow at runtime can still verify; the
  runtime separately raises `IntegerOverflow`. Documented hazard.
- **`@proof_required(checked_arithmetic)`**: every arithmetic
  operation generates an additional VC `result ∈ [Int.min, Int.max]`.
  Slow but sound. Recommended for safety-critical code (the original
  Phase 0 audience, `00-overview.md`).

Mode is fixed per package, like the other proof-required modifiers.

### 5.5 Pure-function unfolding

Per §3.2, `@pure` callees may have their bodies serialised. The
VC generator unfolds *one level* by default at every call site,
emitting

> `g(args) = ⟦body_g⟧[params := args]`

as an assumed equality, in addition to `g`'s contract. One level
keeps the formula size bounded; user can request more with
`@unfold(n)` on the call site (rejected if `g` is not `@pure` or
not from a package whose `<P>.lyric-contract` carries the body).

---

## 6. Lyric-VC IR

The intermediate representation between VCGen and the SMT emitter
is a typed first-order logic with the sorts of §5.2, the standard
connectives, equality, quantifiers (with explicit triggers), let-
bindings, and pattern matching over datatypes. It is deliberately a
near-isomorphism of SMT-LIB v2.6 minus surface syntax.

```fsharp
type Sort =
  | SBool
  | SInt
  | SBitVec of int
  | SFloat32 | SFloat64
  | SDatatype of string * Sort list   // record, union, enum, opaque
  | SArray of Sort * Sort
  | SUninterp of string
  | SArrow of Sort list * Sort        // function sort, @pure only

type Term =
  | TVar of string * Sort
  | TLit of Literal
  | TApp of string * Term list        // user fns + builtins
  | TLet of (string * Term) list * Term
  | TIte of Term * Term * Term
  | TForall of (string * Sort) list * Term list (* triggers *) * Term
  | TExists of (string * Sort) list * Term
  | TMatch of Term * (Pattern * Term) list

type Goal =
  { Hypotheses: Term list
    Conclusion: Term
    Origin: SourceSpan          // where in the user's code this came from
    Tag:    GoalKind            // PreOnEntry | PostOnReturn | LoopEstablish | ...
    Budget: SolverBudget }
```

Why an IR rather than directly emitting SMT-LIB:

- **Solver swap (D033 fallback).** The IR is solver-agnostic; the
  Z3 emitter is one back-end, a CVC5 emitter is another, both
  ≈300 lines.
- **Counterexample mapping (§9).** Z3's models are over its sort
  names; mapping back to user names happens once, in the IR-aware
  formatter, not in five places.
- **Pretty-printing for `--explain` (§9.4).** Users get a
  Lyric-typed view of the open obligation, not raw `(=> (and …))`.
- **Caching (§7.4).** A goal's content hash is taken on the IR;
  the SMT-LIB string is a derivative.

---

## 7. SMT integration

### 7.1 Solver

Z3 (D033). Consumed via the `Microsoft.Z3` NuGet package, which
provides .NET bindings on Native-AOT-compatible builds. The
verifier links Z3 dynamically; AOT trim warnings are *not*
treated as compilation errors for the verifier crate (we annotate
with `[DynamicallyAccessedMembers]` per ECMA-335 / .NET trim spec).

**AOT compatibility carve-out.** The bootstrap-compiler-as-a-whole
runs as Native-AOT (D-progress-040). The verifier process is the
*one* AOT carve-out: it runs from the JIT-mode `lyric prove`
binary and shells out to `libz3` at native ABI. `lyric build`
without `--prove` is unchanged and remains AOT-clean.

### 7.2 SMT-LIB v2.6 emission

One file per VC, written to `target/<P>/proofs/<n>.smt2`. Files
are stable across runs (sorted hypotheses, sorted let-bindings,
named binders); the verifier hashes them for the cache (§7.4).

Emission rules:

- All Lyric-VC sorts map to declared SMT-LIB sorts at the file
  head; datatypes are declared once per file and reused across
  goals via `(set-option :produce-models true)` on the same
  context.
- Quantifier triggers are *required* on every `forall` over a
  user datatype, picked by the IR emitter from the heads of
  pattern-matching positions in the conclusion. Triggerless
  quantifiers are admitted only when generated from a literal
  user `forall (x: T)` with finite-cardinality `T`.
- A `(get-model)` is emitted on `sat`. Counterexample extraction
  reads the model.

### 7.3 Solver budget

Default budget per VC is 5 seconds wall, 1 GiB memory. Configurable
via `lyric.toml` `[verify] timeout_ms`, `memory_mb`. Exceeded budget
is reported as `unknown` (`V0007`), not silently elided.

The driver maintains a *push/pop* solver context per file, so
shared declarations (datatypes, function sorts) are emitted once;
each goal is a `(push) … (assert) (check-sat) (pop)` block.

### 7.4 Goal cache

`target/<P>/proofs/cache.json` maps content-hash of a Lyric-VC goal
(IR-level) to its discharge result and Z3 version. A cached `unsat`
under the same Z3 version skips the solver invocation. Cache is
invalidated automatically when:

- the Z3 version changes,
- any contract metadata in `<P>.lyric-contract` (or any transitive
  dependency's `.lyric-contract`) changes,
- the `[verify]` block in `lyric.toml` changes.

Incremental verification is the difference between "9 seconds for a
hello-world" and "9 seconds for the entire stdlib." This is not
optional.

---

## 8. Result router

Three outcomes; one user-facing path each.

### 8.1 `unsat` — discharged

The VC's negation is unsatisfiable; the obligation holds. Cached
and the user sees nothing (or, with `lyric prove --verbose`, a
table of "247/247 obligations discharged in 9.3s").

### 8.2 `sat` — proof failed

The VC's negation has a model; the obligation does not hold for the
exhibited model. Counterexample reporting (§9) takes over.

### 8.3 `unknown` — unverified

`V0007`. Default severity error; configurable to warning per
`lyric.toml`. Output includes:

- Source location of the obligation,
- A textual rendering of the goal in the Lyric-VC IR's pretty form,
- The path to the SMT-LIB file under `target/<P>/proofs/<n>.smt2`,
- A list of fix-it suggestions: tighten the `requires:`, add a
  loop invariant, rewrite a quantifier to bounded form, shift the
  module to `@runtime_checked`, or insert an `assume` (only
  inside `unsafe { … }` per §3.1).

The list is heuristic-driven; the heuristics evolve with the user
base. Ship it as a JSON-emitting `lyric prove --explain --json`
mode in M4.3 so editor integrations can render fix-its inline.

---

## 9. Counterexample reporting

This is the user-facing phase of the verifier. SPARK's experience
(`07-references.md` SPARK 2014 RM) is unambiguous: the difference
between a verifier the user understands and one they avoid is the
counterexample UX.

### 9.1 Model extraction

On `sat`, the driver reads the Z3 model and walks each named binder
in the original Lyric-VC goal. Sorts map back through the §5.2 table:

- `Int` values render as decimal literals.
- Range-subtype binders render with the type name, e.g. `Cents(42)`.
- Bitvectors render as hex with the underlying type, `UInt(0xFFFF)`.
- Datatype values render as Lyric construction syntax,
  `Amount(value = 100)` rather than `(Amount 100)`.
- Slices render as `[a, b, c]` with their length.
- Uninterpreted sorts render as `<UninterpretedValue id=k>` with
  any constraints the model exhibits.

### 9.2 Trace reconstruction

For VCs derived from imperative bodies (most postcondition
violations), the driver replays the wp/sp derivation in reverse to
produce an *execution trace*: at line N, `x = 5`; at line N+2, the
loop body runs; at line N+5, `x = -3`; the postcondition `x > 0`
fails. The trace is a list of `(SourceSpan, Binding)` pairs.

For VCs that are pure logical statements (typically, derived from
`forall`/`exists` constructions), there is no trace; the report is
just the binder values.

### 9.3 Output shape

Two formats:

**Human (default).**

```
error[V0008]: postcondition not provable for `Transfer.execute`
  --> lyric/banking/transfer.l:42:3
   |
42 |   ensures: result.isOk implies {
   |   ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   |   counterexample:
   |     amount = Cents(0)
   |     from   = Account(balance = Cents(50), id = AccountId(1))
   |     to     = Account(balance = Cents(50), id = AccountId(2))
   |
   |   trace:
   |     line 30: amount.value == 0 (precondition admits)
   |     line 35: result := Ok((from, to))
   |     line 42: postcondition newFrom.balance + newTo.balance ==
   |              from.balance + to.balance + amountValue(amount)
   |              fails:  100 != 100 + 0  is false ... oops
   |
   |   suggestion: add `requires: amount.value > 0`
```

**Machine (`--json`).** A JSON object suitable for editor
integration. Schema documented in appendix A of this document
(frozen as of M4.3).

### 9.4 The `--explain` mode

`lyric prove --explain --goal <n>` prints the full Lyric-VC IR for
goal `n` with hypotheses pretty-printed in their Lyric form. This
is the escape hatch for users debugging *why* the solver picked a
particular model — the analogue of `dafny verify /printDischarge`.

---

## 10. Interaction with runtime asserter

`@proof_required` modules under M1.4 today emit runtime asserts
*and* parse contracts (D035). Phase 4 reverses the first half:

| Mode                                     | Runtime asserts emitted? | VC obligations? |
|------------------------------------------|--------------------------|-----------------|
| `@runtime_checked`                       | yes                      | no              |
| `@proof_required`                        | no                       | yes             |
| `@proof_required(unsafe_blocks_allowed)` | no, except inside `unsafe { … }` | yes |
| `@proof_required(checked_arithmetic)`    | no                       | yes (with overflow VCs) |
| `@axiom`                                 | n/a (no body)            | no              |

A `lyric build --release` of a proof-required package emits an
*assembly with no contract checks*, exactly the way SPARK's
`Pre => Static` works. The contract is in the metadata, not in
the IL. This is the speedup story for `@proof_required`: the
contracts are not free-standing assertions any more.

A `lyric build --debug` of the same package emits the runtime
asserts anyway, *belt and braces*. Useful during proof-debugging.

---

## 11. Standard library status under proof-required

Most of `std.*` is `@runtime_checked`: it interacts with I/O, the
runtime, .NET BCL, and async — none of which are in the decidable
fragment. A proof-required user package cannot import a runtime-
checked package directly (`V0001`).

The strategy:

- **`std.core.proof`** — a small subpackage of `std.core` declared
  `@proof_required`, containing `Option`, `Result`, the
  finite-collection types and operations relevant to verification
  (`map`, `fold`, `forall`, `exists`, `length` over a slice, etc.),
  and pure arithmetic helpers.
- **`@axiom`-marked `std.bcl.*` shims** for the operations that
  *must* cross into runtime-checked code: `IO`, `Time`, `Random`,
  `String.format`. The contracts of these axiom shims are reviewed
  manually (D013 social mechanism); the audit list lives at
  `docs/17-axiom-audit.md` (renumbered from 16 because slot 16 was
  taken by `docs/16-lsp-vscode-plan.md`).

`docs/14-native-stdlib-plan.md` already commits to a native
`std.collections.List[T]` carrying `invariant: length >= 0`. That
invariant becomes a usable proof fact only after Phase 4 ships.

---

## 12. Milestones

The Phase 4 budget is 12–18 months (`05-implementation-plan.md`
Phase 4). Three milestones, mapped to the strategic plan's
M4.1/M4.2/M4.3.

### M4.1 — VC generator skeleton + arithmetic (months 39–45)

**Deliverables:**

1. `Lyric.Verifier` skeleton: project, `Vcir`, `Theory`,
   `Substitution`, `Driver` plumbed.
2. The wp/sp calculus for the *imperative* fragment: `let`, `var`,
   `if`, `match`, sequential composition, `return`. No loops yet.
3. Z3 integration via SMT-LIB: emission, push/pop solver context,
   `(get-model)` parsing.
4. Range-subtype encoding (§5.2). Construction-site VCs.
5. `@axiom` registration; `<P>.lyric-contract` extension (§3.2)
   for axiom-list and `@pure` body serialisation.
6. Mode-dispatch and pure-call check (§4.1).
7. `lyric prove` CLI subcommand: takes a manifest, runs verifier,
   reports per-package status. Defaults to error on `unknown`.

**Exit criteria:**

- `Money.make` (`08-...md` §13.2) verifies: VC discharged, no
  runtime asserts emitted in `--release`.
- `Transfer.execute`'s conservation property
  (`08-...md` §13.3) verifies *given* hand-written postconditions on
  `debit`/`credit`. Both helpers are themselves proof-required and
  also discharge.
- A regression suite of 50 small `@proof_required` examples
  (arithmetic, ranges, simple records) verifies in ≤30 s total on
  CI hardware.
- `V0001`–`V0006` and `V0008` are emitted with the correct fix-it
  suggestions on a curated negative-test corpus.

### M4.2 — Quantifiers, loops, structural reasoning (months 45–51)

**Deliverables:**

1. Loop encoding (§5.3): `while`/`for` with explicit invariant.
   *Establish/preserve/conclude* sub-VCs reported separately.
2. Loop-invariant gate (§4.2): `V0005` with fix-its.
3. Quantifiers: `forall`/`exists` over slices, sets, finite ranges,
   enums. Trigger inference. Decidable-fragment enforcement
   (`V0006`).
4. Inductive datatypes: full record / union / opaque encoding,
   pattern-match wp rule.
5. Pure-function unfolding (§5.5).
6. `std.core.proof` standard library subpackage.
7. Goal cache (§7.4).
8. `--allow-unverified` flag for the user's escape hatch on
   `unknown`.

**Exit criteria:** (all met — D-progress-091 / D-progress-129)

- `std.core.proof` self-verifies. Every operation on `List[T]` or
  `Result[T,E]` carries a contract that the verifier discharges.
  **Done** (D-progress-091; 9/9 obligations).
- A non-trivial worked example verifies end-to-end.  **Done**
  (D-progress-129): `examples/pagination.l` (4/4) and
  `examples/token_bucket_proof.l` (6/6) both discharge under Z3.
- 200 verification regression tests (cumulative). **Done**
  (D-progress-091; 266 passing as of D-progress-129).
- A re-verification of `std.core.proof` after a no-op edit
  finishes in < 1 s (cache hit).  **Done** (goal cache,
  D-progress-089).

### M4.3 — Counterexamples, polish, v2.0 release (months 51–57)

**Deliverables:**

1. Counterexample reporting (§9): model extraction, trace
   reconstruction, human + JSON output, suggestion heuristics.
2. `lyric prove --explain --goal <n>` mode (§9.4).
3. `lyric prove --json` schema, frozen as part of the public CLI.
4. Editor integration: LSP server (`Lyric.Lsp`) surfaces
   `V0007`/`V0008` diagnostics with hover-rendered counterexamples
   and code actions for the suggestion list.
5. `@proof_required(checked_arithmetic)` mode (§5.4).
6. `unsafe { … }` + `assert φ` plumbed end-to-end (§3.1 `V0003`,
   `V0009`).
7. Tutorial chapter and "verifying the banking example" walkthrough
   in `docs/13-tutorial.md`.
8. `docs/17-axiom-audit.md` lists every `@axiom` shipped in
   `std.bcl.*`, with rationale.
9. `lyric public-api-diff` aware of contract changes: a SemVer
   minor bump that *strengthens* a `requires:` (or weakens an
   `ensures:`) is a SemVer-breaking change. (Already specified in
   `01-language-reference.md` §11; Phase 4 is the first time the
   tooling can detect it.)
10. v2.0 release: Phase 4 shipped. Conference talk material.

**Exit criteria:**

- A verification-curious working programmer can take the banking
  example, mark it `@proof_required`, and discharge all VCs with
  user-written contracts in under one day.
- Counterexamples are produced for every contrived `V0008` case in
  the regression suite, with a model that names the source-level
  binder that violated the contract.
- The verifier is demonstrably solver-pluggable: a feature-flag
  build with CVC5 passes ≥95 % of the M4.2 regression suite.

---

## 13. Testing strategy

Per `05-implementation-plan.md` §"Testing the compiler", Phase 4
ships ~500 verification-specific tests. Their breakdown:

| Bucket                         | Count goal | What's checked                                |
|--------------------------------|------------|------------------------------------------------|
| Positive arithmetic            | 100        | `unsat`, fast (≤ 50 ms each)                  |
| Positive structural            | 100        | datatypes, pattern matching, slices, length  |
| Positive loops                 | 50         | establish/preserve/conclude all discharge     |
| Positive quantifiers           | 50         | finite domains; trigger picking sane          |
| Negative — counterexamples     | 100        | each fails; counterexample matches expected  |
| Negative — diagnostics         | 50         | `V0001`–`V0009` cases; exact text match       |
| Soundness — anti-axiom         | 25         | a deliberately wrong `@axiom` does *not* save the proof |
| Solver-swap                    | 25         | run-against-CVC5 corpus (subset of above)     |

The soundness-anti-axiom bucket is the most important. It guards
against "the verifier is hiding a `true` assertion behind a quirk
of how axioms compose." For each test we know the proof should
*not* go through; failing to fail is a critical regression.

Tests live under `bootstrap/tests/Lyric.Verifier.Tests/` (Expecto,
per the project convention in `bootstrap/Directory.Build.props`).

---

## 14. Hiring and external collaboration

`05-implementation-plan.md` Phase 4 calls out: "you will hire
someone with formal methods background." Concretely:

- One full-time engineer with ≥3 years of formal-methods
  practice (Dafny, F\*, Coq+SSReflect, Lean tactic-mode, SPARK,
  Frama-C, or equivalent). Familiarity with Z3 SMT-LIB internals
  is mandatory.
- An advisory relationship with one academic group whose
  research overlaps Lyric's verification approach. Examples
  (illustrative, not commitments): groups maintaining Dafny,
  Why3, F\*, or any active SMT-tool research lab. The advisor
  reviews the wp/sp implementation against published
  formalisations of the same calculus and signs off on the
  soundness theorem (`08-...md` Theorem 1) before v2.0.
- Budget for one academic publication: a workshop paper at a
  verification venue (CAV, FMCAD, VSTTE, or VMCAI) describing
  the wp/sp calculus, the Lyric-VC IR, and any non-trivial
  encoding choices. Not a credibility *requirement* but a
  credibility *multiplier* with the formal methods community,
  which is who Phase 4 needs to reach.

---

## 15. Risks and mitigations

| Risk                                                                 | Likelihood | Impact   | Mitigation |
|----------------------------------------------------------------------|------------|----------|------------|
| Solver `unknown` rate higher than 2 % in steady state                | Medium     | High     | Document the decidable fragment aggressively; `lyric prove --explain` is good UX; `@runtime_checked` shift is always available |
| Z3 .NET bindings break on a future runtime                           | Low        | Critical | The IR (§6) decouples from Z3; CVC5 fallback is on the regression suite from M4.3 |
| Counterexample messages baffle non-verification users                | High       | Medium   | The `--explain` JSON schema lands in M4.3 so editor integrators can render fix-its; UX iterations are post-v2.0 work |
| Pure-function-body serialisation explodes contract artifacts         | Low        | Low      | One-level unfold by default (§5.5); user opts in to more |
| `std.core.proof` development time exceeds budget                     | High       | High     | Carve `std.core.proof` to the *minimum* needed by the worked examples; defer the rest to Phase 4 polish |
| `@axiom` audit drifts from real usage                                | Medium     | High     | `<P>.lyric-contract` already lists axiom declarations; the v2.0 release blocks on `docs/17-axiom-audit.md` matching the union of axioms in shipped stdlib packages |
| Native AOT compatibility broken by Z3 link                           | Resolved   | n/a      | The verifier is a JIT-mode carve-out (§7.1); `lyric build` without `--prove` stays AOT |
| Soundness bug discovered after v2.0                                  | Medium     | Critical | Soundness-anti-axiom regression suite (§13); academic advisor sign-off; the conservation property test is canary |
| Contract metadata format-break between v1.x and v2.0                 | Low        | High     | `<P>.lyric-contract` versioning already shipped; v2.0 bumps the format version and emits both during a deprecation window |

---

## 16. Out of scope for Phase 4

Explicitly deferred (Phase 4 polish, Phase 5+, or never). Capturing
these here so reviewers do not re-litigate them:

- **Concurrency proofs.** `protected type` invariants are still
  runtime-only. Linearisability proofs are a research project.
- **Async correctness.** `await` in proof-required code remains a
  compile error (`V0002`).
- **String-content reasoning.** Equality and length only. No
  regex, no parsing, no format strings.
- **Self-hosting the verifier.** D-progress-234 shipped a self-hosted
  port (`lyric-compiler/lyric/verifier/`) at M4.1 parity as part of
  Phase 5 (M5.3).  The F# verifier project has been deleted; `lyric
  prove` routes through the self-hosted implementation.
- **Termination proofs of arbitrary recursion.** Required only for
  `@pure` callees that are themselves used in contracts; the
  decidable fragment requires a structural measure, the
  enforcement of which is left as a later refinement.
- **Multiple-solver portfolio.** D033 ships Z3; CVC5 swap is
  feasible per §6 / M4.3 exit criterion; an *active portfolio*
  ("try them in parallel, take whichever returns first") is post-
  v2.0.
- **Inferred loop invariants.** The user writes them. Houdini-style
  inference is a research direction worth tracking but not
  promising.
- **Proof certificates.** Z3's `unsat`-cert export is unreliable;
  consumers are few. The verifier records *that* a proof closed
  and which Z3 version closed it; certificate export is a Phase 6+
  ask-driven feature.

---

## 17. References

- `docs/01-language-reference.md` §6, §13.
- `docs/03-decision-log.md` D013, D033, D035.
- `docs/05-implementation-plan.md` Phase 4.
- `docs/06-open-questions.md` Q020.
- `docs/08-contract-semantics.md` §§10–13.
- `docs/09-msil-emission.md` §16.
- `docs/14-native-stdlib-plan.md` §3, §4.
- C. A. R. Hoare, *An Axiomatic Basis for Computer Programming*,
  CACM 1969.
- K. Rustan M. Leino, *Dafny: An Automatic Program Verifier for
  Functional Correctness*, LPAR-16, 2010.
- L. de Moura, N. Bjørner, *Z3: An Efficient SMT Solver*, TACAS
  2008.
- Tucker Taft et al., *Ada 2012 Rationale*, contracts chapter.
- *SPARK 2014 Reference Manual.*

---

## Appendix A. `lyric prove --json` schema (frozen v1)

The JSON surface emitted by `lyric prove --json` is part of M4.3's
public contract.  Editor extensions, CI gates, and downstream
tooling can rely on the keys, types, and value vocabulary below
without breakage across patch and minor compiler releases.

### A.1 Top-level object

| Field         | Type   | Notes                                                                                                              |
|---------------|--------|--------------------------------------------------------------------------------------------------------------------|
| `file`        | string | The source file path passed to `lyric prove` (verbatim, not canonicalised).                                        |
| `level`       | string | The verification level — one of `@runtime_checked`, `@proof_required`, `@proof_required(unsafe_blocks_allowed)`, `@proof_required(checked_arithmetic)`, `@axiom`. |
| `goals`       | array  | Goal objects (see A.2).  Always present; empty when the file has no proof obligations.                             |
| `diagnostics` | array  | Diagnostic objects (see A.3).  Always present; empty when there are none.                                          |
| `summary`     | object | Counts (see A.4).                                                                                                  |

### A.2 Goal object

| Field      | Type                  | Notes                                                                                                                   |
|------------|-----------------------|-------------------------------------------------------------------------------------------------------------------------|
| `index`    | integer               | 0-based goal index, stable for `--explain --goal <n>` cross-reference.                                                  |
| `label`    | string                | `<function>$<role>` — e.g. `id$post`, `transfer$pre`, `body$assert`.  Free-form but stable for a fixed source.           |
| `kind`     | string                | One of `postcondition of <fn>`, `precondition of <fn> at call site`, `loop invariant — establish/preserve`, `loop invariant — conclusion`, `user assertion`, `range constructor side condition`. |
| `line`     | integer               | 1-based source line of the goal's origin span.                                                                          |
| `col`      | integer               | 1-based source column of the goal's origin span.                                                                        |
| `outcome`  | string                | One of `discharged`, `counterexample`, `unknown`.                                                                       |
| `model`    | string &#124; null    | Raw `(get-model)` block on `counterexample`; the solver's `unknown` reason on `unknown`; `null` on `discharged`.        |
| `smtPath`  | string &#124; null    | Path to the goal's SMT-LIB v2.6 source on disk under `target/proofs/`, or `null` when SMT was not written.              |
| `suggestions` | array of string    | Heuristic contract clauses the user could add to block this counterexample (e.g. `"requires: x > 0"`).  Always present; empty for `discharged` / `unknown`, capped at 3 for `counterexample`.  See §9.3 for the boundary-suggestion policy. |

### A.3 Diagnostic object

| Field      | Type    | Notes                                                                                       |
|------------|---------|---------------------------------------------------------------------------------------------|
| `code`     | string  | `V0001`–`V0009`, `V0023`, `P####`, etc.  See `docs/01-language-reference.md` §13 + §10.     |
| `severity` | string  | `error` or `warning`.  Under `--allow-unverified`, V0007 surfaces as `warning`.             |
| `message`  | string  | Human-readable diagnostic text (LF-newline-separated for multi-line counterexample blocks). |
| `line`     | integer | 1-based source line.                                                                        |
| `col`      | integer | 1-based source column.                                                                      |

### A.4 Summary object

| Field             | Type    | Notes                                                                          |
|-------------------|---------|--------------------------------------------------------------------------------|
| `total`           | integer | `goals.length` — sum of the three counts below.                                |
| `discharged`      | integer | Goals whose outcome is `discharged`.                                           |
| `unknown`         | integer | Goals whose outcome is `unknown`.                                              |
| `counterexamples` | integer | Goals whose outcome is `counterexample`.                                       |

### A.5 Exit codes

`lyric prove --json` exits 0 when the summary is clean (no errors,
no counterexamples) and 1 otherwise.  Under
`lyric prove --json --allow-unverified`, V0007 unknowns are
warnings — the run exits 0 if no V0008 counterexamples are present.
V0008 always exits 1.

### A.6 Stability promise

The keys, value types, and string vocabularies in tables A.1–A.4 are
frozen as of M4.3.  Future minor compiler releases may add new
fields or new outcome / kind / code values, but never remove or
rename existing ones.  Tooling that consumes this schema should
ignore unknown keys.
