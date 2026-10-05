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
   conditions for `lyric prove`.  (A build still emits their runtime
   asserts; see §10.)
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
                `lyric build` continues to MSIL emission
                as in M1.4; every clause stays a runtime
                assert (§10, D-progress-994).
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
| `V0012` | _(planned code, **repurposed**)_ The mode checker now uses `V0012` for `await` inside a `try`/`catch`/`finally` block in an async function (a CLR IL constraint, #2985/#3113), not for the broad "async in proof-required" rejection planned here.  The actual verifier-side rejection of contracts on async/generator functions ships as `V0032` (below, #3298). | — | — |
| `V0031` | **Retired** in #336.  The self-hosted aspect weaver (`Lyric.Weaver.weaveFile`, ported from `bootstrap/src/Lyric.Emitter/Weaver.fs`) now runs in the verifier driver before VC generation, so proofs discharge against the woven wrapper's composed contracts — not the bare body.  The same-package limitation that previously made the warning incomplete is gone; cross-package aspect detection is still future work (imported aspect annotations don't fire weaving today, mirroring the original `V0031` cross-package gap). | — | — |
| `V0032` | A `@proof_required` `async func` or `yield`-bearing generator carries a contract clause (`requires:`/`ensures:`).  The WP/SP calculus has no model for suspend/resume control flow — `await`/`yield` has no Term translation and would be coerced to an opaque symbol, so the contract would be checked against an unmodelled body.  `goalsForFunction` rejects such functions before VC generation and emits no goals (rather than vacuous/opaque ones).  A non-contract async function is unaffected.  Effect-aware VC generation is future work (#3298). | error | move the contract to a synchronous core, or mark `@runtime_checked` |
| `V0033` | A proof obligation cannot be translated into the proof logic faithfully: an integer/bitvector sort mix with no implicit conversion (a `UInt` operand beside an `Int` variable, a negative constant or a constant too wide for an unsigned type, the negation of an unsigned value), a declared result range whose bound is not an integer literal that fits its base, or a call whose arguments cannot be paired with the callee's parameters (an unknown parameter name, a parameter given twice, an omitted parameter with no default; #7873).  The verifier reports the construct instead of reasoning about a term that means something else, once: at the construct when VC generation meets it (a construct in a callee's contract is reported once however many calls translate it), or at the goal when substitution first brings the mix together. Every goal the construct reaches stays failed (`unknown`, never `discharged` — an untranslatable result range included), and neither the trivial discharger nor the solver sees it (#7848, #7874). | error | add an explicit conversion, or state the bound as a literal of the base type |

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
| `Int`, `Long`, `Nat`      | `Int` (mathematical integer)                 | overflow handled separately, see §5.4; a parameter, field or callee result carries its type's 32- or 64-bit bounds as a hypothesis. `/` and `%` truncate toward zero as at runtime, not SMT-LIB's Euclidean `div`/`mod`: they render as `lyric!tdiv`/`lyric!trem`, which the preamble defines as `(ite (= b 0) (div a 0) (ite (= (>= a 0) (>= b 0)) (div (abs a) (abs b)) (- (div (abs a) (abs b)))))` and `(ite (= b 0) (mod a 0) (- a (* b (lyric!tdiv a b))))`. A zero divisor falls through to the solver's unspecified `div`/`mod`; the value never matters, because every integer `/` and `%` carries the obligation `divisor != 0` — division by zero panics in every build profile (#7870, #8107) |
| range subtype `T range a ..= b`, named or inline | the base type's sort with an implicit `a ≤ x ≤ b` hypothesis on every parameter, field, callee result, binding and assigned value, and on every `forall`/`exists` bound variable (below) | preserves identity loss is fine in proof; CLR identity matters only for emission. A named range subtype (`type Port = UInt range 1 ..= 65535`) is its refined underlying type; `Port.from(x)` is the value `x` with the obligation that it lies in the range, `.value` is the identity, and `tryFrom` is uninterpreted (#7872) |
| `UInt`, `ULong`, `Byte`   | `(_ BitVec n)`                               | bitvector arithmetic, slow but decidable. A `u8`/`u16`/`u32`/`u64` literal is a `(_ bvN n)` constant of its width (a `u64` literal from 2^63 up is its unsigned value, #7839); an unsuffixed literal next to an unsigned operand takes that operand's width. Ordering, `/` and `%` use the unsigned `bvult`/`bvule`/`bvugt`/`bvuge`/`bvudiv`/`bvurem`; `+`, `-`, `*` are `bvadd`/`bvsub`/`bvmul`. A narrower unsigned operand zero-extends along `Byte < UInt < ULong`, and a `Byte` enters the signed chain through `bv2nat`. A range subtype over an unsigned base folds its bounds unsigned. Any other mix of the two sorts (a `UInt` beside an `Int` variable, a negative constant as an unsigned value, an unsigned negation, a bound that does not fit its base) fails closed with `V0033` (#7848) |
| `Char`                    | `Int` (its code point)                       | a `Char` literal is its code point; every `Char` value carries `0 ≤ c ≤ 65535` and `c < 55296 ∨ 57343 < c` (a BMP scalar, docs/01 §2.1) wherever a range subtype carries its range, so `==` and ordering on `Char` are the integer ones. (#8214) |
| `Float`, `Double`         | SMT `Real` (mathematical reals)              | sound approximation: avoids IEEE 754 FP theory and its rounding-mode complexity; linear arithmetic over reals is decidable and fast; division emits `/` (Real div) not `div` (integer) |
| `String`                  | uninterpreted sort with `length: String -> Int`, `==` | content reasoning out of scope |
| record                    | SMT-LIB datatype                             | one constructor, fields as selectors |
| union                     | SMT-LIB datatype                             | one constructor per variant |
| enum                      | SMT-LIB datatype, no payloads                | as union with arity-0 variants |
| `slice[T]` of compile-time-bounded length | array sort with separate length | length axiom asserts `0 ≤ length ≤ N` |
| `slice[T]` unbounded      | uninterpreted sort + length function          | `forall` over its elements requires explicit bound (§4.2 §11) |
| opaque type               | SMT-LIB datatype with one private field       | fields are not exported across packages — the VC generator inlines invariant facts but not the representation |
| function type             | uninterpreted sort `Function`                | a function the file declares, named as a value, is one symbol per function; a call through a binding holding one is a call of that function, otherwise the call site's own result; `==`/`!=` on function values fail closed (#8109) |
| `Result[T, E]`            | the standard Lyric-defined two-arm union; treated as datatype | |
| protected-type ref        | fields bound as symbolic `Real`/`Int`/… vars | per-entry sequential reasoning via `goalsForProtectedType`; `invariant:` clauses are `requires:` hypotheses on each entry and `ensures:` obligations over the values its `var` fields hold when it returns (#8102) |

Range subtype values lift to `Int` with the bound as a `forall`-
introduced hypothesis. This is the same trick SPARK uses; it lets
the solver carry the bound through arithmetic without a special
theory.

The facts a value of a declared type carries — its range, and for an
`Int`/`Long` its width — come from one function, `valueFactsForTerm`
(`verifier/theory.l`), for every value the verifier does not otherwise
determine: a parameter, a quantifier's bound variable, a variable after
code that may change it (a loop, an `out`/`inout` argument, a lambda's
captures), a lambda parameter, an uninitialized `var`, a callee's result
and a field read. A computed value (a binding's initializer, an assigned
value) carries its declared range but not its width: its arithmetic is
mathematical in the proof, so only `checked_arithmetic` proves it fits.

A quantifier ranges over the values of its bound variables' types
(#8214). `forall (x: T) P` is `forall x. facts_T(x) ⇒ P` and
`exists (x: T) P` is `exists x. facts_T(x) ∧ P`, with a `where` clause
conjoined to the facts, so an `exists` over a range subtype is witnessed
only by a value in the range, and a `forall` over one is not checked
against values outside it. Each bound variable is a solver name of its
own (`i!7`), so a term the body reads from an enclosing binding spelt the
same (`old(n)` inside `exists (n: Small)`) is never captured by it. A
type's facts reach the bound variable through distinct types
(`type Score = Small`), type aliases of a scalar (`alias S = Small`,
`alias Pct = Int range 0 ..= 100`, chains of them), chains of distinct
types (`type Grade = Score`) and inline ranges (`forall (i: Int range 2
..= 5)`). A range subtype over a distinct or range subtype, or over
`Char`, is rejected by the type checker (`T0091`), so no value needs the
intersection of two declared ranges. `UInt`, `ULong` and `Byte` bound variables are
bitvectors, non-negative by construction. A bound variable over plain
`Int`, `Long`, `Nat`, `UInt`, `ULong`, `Float`, `Double` or `String` is
rejected before proof (`V0006`).

### 5.3 Loops

A loop `while c invariant: ι { S }` is proved by the standard Hoare
rule, in an arbitrary iteration's state (#8102):

> `assert ι` (at loop entry), and `c`'s own obligations under `ι`
> `havoc` every variable `c` or `S` may change
> `assume ι`; `assert` `c`'s own obligations (after any iteration)
> `assume c`; `S`, its obligations proved under `ι ∧ c`
> `assert ι` (preserved: over the values `S` leaves)
> `assume ι ∧ ¬c` (the rest of the block)

What may change is every variable assigned anywhere in `c` or `S` — in a
nested `if` or `match` arm, an inner loop, a lambda — and every variable
passed to an `out`/`inout` parameter of a function the file declares,
including the receiver of such a method. Each havocked variable is a
fresh symbol per loop translation (`i!loop12`), never shared with
another loop or path, and keeps its type's width and range as a fact.
The preserved invariant is translated with a placeholder for each
changed variable, which every path through the body replaces with the
value it leaves (`finishPost`); the same mechanism states an `ensures:`
over an `out`/`inout` parameter or a protected type's `var` field at the
function's end, with `old(p)` its entry value.

The body is walked as statements to its end — an `if` or a call in last
position changes state, it is not the loop's value. A `return` or `?`
in the body, like `break` and `continue` (#7396), fails closed
(`V0026`): the invariant says nothing about the value it leaves with.
The loop's exit facts hold only after the loop, and the facts one branch
of an `if` establishes hold only under that branch's condition, so a
loop that never exits on one path proves nothing about another.

The VC generator emits *establish*, *preserve* and the condition's and
body's own obligations as separate goals, so a failed proof points to
"the body does not preserve the invariant" rather than the lump "the
loop is wrong."

`for x in xs invariant: ι { S }` desugars to a `while` where the
implicit iterator state is `(remaining: slice[T], processed: slice[T])`
and the iteration step is `(processed.append(x), remaining.tail)`.
The user-written invariant is conjoined with the implicit
`xs == processed ++ remaining`.

### 5.4 Overflow

Range subtypes give bounded integers. Plain `Int`/`Long` are
unbounded mathematical integers in the proof but bounded `Int32`/
`Int64` at runtime, where `+`, `-`, `*` and unary `-` panic on overflow
in a `debug` build and wrap in a `release` build (D163). `lyric prove`
takes no build profile: it reasons with the `debug` (checked) semantics,
the sound choice for a proof, since a panicking operation never produces
the value a later obligation is stated over (#7871).

- **Width facts, every mode.** A value that exists at runtime holds a
  value of its type, so the verifier assumes `Int.MinValue <= v <=
  Int.MaxValue` for each `Int` (and the 64-bit bounds for each `Long`)
  parameter, protected-type field, callee result and variable a loop
  havocs. A value the body computes gets no such fact from its type; its
  arithmetic stays mathematical.
- **`@proof_required`** (no modifier): arithmetic is mathematical and
  overflow is not an obligation. A proof is a partial-correctness proof
  under the `debug` semantics: an execution that overflows panics before
  the postcondition is reached. It does not cover a `release` build, where
  the same operation wraps instead.
- **`@proof_required(checked_arithmetic)`**: every signed `+`, `-`, `*`
  and unary `-` carries the obligation `Min <= result <= Max` for the
  operand's own width — 32 bits for `Int`, 64 for `Long` (and `Nat`) — so
  `2147483647 + 1` on `Int` is refuted while the same sum on `Long` is
  not. The width comes from the expression's static type: a binding's or
  field's declared type, a callee's result type, an `i64`/`i32` suffix. An
  unsuffixed-literal expression is checked as an `Int` unless a literal
  needs 64 bits; checking a `Long` against the narrower range can fail a
  proof, never pass a wrong one. A compound assignment (`+=`, `-=`, `*=`)
  carries the obligation of its operator. On a `UInt`/`ULong`/`Byte`
  bitvector the obligation is that the operation does not wrap: `x <= x +
  y` for `+`, `y <= x` for `-`, and `y == 0 or (x * y) / y == x` for `*`,
  all ordered unsigned (#7848). With no overflow possible, both profiles
  compute the same values, so a `checked_arithmetic` proof holds for a
  `release` build too.

At a call the callee's contract is instantiated with the argument each
parameter receives: named arguments by name, positional ones in order
into the remaining parameters, an omitted parameter by its default, and a
record constructor's fields likewise (#7873).

Two values the program can tell apart never share a term (#8109):

- `@pure` is trusted, not checked: the verifier believes a `@pure`
  function computes its result from its arguments alone. A call of a
  function the file declares — free, static or method — is the callee
  applied to its arguments only when the callee is `@pure` and every
  argument is a value `==` sees all of: a `Bool`, integer, bitvector,
  `Float`/`Double` or `String`; `Unit`, a tuple, or the standard
  `Result`/`Option` of such values; an enum the file declares, or a
  non-generic record or union the file declares whose fields are all
  immutable and of such types; or a function the file declares `@pure`,
  named as a value. Two such calls with equal arguments are equal. Any
  other call's result belongs to its call site: an uninterpreted function
  of its own applied to the arguments, so two call sites never share a
  result — `f(x) == f(x)` is not provable for a counter or a random
  source, nor for a `@pure` function passed a closure whose captured
  variable changed, a `List` that grew, or a protected object — and
  under a quantifier the result varies with the bound variable. The
  callee's `ensures:` still says what the result is. A `@pure` body the
  verifier cannot translate faithfully (V0033, or a value not of the
  result's sort) is not assumed, and the call keeps its contract.
  `@pure` is read from the declaration in the file being proved; `lyric
  prove` does not read other packages' contract metadata, so a callee
  declared elsewhere (another file, another package, the standard
  library) is not known to be pure, and each of its call sites has a
  result of its own, in a body or a contract alike.
- A function the file declares, named as a value (`val h = sq`), is one
  symbol per function, which says which function a call through the
  binding reaches: as the binding holds it at the call, so after
  `h = other` the call is `other`'s. A binding holding anything else — a
  lambda, a parameter, a value a loop has havocked — is called as a
  computed callee, a result of the call site's own. Whether two function
  values are equal is not modelled (a .NET delegate compares its method
  and target, a JVM lambda its reference, and one function named twice
  may be two objects).
- `==` and `!=` are the solver's equality only where that is the
  runtime's on every target: primitives and `String`; `Unit`, tuples and
  the standard `Result`/`Option` of such values; enums; and the file's
  non-generic unions and records that compare field by field (D164,
  D172) — a record with no `var` field, or one that derives `Equals` —
  whose fields are all such values (a recursive record included). Any
  other operand fails closed (V0033): a function or lambda, a mutable
  record that keeps identity, a protected, opaque, interface or extern
  value, a host collection, a generic record, an alias, an unannotated
  lambda parameter, a qualified path, or a module-level name with no
  declared type. A module-level `val` or `const` with a declared type is
  a value of that type. Inside a generic, `==` over its own type
  parameter is an opaque equivalence — whatever `==` its binding has, it
  is reflexive, symmetric and transitive, as the solver's equality is —
  so `ensures: result == x` on `func identity[T]` still proves. Where a
  call instantiates such a contract, each `==` in it is checked again
  over the argument terms, and fails closed (V0033) if they are not
  modelled values: `same(one, one)` against `requires: a == b` does.
- The built-in `Unit` and tuple sorts have names no source type can take
  (`Lyric!Unit`, `Lyric!Tuple<n>`), so a user `record Tuple` is a
  datatype of its own. A type the file declares or imports by name with
  a primitive's name (`record Unit`, `record Int`) would be read as the
  primitive, so such a file fails closed (V0033).
- Every binding has a value of its own. Each name a destructuring `val`
  pattern binds is a fresh unknown (the verifier does not take values
  apart), so the same name in two patterns never denotes one value. A
  name no binding declares is module-level, where a `val` never changes;
  it is the symbol `global!<name>`, apart from any parameter or binding
  spelt the same. An assignment to such a name fails closed (V0026).
- An `if` statement's branches, and function, lambda and loop bodies,
  are scopes. The walk appends the rest of the block to each branch, so
  a branch ends with a marker that restores every binding it shadowed
  (or unbinds a name it introduced), with its value and mutability as of
  the shadowing. While an `out`/`inout` parameter or a loop-changed
  variable is shadowed, the postcondition's placeholder for it reads the
  shadowed binding, which cannot change meanwhile.

A method call `recv.m(args)` reaches a dot-named `func R.m(self: R, ...)`
the file declares when `recv` is a value of the file's record (or
protected type) `R` and `R` declares no method `m` of its own; it is
applied by that function's contract, the receiver its first argument,
with a result of its own at each call site unless the method is `@pure`
— two calls agree only where the contract says so. `R.m(args)` on a type
name is a call of `func R.m` by path. Any other method call is an
uninterpreted function of the receiver and the arguments, one function
per method name, argument shape (a named argument keeps its name) and
sorts: `a.f() == a.f()` holds by congruence, `a.f() == b.g()` and
`a.f() == b.f()` do not. Congruence treats the method as a function of
its receiver and arguments — true of the `@pure` calls a contract may
make (T0133), and an assumption about an unmodelled method called in a
body, which mutation through the receiver (the verifier has no heap)
would break. A call through a computed callee is a fresh
value. No two distinct values share a symbol: every value the verifier
introduces — a call result, a havocked variable, an unmodelled
expression — has a name of its own, with a `!` no Lyric identifier
contains (#8101).

An argument passed to an `out`/`inout` parameter holds a new, unknown
value after the call; in the callee's `ensures:` the parameter is its
value after the call, a symbol of its own, and `old(p)` the argument.
A write to a record field or element fails closed (`V0026`): a record is
a reference, and the verifier has no heap to follow its aliases.

The same call's facts never prove its own precondition. A contract
expression — `requires:`, `ensures:`, a loop `invariant:`, an `assert` —
translates to its side conditions (callee `requires:`, overflow bounds),
the facts its evaluation brings (callee `ensures:`) and its value; proving
it takes `sides ∧ (facts ⇒ value)`, and assuming it gives all three. A
loop condition's side conditions are guarded by the invariant only, never
by the condition's own facts, which guard the body and the code after the
loop.

Calls the verifier cannot follow fail closed or are over-approximated
(#8102):

- Two `out`/`inout` parameters bound to one variable (`f(a, a)`) fail
  closed (`V0033`): the callee's proof assumes they do not alias.
- A parameter default sees no other parameter, only module-level names
  (docs/01); it is translated with no bindings, and one naming a value the
  verifier does not model (a module `val`) fails closed (`V0033`).
- `f[T](args)` is a call of `f`; `P.f(args)` with `P` the file's own
  package reaches `f` by contract like `f(args)`.
- A call the verifier cannot resolve may have `out`/`inout` parameters:
  every argument (or receiver) naming a binding a call may store into — a
  `var` local, an `out`/`inout` parameter, a protected type's `var` field —
  holds a new, unknown value afterwards.
- Inside a protected type, a bare call to one of the type's own members
  fails closed (`V0033`): its effect on the fields is not modelled.
- An expression statement of any form keeps its obligations and facts.
- A block used as a value — an `if`-expression's branch, a match arm, a
  `{ ... }` expression — runs its statements in order before its last
  expression gives the value: bindings are visible to the rest of the
  block, `assert`s are obligations and then facts, and every callee
  precondition is an obligation. An assignment, a jump (`return`, `break`,
  `continue`, `throw`, `?`) or a loop inside such a block fails closed
  (`V0033`) (#8107).
- An operator or construct the verifier does not model (V0023, V0024) is
  an unknown value, but the operands and subexpressions it evaluates keep
  their obligations and facts (#8107).
- Integer `/` and `%` (and `/=`, `%=`) carry the obligation `divisor != 0`
  in every mode, and on a signed operand `not (dividend == Min and divisor
  == -1)` for its width: both trap in every build profile (D163) (#8107,
  #7882). When the verifier does not know the width, both the 32- and
  64-bit minimums are excluded. An expression combining operands (an
  arithmetic operator, the branches of an `if` or `match`) has an unknown
  width when any operand does — a known `Int` operand does not make a
  possibly wider one narrow — except an unsuffixed literal, which takes
  its context's type. A distinct value's `.value` has the distinct type's
  width and range, `T.from(x)` has `T`'s width, and a match binding of the
  whole scrutinee carries the scrutinee's width and range. (The `+`, `-`,
  `*` and negation overflow obligations use the widest known operand, or
  32 bits when none is known: a result is at least that wide, so this can
  only make them stricter.)
- Inside one expression, evaluation order is respected: a call's receiver
  or computed callee, then its arguments as written — named and positional
  alike, whatever the parameter order (D171) — then the omitted
  parameters' defaults, a branch or arm after a condition,
  scrutinee or guard, the arms after a guard that ran and failed, and the
  right operand of a binary operator see the state the earlier part
  leaves — a variable it passed to an `out`/`inout` parameter holds a new
  value. Index receivers before indices, interpolation segments, and
  tuple and list elements run left to right as well. The values then pass
  to the parameters by `Lyric.Parser.pairCallArgs`, as in the type checker
  and every backend.
- A match arm's guard is translated in the arm's bindings: its side
  conditions and facts hold where the pattern matches and no earlier arm
  did, and the arm is taken when pattern and guard hold. An arm whose
  pattern the verifier does not model (V0027) still has its guard and body
  checked, under an unknown condition and with each binding a value of its
  own; its value is #8142's open question.
- A lambda's body is checked for every call: it is walked as a function
  body, with each parameter a value of its own of its declared sort, each
  captured `var`/`out`/`inout` binding whatever it holds by then and every
  other capture at its value where the lambda is made; nothing the body
  establishes is assumed outside it.
- The right operand of `??` runs only when the left is null, which is not
  modelled: its side conditions hold under an unknown condition (so they
  must hold) and its facts give nothing.
- A `?` or other jump in a loop condition fails closed (`V0026`) (#8143).
- `e?` splits the path where it runs (#8108). Where `e` is an `Err`/`None`
  the function returns `Err(e.error)` or `None` at its own result type, as
  `Lyric.Propagate` lowers it, and its `ensures:` must hold for that
  result: a caller assumes the postcondition of every value a function
  returns, although the runtime does not check it on this exit (D174). Otherwise the path goes on with the payload, and
  facts from the callee's `ensures:` (`result.isOk implies result.value >
  0`) hold of it — for the postcondition; a side goal (a later callee's
  `requires:`, an `assert`) does not see earlier facts yet (#8103 item 1).
  A statement's `?`s are first given bindings of their own
  in evaluation order, with everything evaluated before a `?` bound before
  it too, so a callee's precondition or an `out`/`inout` change before a
  `?` is checked on both paths and one after it only on the success path.
  A place an `out`/`inout` parameter or a method receiver uses stays the
  variable itself, never a copy, so the call's write lands on it; if an
  operand hoisted ahead of the call changes that variable, the call fails
  closed (`V0033`).
  This covers bindings, expression statements, assignments, `return`, a
  statement `if`'s condition and branches, and call arguments, receivers
  and operands. A `?` that runs only conditionally within its statement (a
  branch of an `if` or `match` expression, the right operand of `and`,
  `or`, `implies` or `??`, a lambda, a block used as a value), on a value
  the verifier cannot see is a `Result` or `Option` (an unresolved
  callee), or whose error type differs from the function's fails closed
  (`V0033`); in a loop body or condition it fails closed (`V0026`).
- `Result[T, E]` and `Option[T]` are the SMT datatypes `Lyric!Result` and
  `Lyric!Option` — the standard library's only: where the file, or another
  file of its package, declares a type of that name, the file imports one
  by name or alias, or it imports a whole package outside `Std.*`, the name
  is an ordinary uninterpreted type (a generic type is an uninterpreted
  sort of its arity). "Its package" is the build's: the files
  `Lyric.Discovery.projectEntryFiles` gives for the `[project.packages]`
  (or `[project.tests]`) entry containing the file — an explicit list in
  order, or every `.l` file under the entry's directory, recursively,
  whatever their `package` line — which `lyric build` merges too.
  `lyric prove --manifest` takes each entry's type names over exactly that
  set, and warns about an entry file outside the manifest's tree. A
  single-file proof (`lyric prove <file>`, the LSP) is relative to the
  builds the file's ancestor manifests define: every `lyric.toml` from the
  file's directory up is read, and the files of every entry of any of them
  that contains the file are united; with none, every `.l` file under the
  file's directory, recursively (an over-approximation; a subdirectory with
  its own `lyric.toml` is another project). A manifest that lists files
  outside its own tree cannot be found from such a file: prove that
  package with `--manifest` (D174). Paths are matched case-insensitively,
  which only adds files; symbolic links are not resolved (Std has no
  canonical-path call). The scope is unknown — both names counted as
  declared — when any of those files cannot be read or parsed, a
  containing entry cannot be fully listed, an ancestor manifest is broken,
  any of them carries a custom `@generate(X.Y)` (whose output the build
  adds before merging, and `lyric prove` does not run), or a caller passes
  none (`proveSource`, `proveSourceWithOptions`). `Ok(v)`, `Err(e)`, `Some(v)` and `None` take their type
  where they meet a typed slot (a return, an annotated binding, an
  argument, the other operand of `==`), written positionally or with their
  field named (`Ok(value = v)`, `Err(error = e)`); a value of another sort
  at such a slot fails closed (`V0033`); `.isOk`, `.isErr`, `.isSome`,
  `.isNone` and `isOk(r)`-style calls are case tests, and `.value` and
  `.error` read the payload with the obligation that the value is that
  case, since reading the other case's payload traps (#8108).
- `old(e)` is `e` evaluated with every name that has an entry snapshot (a
  parameter, an `out`/`inout` parameter, a protected `var` field) at its
  entry value.

A side condition, and a fact, holds only where its subterm is evaluated:
the right operand of `and` and `implies` under the left operand, of `or`
under its negation, an `if`-expression's branch under its condition (or
its negation), a match arm under its pattern and the failure of every
earlier arm (an arm pattern or guard the verifier does not model is an
unknown condition). This applies both when an obligation is proved — so
`f(0)` against `requires: x == 0 or pos(x) > 0` need not prove `0 > 0` —
and when a contract is assumed. A callee's contract is translated at a
call against the file's functions, so a call nested in its `requires:`
puts that call's own precondition on the caller.

Recursion through contracts is cut the same way on both sides. A
function's own `requires:` and `ensures:` are translated with it on the
contract stack, as its callers translate them, so what it assumes of its
contract is exactly what they prove. A function reached again inside a
contract it is unfolding is applied without a second unfolding — no facts
— and, if it has a `requires:`, fails closed (`V0033`): its precondition
there cannot be stated. Before goals are generated, the contract-call
graph (an edge from a function to every function its contracts, or its
`@pure` body, call) is checked for cycles; a function on a cycle has its
`requires:` proved at every call but its `ensures:` and `@pure` body never
assumed, since a cycle (`ensures: result == f(x) + 1`) can make them
contradictory. Recursion in a body, outside the contracts, is unaffected.
Parameter and record-field defaults are part of the same picture: a
call's omitted-parameter defaults are translated with the callee on the
contract stack and are edges of the contract-call graph, and a record
field default that constructs its record again fails closed (`V0033`).
As a backstop, contracts and defaults unfold inside one another at most
32 deep; past that the call fails closed (`V0033`).

A local binding shadows a file function of the same name: `val f = ...;
f(x)` is a call through the binding — of the file function it holds, if
it holds one by name, otherwise a computed callee (a fresh result, its
mutable arguments reset). Inside a protected type, `self.m()` fails closed like a
bare `m()`, as does a method call on any receiver the verifier does not
model (V0024).

Known limitations, tracked separately: no heap model, and record
methods never verified (#8110); a callee's `ensures:` about an
`out`/`inout` parameter not linked back to the argument (#8111);
`Float`/`Double` as SMT reals (#8141); the value of an expression `match`
arm with an unsupported pattern (#8142); anonymous-range assignment (#8143);
precision and range gaps (#8103).

Obligations raised inside an expression — a callee's `requires:`, an
overflow obligation — are proved wherever the expression occurs: an
expression statement, a returned value, a `val`/`let`/`var` initializer or
the right-hand side of an assignment (#7871).

A negated integer literal is one signed constant, as
`foldNegatedIntLiteral` makes it for the backends: `-9223372036854775808`,
`-0x8000_0000_0000_0000`, `-2147483648i32` and `-128i8` are their minimum
values, never the negation of a magnitude whose pattern is already
negative (#7853). A range bound is folded the same way.

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
- Every uninterpreted function is declared from its applications in
  the goal's own terms, never from a side list, so none is undeclared;
  a name applied at two signatures (a call cut at a recursive default
  with fewer arguments) becomes one function per signature
  (`f!sig1`, #8102).
- Before a goal reaches the solver it is checked to be well-sorted: a
  value the verifier does not model (its own uninterpreted sort) used
  where an `Int` or a `Bool` is needed fails closed as `V0033`, naming
  both sorts, instead of becoming an ill-sorted query.
- A query the solver rejects (`(error ...)`) is a verifier bug, never a
  property of the program: the goal stays unproved and is reported as an
  internal verifier error naming the goal, even under
  `--allow-unverified`, with the solver's text as a detail line.

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

`@proof_required` modules emit runtime asserts *and* carry their parsed
contracts (D035).  This plan originally had Phase 4 drop the runtime
asserts once the verifier shipped, with `--release` emitting an assembly
with no contract checks (SPARK's `Pre => Static`).  That did not happen:
`lyric build` never runs the verifier, so dropping the asserts left an
unproved `@proof_required` package with no contract checking at all.
D-progress-994 (#7227) therefore keeps them:

| Mode                                     | Runtime asserts emitted by `lyric build`? | VC obligations for `lyric prove`? |
|------------------------------------------|-------------------------------------------|-----------------------------------|
| `@runtime_checked`                       | yes                                       | no                                |
| `@proof_required`                        | yes, except quantifier conjuncts          | yes                               |
| `@proof_required(unsafe_blocks_allowed)` | yes, except quantifier conjuncts          | yes, except inside `unsafe { … }` |
| `@proof_required(checked_arithmetic)`    | yes, except quantifier conjuncts          | yes (with overflow VCs)           |
| `@axiom`                                 | n/a (no body)                             | no                                |

Every build profile keeps the asserts; `--release` does not remove
contract checks (language reference §6.4).  Eliding the assert for each
obligation the verifier discharges during the build is tracked in #7431.

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

- `Money.make` (`08-...md` §13.2) verifies: VC discharged.  (The
  build still emits its runtime asserts in every profile; see §10.)
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
