# 08 — Operational Semantics for Contracts

Phase 0 deliverable #5 (per `docs/05-implementation-plan.md`).

This document defines, in formal notation, what `requires`, `ensures`,
`invariant`, and `when` clauses *mean*. It is the source of truth for
two questions a Phase 1 implementer must answer:

1. **Where, in the lifecycle of a function or type, are contract
   expressions evaluated?**
2. **What is the observable effect of a contract that holds, fails, or
   cannot be discharged statically?**

The semantics is presented in two parts:

- **§5–§9** describe the *common* dynamic semantics — the meaning of
  contracts as runtime obligations on a program's execution. This is
  the model that `@runtime_checked` modules realise directly.
- **§10–§12** describe the *proof-required* semantics — how the same
  contracts give rise to verification conditions discharged statically
  by an SMT solver. The two views are *consistent*: any execution that
  the runtime semantics admits is also admitted by the proof semantics
  (Theorem 1, §13.1).

Where the language reference (`docs/01-language-reference.md`) and this
document disagree on contract behaviour, **this document wins** and the
reference is updated. Conversely, this document does not introduce any
syntactic novelty; every clause referenced here corresponds to a
production in `docs/grammar.ebnf`.


## 1. Overview

A Lyric program contains four kinds of contract clause:

| Clause       | Attaches to               | Sense        | Evaluated when |
|--------------|---------------------------|--------------|----------------|
| `requires:`  | function / entry          | precondition | on entry       |
| `ensures:`   | function / entry          | postcondition| on return      |
| `invariant:` | record / opaque / protected| type invariant | at every public boundary |
| `when:`      | protected entry           | guard / barrier | before entry admits caller |

A contract clause carries a *contract expression* — a Boolean expression
in a restricted, side-effect-free sublanguage (§4). Three special atoms
are admitted only inside contracts:

- **`old(e)`**, valid only in `ensures:` clauses, evaluates `e` against
  the *pre-state* of the function call.
- **`result`**, valid only in `ensures:` clauses (and only on
  non-`Unit`-returning functions), refers to the function's return
  value.
- **`forall (x: T) ...` / `exists (x: T) ...`**, quantifiers over a
  *bounded* domain (a slice, a set, or a finite enumerable type).

A contract that *fails* under the runtime semantics raises a `Bug` with
a specific tag (`PreconditionViolated`, `PostconditionViolated`,
`InvariantViolated`, `BarrierViolated`). `Bug`s propagate per language
reference §8.2: out of regular functions until caught by `try`/`catch`,
to the awaiter for async tasks, with state-rollback for protected entries.

A contract that fails under the proof semantics is a *compile-time
error*: the verifier reports the unresolved verification condition (VC)
together with a counterexample.


## 2. Notation

### 2.1 Stores, environments, and values

We model program state as a pair:

> σ = ⟨E, H⟩

where:

- **E** is a stack of environments (one per active activation frame).
  An environment binds local names to values: `E(x) = v`.
- **H** is the heap. A heap address `ℓ ∈ Addr` resolves to a value
  via `H(ℓ) = v`.

Values **v** range over:

- primitive values `n: Int`, `b: Bool`, `s: String`, `()`, …
- record values `record{ f₁ = v₁, …, fₖ = vₖ }`
- union values `Tag(v₁, …, vₖ)` (where `Tag` is a constructor name)
- array / slice values `[v₁, …, vₙ]`
- references `ℓ ∈ Addr` (used internally for `inout`, opaque cells,
  and protected-type state)
- the bottom value `⊥` (uninhabited; only used to type `Never`)

The metavariable σ also carries a *frame's contract context*
`κ ⊆ {old: Σ, result: v, ...}` introduced when an `ensures:` clause is
evaluated; see §5.

### 2.2 Judgments

We use **big-step evaluation** judgments:

> ⟨e, σ⟩ ⇓ v       (expression e in store σ evaluates to value v)
>
> ⟨S, σ⟩ ⇓ σ'      (statement S in store σ produces store σ')

Failure is encoded as an alternative result kind:

> ⟨e, σ⟩ ⇓ **Bug**(tag, msg)
>
> ⟨S, σ⟩ ⇓ **Bug**(tag, msg)

A judgment that produces `Bug` propagates outward; rules are written so
that any non-`Bug` premise must hold for the rule to apply. We omit
explicit `Bug`-propagation rules — they are uniform: any premise of the
shape `⟨e, σ⟩ ⇓ v` may instead match `⟨e, σ⟩ ⇓ Bug(t, m)`, in which
case the conclusion produces `Bug(t, m)` unchanged.

### 2.3 Verification-condition judgments

For the proof semantics (§10) we use Hoare-triple notation:

> ⊢ {P} S {Q}

read "under hypothesis `P`, statement `S` terminates in a state
satisfying `Q`." Verification conditions (VCs) are the *side conditions*
that must be discharged by the SMT solver to derive these triples.

We write `Γ ⊢ φ` for "in proof context Γ (axioms, type assumptions,
contracts of called functions), the formula φ is valid."

### 2.4 Notation for contracts

Where a contract clause `C` is attached to a function `f`, we write:

- **`Pre_f`** — the conjunction of all `requires:` clauses on `f`.
- **`Post_f`** — the conjunction of all `ensures:` clauses on `f`.
- **`Inv_T`** — the conjunction of all `invariant:` clauses on type `T`.
- **`Barrier_e`** — the `when:` clause on protected entry `e` (or `true`
  if absent).

Multiple clauses of the same kind on the same declaration (permitted
by the language reference §6.1) are conjoined left-to-right: their
order of evaluation matters only for *which* clause is reported when a
violation occurs, not for the truth of the conjunction.


## 3. Program model

### 3.1 Module verification level

Every package `P` carries a verification level

> level(P) ∈ { runtime_checked, proof_required, proof_required_unsafe, axiom }

determined by the package-level annotation (`@runtime_checked`,
`@proof_required`, `@proof_required(unsafe_blocks_allowed)`,
`@axiom`). The level is fixed at compile time and cannot vary across
the package's source files.

The four levels relate as follows:

```
   axiom  ──────────────────────────────────────►  trusted by all callers
              (extern declarations only;
               see §12)

   runtime_checked  ◄──────────►  proof_required
              ▲                            ▲
              │                            │
     contracts as runtime         contracts as VCs
     assertions; failures         discharged by SMT;
     are Bugs at runtime          failures are
                                  compile errors
```

A function declared in package `P` inherits `level(P)`. Every call
site `c` calling a function `f` is constrained by:

> level(callee(c)) ⊒ level(caller(c))

where the partial order is `axiom ⊐ proof_required(_unsafe) ⊐
runtime_checked`. Equivalently: a `@proof_required` module may call
other `@proof_required` modules, primitives, or `@axiom` externs;
it may *not* call `@runtime_checked` code (else the proof is
unsound). A `@runtime_checked` module may call anything.

### 3.2 The `old` and `result` slots

Each activation frame `F` for a function `f` carries two
contract-only slots:

- `F.old` — a snapshot of the function's parameters and reachable state
  at entry, taken immediately *after* `Pre_f` is evaluated and *before*
  the function body runs. The snapshot is *deep with respect to fields
  the contract reads* (see §5.2).
- `F.result` — the function's return value, populated immediately after
  the function body produces a value and before `Post_f` is evaluated.

Both slots are inaccessible to the function body; they are visible only
inside contract expressions.

### 3.3 The pure subset of values

Contract expressions evaluate over the *pure* projection of values:
mutable cells (cells reachable through `var` or `inout` parameters)
are read but never written. The semantics in §6 only defines reads;
attempting a write inside a contract is a static error caught by the
contract validator (§4.4) — it is not given a runtime semantics.


## 4. The contract sublanguage

### 4.1 Surface syntax

Contract expressions use the ordinary expression grammar
(`docs/grammar.ebnf` §7) with the following additions admitted *only*
in contract position:

- `old(e)` — see §5
- `result` — see §5
- `forall (x: T [, y: U …]) [where φ] implies ψ`
- `forall (x: T [, y: U …]) [where φ] { ψ }`  (block form)
- `exists (x: T [, y: U …]) [where φ] { ψ }`
- `a implies b` — binary connective; equivalent to `not a or b`

### 4.2 Permitted operators and references

Within a contract expression, the following are admissible:

1. Literals (any `Literal` per grammar §7.1.1)
2. Parameter references (the function's `in`/`out`/`inout` parameters)
3. Local-variable references introduced by `let`/`val` *in scope* of
   the contract clause — that is, only `requires:` may refer to
   parameters; `ensures:` may also refer to `result` and to `old(_)`
   forms. Body-local bindings are not in scope of any contract clause.
4. Field projection `e.f` where `e` has a record, opaque (within its
   own package), or exposed-record type.
5. Function calls `g(args…)` where `g` is **`@pure`** — see §4.3.
6. Construction of records, unions, tuples, slices, and lists, where
   the constructed values are immediately consumed by the contract
   expression (no aliasing or escape).
7. The standard arithmetic, comparison, logical, range, and indexing
   operators; the nil-coalescing `??`; the postfix `?` is **not**
   admissible (no early return inside a contract).
8. Pattern matching (`match`) with the same exhaustiveness rules as
   ordinary expressions.
9. The contract-only forms `old`, `result`, `forall`, `exists`,
   `implies`.

### 4.3 The `@pure` annotation

A function `g` may be annotated `@pure`. The annotation is admissible
only if `g` syntactically satisfies the contract sublanguage in its
body:

- `g`'s parameters are all `in`-mode.
- `g`'s body uses only operators and calls drawn from §4.2 above.
- `g` does not allocate observable state (record/union/slice
  construction is permitted; the result must not escape via `out`/
  `inout`/global state).
- `g` does not call any `async` function, any `entry`, or any
  function that is not itself `@pure`.
- `g` does not appear inside an `unsafe { … }` block.

`@pure` is part of `g`'s contract metadata: it is exported in the
`<package>.lyric-contract` artifact (§3.3 of the language reference).
Removing `@pure` from a previously-pure function is a SemVer-breaking
change (callers' contracts may have called it).

Built-in primitives admit a fixed `@pure` set: arithmetic, comparison,
logical operators, `slice` length, and the constructors of records,
unions, and tuples are all `@pure`. I/O, mutation, allocation that
escapes, and `entry` calls are not.

### 4.4 The contract validator

After parsing, the compiler runs a *contract validator* over each
contract expression that rejects, with a precise diagnostic:

- references to body-local bindings,
- calls to non-`@pure` functions,
- mutations or `inout` writes,
- `?` (error propagation),
- `await`,
- `spawn`,
- `try` blocks,
- side-effecting operators (`+=`, `-=`, …),
- `result` outside `ensures:`,
- `old(_)` outside `ensures:`.

The validator runs *before* the proof obligation generator (§10) and
before the runtime asserter (§9): both layers downstream may assume
they are operating on a syntactically pure expression.


## 5. `old` and `result`

### 5.1 The `result` slot

`result` is bound exactly once per call: immediately before
`Post_f` is evaluated. Its value is the function's return value (the
operand of the `return` statement that produced control flow back
to the caller, or `()` for `Unit`-returning functions).

Formal rule (Big-step, evaluation of `Post_f` after the body):

```
        ⟨body, σ_pre⟩ ⇓ ⟨v_ret, σ_body⟩
        σ_post = σ_body[F.result := v_ret]
        ⟨Post_f, σ_post⟩ ⇓ true
        ─────────────────────────────────────
        ⟨call f(args), σ_caller⟩ ⇓ v_ret
```

with the corresponding failure rule when `⟨Post_f, σ_post⟩ ⇓ false`
or when evaluation of `Post_f` itself produces a `Bug`:

```
        ⟨Post_f, σ_post⟩ ⇓ false
        ───────────────────────────────────────────────────
        ⟨call f(args), σ_caller⟩ ⇓ Bug(PostconditionViolated, "f")
```

A function with `Unit` return type still has `result` in its
`ensures:` scope; its value is the unique `()` and any reference
to it is degenerate but not an error.

### 5.2 The `old` slot

`old(e)` evaluates `e` against the *pre-state* `σ_pre` taken *after*
`Pre_f` succeeded and before any statement of the body executed.

Formal rule for evaluating an `ensures:` clause that contains `old`:

```
        ⟨Pre_f, σ_caller⟩ ⇓ true
        σ_pre = enter_frame(σ_caller, args)        (cf. §6.1)
        F.old = snapshot(σ_pre, free_old(Post_f))  (cf. below)
        ⟨body, σ_pre⟩ ⇓ ⟨v_ret, σ_body⟩
        σ_post = σ_body[F.result := v_ret][F.old := F.old]
        ⟨Post_f, σ_post⟩ ⇓ true
        ───────────────────────────────────────────────────
        ⟨call f(args), σ_caller⟩ ⇓ v_ret
```

`free_old(Post_f)` is the syntactic set of expressions appearing as
operands of `old` in `Post_f`. The snapshot is *as deep as the contract
reads*:

> snapshot(σ, S) =  { e ↦ value of e in σ | e ∈ S }

For each `old(e)` in `Post_f`, the snapshot stores the *value* of `e`
in `σ_pre`. Since contract expressions are pure (§4), this value is
well-defined regardless of subsequent mutation; in particular:

- For a primitive-typed `e`, the stored value is the primitive itself
  (no aliasing concern).
- For a record-typed `e`, the stored value is the record (records are
  values, not references — see `09-msil-emission.md` §5).
- For a slice or array `e`, the stored value is a *snapshot* of the
  elements visible at `σ_pre`. The implementation may either copy
  eagerly or use a copy-on-write strategy; the observable semantics is
  the same.
- For a reference-typed `e` (a value behind an `inout`), the stored
  value is the *dereferenced* value at `σ_pre`. `old` never preserves
  identity, only contents.

`old(e)` is malformed when `e` reads a value not in scope at function
entry (e.g. a body-local binding); the contract validator (§4.4)
rejects this statically.


## 6. Evaluation rules for contract clauses

### 6.1 Function-call semantics with contracts

Let `f` be a function whose verification level is `runtime_checked`
(the proof-required case is treated in §10). The big-step rule for a
call to `f(v₁, …, vₙ)` from a caller with store `σ_caller` is:

```
        E_callee = bind(params(f), v₁…vₙ)
        σ_entry  = ⟨E_callee :: E(σ_caller), H(σ_caller)⟩

        (* parameter-side invariant checks *)
        ∀ i. typeof(params(f)[i]) = T  ⇒  ⟨Inv_T, σ_entry, vᵢ⟩ ⇓ true

        (* precondition *)
        ⟨Pre_f, σ_entry⟩ ⇓ true

        (* snapshot for old *)
        F.old = snapshot(σ_entry, free_old(Post_f))

        (* body *)
        ⟨body_f, σ_entry⟩ ⇓ ⟨v_ret, σ_exit⟩

        (* return-side invariant check *)
        typeof(return f) = U  ⇒  ⟨Inv_U, σ_exit, v_ret⟩ ⇓ true

        (* postcondition *)
        σ_post = σ_exit[F.result := v_ret][F.old := F.old]
        ⟨Post_f, σ_post⟩ ⇓ true
        ─────────────────────────────────────────────────────────
        ⟨call f(v₁…vₙ), σ_caller⟩ ⇓ ⟨v_ret, restore(σ_caller, σ_exit)⟩
```

`bind` and `restore` are the standard activation-frame conventions:
`bind` builds a fresh environment with the parameters mapped to their
argument values; `restore` discards the callee's frame and propagates
any `inout`-mode parameter writebacks to the caller's environment.

If any premise fails, the conclusion is the corresponding `Bug`:

| Failing premise                               | Bug tag                  |
|-----------------------------------------------|--------------------------|
| parameter-side invariant                      | `InvariantViolated`      |
| `Pre_f`                                       | `PreconditionViolated`   |
| return-side invariant                         | `InvariantViolated`      |
| `Post_f`                                      | `PostconditionViolated`  |
| body produces `Bug(t, m)`                     | `t`/`m` (propagated)     |

The order of premises corresponds to the order in which the runtime
performs the checks. In particular: a precondition violation is
reported before any work is done, and an invariant violation on a
parameter is reported before the precondition (the precondition may
itself read fields of that parameter and would otherwise fail
spuriously).

### 6.2 Multiple `requires:` / `ensures:` clauses

The reference (§6.1) allows multiple clauses for clarity:

```
func transfer(...): Result
  requires: amount > 0
  requires: from != to
  ensures: result.isOk implies fromBalance.decreased
```

Multiple clauses are conjoined in source order. The runtime reports
the *first* violating clause, identified by source location, in the
`Bug`'s message. The proof obligation (§10) is the conjunction; the
solver needs no order awareness.

### 6.3 Quantifiers — runtime semantics

For runtime-checked code, quantifiers are evaluated by *iteration*:

- `forall (x: T) where φ implies ψ` — for every `x` enumerable in `T`
  (or, for slice/set quantifiers, every element of the collection)
  satisfying `φ`, check `ψ`. Short-circuits on the first violation.
- `exists (x: T) where φ ψ` — analogous, with short-circuit on the
  first satisfying witness.

The runtime semantics requires the domain `T` to be *finitely
enumerable*: it is one of

- a slice, set, list, or other `std.collections.Iterable`,
- an enum or finite-cardinality range subtype,
- a finite tuple of the above.

A quantifier whose domain is not finitely enumerable (e.g. `forall
(x: Int)`) is a *static error* in `@runtime_checked` mode; it is only
admissible inside `@proof_required` modules, where the SMT solver
discharges it without enumeration.

### 6.4 `implies`

`a implies b` is fully equivalent to `not a or b` and inherits its
semantics — including short-circuiting on `not a`. The grammar
(§9 ContractClause) admits `implies` only inside contract sub-language
positions; outside, `implies` is a soft keyword and resolves to a
plain identifier.


## 7. Invariants

### 7.1 Where invariants are checked

For a type `T` whose declaration carries `invariant: φ_T`, the
following are *invariant-check points*:

1. **Construction.** Every code path that produces a fresh value of
   type `T` must, before that value escapes the constructor, satisfy
   `Inv_T(value)`. For records and exposed records, the implicit
   constructor inserts the check at its return. For opaque types, the
   constructor is always a function inside the type's package; the
   check is inserted at every `return` of that constructor.
2. **Public boundary, return.** When a value of type `T` is returned
   from a `pub` function whose declaring package is *not* `T`'s
   package, `Inv_T` is checked on the return value before control
   passes to the caller.
3. **Public boundary, parameter.** When a value of type `T` is passed
   as a parameter to a `pub` function whose declaring package is not
   `T`'s package, `Inv_T` is checked on the argument *before* `Pre_f`
   is evaluated.
4. **Protected entry, return.** When an `entry` of a protected type
   `P` returns to its caller, `Inv_P` is checked on the post-state.
   See §8.3 for the rollback rules on failure.
5. **Mutation through `inout`.** When an `inout` parameter of type `T`
   is written by the callee, `Inv_T` is checked on the new value
   before the writeback to the caller.

### 7.2 Where invariants are *not* checked

By design, invariants are not checked:

- inside the declaring package on intra-package calls (a designated
  internal helper may temporarily violate the invariant; the public
  boundary re-establishes it),
- on a `pub` *field read* — only on whole-value crossings,
- inside a contract expression (contract evaluation is pure),
- between intermediate steps of a record's `copy(…)` non-destructive
  update (the intermediate value need not satisfy `Inv_T`; the result
  of `copy` is checked on its first crossing).

This is a deliberate weakening of "invariants always hold." The cost
of checking on every assignment is too high; the design intent is
that public-boundary checking is sufficient, supported by the
restriction that mutation only happens through `inout`, `var`, or
inside a `protected type`.

### 7.3 Formal rule for return-side invariant

```
        ⟨body, σ_entry⟩ ⇓ ⟨v_ret, σ_exit⟩
        typeof(return f) = T   declaring_pkg(f) ≠ declaring_pkg(T)
        ⟨φ_T[self := v_ret], σ_exit⟩ ⇓ true
        ─────────────────────────────────────────────
        invariant ok at return; continue with §6.1's Post_f rule
```

When the body returns `Bug(t, m)`, the invariant is *not* checked;
the `Bug` propagates immediately. Invariant violation has its own
tag, `InvariantViolated(typename, location)`.

### 7.4 Construction obligation

Every constructor of `T` (whether implicit or a user-written `func
make(...): T` inside `T`'s package) carries an implicit additional
postcondition

> `Inv_T(result)`

which is conjoined with whatever explicit `ensures:` the constructor
declares. This is *not* a separate runtime check on top of §7.1: it
is the same check, identified at the constructor's return site.

For projectable opaque types (§2.9 of the language reference),
`tryInto` constructors evaluate `Inv_T` on the candidate value and
return `Err(ContractViolation(...))` on failure rather than a `Bug`.
The corresponding `Bug` is replaced by a `Result.Err` value because
the violation is *recoverable* — the input was external data.


## 8. Protected entries and `when:` barriers

### 8.1 The protected-type state model

A protected type `P` with field set `F` is realised as a *cell* on
the heap holding the current values of `F` plus a *queue* of pending
callers and an exclusive lock. The semantics treats this cell as a
single value; no two evaluations may inspect or mutate it
concurrently (lowering details are in `09-msil-emission.md` §17).

We write `σ@P_ℓ` for the substore that contains `P`'s cell at heap
address `ℓ`. The notations `read(σ@P_ℓ)` and `write(σ@P_ℓ, v)` denote
the atomic read and write of the cell.

### 8.2 Entry call

For a protected entry `e` declared on `P` with parameters `params`,
`requires:` clauses `Pre_e`, optional `when: Barrier_e`, and body
`body_e`, a call from a caller with store `σ_caller` proceeds as
follows.

```
        v_state = read(σ@P_ℓ)
        ⟨Inv_P, σ_caller, v_state⟩ ⇓ true                    (* admission invariant *)
        ⟨Pre_e[self := v_state, params := args], σ_caller⟩ ⇓ true
        ⟨Barrier_e[self := v_state, params := args], σ_caller⟩ ⇓ true
        E_callee = bind(params(e), args)
        σ_entry = ⟨E_callee :: E(σ_caller), σ_caller.H⟩
        F.old = snapshot(σ_entry, free_old(Post_e))
        ⟨body_e, σ_entry⟩ ⇓ ⟨v_ret, σ_exit⟩
        v_state' = read(σ_exit@P_ℓ)
        ⟨Inv_P, σ_exit, v_state'⟩ ⇓ true                      (* discharge invariant *)
        ⟨Post_e[result := v_ret, old := F.old], σ_exit⟩ ⇓ true
        notify_barriers(σ_exit@P_ℓ)
        ─────────────────────────────────────────────────────
        ⟨call e(args) on P_ℓ, σ_caller⟩ ⇓ v_ret
```

Where `notify_barriers` re-evaluates the `when:` clauses of every
queued caller and admits any whose barrier now holds.

### 8.3 Failure of an entry

If the body raises a `Bug`, the runtime *aborts* the entry's effect:

```
        v_state = read(σ@P_ℓ)
        ⟨body_e, σ_entry⟩ ⇓ Bug(t, m)
        v_state'' = v_state                  (* discard intermediate writes *)
        write(σ@P_ℓ, v_state'')
        ⟨Inv_P, σ, v_state''⟩ ⇓ true         (* must re-hold; was true on entry *)
        ─────────────────────────────────────────────────────
        ⟨call e(args) on P_ℓ, σ_caller⟩ ⇓ Bug(t, m)
```

The premise `⟨Inv_P, σ, v_state''⟩ ⇓ true` is automatic when the
runtime discards intermediate writes (the pre-entry state already
satisfied the invariant). If for some reason the implementation
could not roll back (an FFI side effect crossed an axiom boundary
mid-entry, for example), and `Inv_P` then fails on `v_state''`, the
program *terminates* — invariant violation in a protected type is
unrecoverable per the language reference §8.2.

### 8.4 Barrier semantics

`Barrier_e` is a precondition that, *unlike* `Pre_e`, causes the
caller to *block* (not raise a `Bug`) when it does not hold. The
caller is enqueued; when the next `notify_barriers` event finds the
barrier true, the caller is dequeued and admitted.

A barrier expression may *not* fail with a `Bug`: any `Bug` in
barrier evaluation aborts the *whole protected type* into an
unrecoverable state, because the runtime cannot decide whether to
admit the caller. The contract validator (§4.4) imposes additional
restrictions on barrier expressions: no allocation, no exception-
producing operations (e.g. integer division), only field reads and
arithmetic on guaranteed-finite domains.


## 9. Runtime-checked semantics — summary

For `level(P) = runtime_checked`:

- All contract clauses are *evaluated* at the program points defined
  in §6, §7, and §8.
- Failure produces `Bug` per the tags table (§6.1).
- The compiler may *omit* a check when it can statically prove the
  obligation under the constraints of `@runtime_checked`'s lightweight
  reasoner (e.g. range subtypes whose construction is in the same
  expression; bounds checks on indices whose type already guarantees
  validity per language reference §2.7). The proof system (§10) is
  *not* available in this mode.
- In `--release` builds, the compiler may *also* elide checks
  classified as defensive — preconditions on private helpers,
  invariants on intermediate values — per a setting in `lyric.toml`.
  Public-boundary checks are never elidable in any mode.


## 10. Proof-required semantics

For `level(P) = proof_required`, contracts are not evaluated at run
time; instead they generate **verification conditions** — Boolean
formulae in a typed first-order logic — that an SMT solver discharges
at compile time. If any VC is not discharged, compilation fails.

This section defines the VC generation. The dual viewpoint with the
runtime semantics is summarised in Theorem 1 (§13.1).

### 10.1 The VC generator

The VC generator is a function

> VCGen(f) : { φ₁, …, φₙ }

that, given a function `f` declared in a `@proof_required` package,
produces a finite set of formulae. Compilation of `f` succeeds iff
every `φᵢ` is valid in the proof context Γ_f assembled from:

- the contracts of `f`'s callees (§10.4),
- axioms imported across `@axiom` boundaries (§12),
- the type theory of Lyric's primitive types (integers, IEEE 754
  floats, finite Booleans, algebraic datatypes, finite collections —
  all standard SMT-LIB theories),
- assumptions introduced by the language design itself (e.g. that
  every value of type `Nat range 1 ..= 100` is in the closed interval
  [1, 100]).

### 10.2 VC generation rules

Let `f` have parameters `p₁: T₁, …, pₙ: Tₙ`, return type `U`,
preconditions `Pre_f`, postconditions `Post_f`, and body `body_f`.
The generator computes a *weakest precondition* over the body:

> wp(body_f, Q)

by induction on the body's syntax. The generated VCs are:

```
  φ_pre  ≡  ∀ p₁: T₁, …, pₙ: Tₙ.
              Inv(p₁) ∧ … ∧ Inv(pₙ) ∧ Pre_f
            ⇒  wp(body_f, λ result. Post_f ∧ Inv(result))
```

That is: for every input satisfying the parameter invariants and the
precondition, the body must establish the postcondition and the
return-type invariant. This is the standard Floyd–Hoare derivation.

Inductively, `wp` is defined as:

| Body form                  | wp definition |
|----------------------------|---------------|
| `return e`                 | `Q[result := ⟦e⟧]` |
| `val x = e ; S`            | `wp(S, Q)[x := ⟦e⟧]` |
| `var x = e ; S`            | `wp(S, Q)[x := ⟦e⟧]` (each subsequent `x = e'` yields a fresh substitution) |
| `if c { S₁ } else { S₂ }`  | `(⟦c⟧ ⇒ wp(S₁, Q)) ∧ (¬⟦c⟧ ⇒ wp(S₂, Q))` |
| `match e { case Pᵢ -> Sᵢ }`| `⋀ᵢ (matches(⟦e⟧, Pᵢ) ⇒ wp(Sᵢ, Q[bindings(Pᵢ, ⟦e⟧)]))` |
| `while c invariant: ι { S }` | `ι ∧ ∀ state. ι ∧ ⟦c⟧ ⇒ wp(S, ι) ∧ ∀ state. ι ∧ ¬⟦c⟧ ⇒ Q` |
| `for x in xs invariant: ι { S }` | sugar; expands to a `while` over the iterator state |
| `g(args) ; S`              | call rule, §10.4 |
| `S₁ ; S₂`                  | `wp(S₁, wp(S₂, Q))` |

Loops *must* declare an `invariant:` clause in `@proof_required`
mode; the grammar admits `invariant:` on `while` and `for` even
though it is not common in the worked examples. Without an explicit
invariant, the VC generator reports a missing-loop-invariant error.

### 10.3 Quantifiers in VCs

`forall` and `exists` are translated directly to the corresponding
SMT-LIB quantifiers:

- `forall (x: T) where φ implies ψ` ↦ `∀ x: ⟦T⟧. ⟦φ⟧ ⇒ ⟦ψ⟧`
- `exists (x: T) where φ ψ`         ↦ `∃ x: ⟦T⟧. ⟦φ⟧ ∧ ⟦ψ⟧`

Where `⟦T⟧` is the SMT-LIB sort corresponding to the Lyric type
(`Int`, `Bool`, `Real`, an inductive datatype, or an
uninterpreted sort; see §13).

The decidable fragment (§11) restricts which contracts may use
quantifiers and over which sorts.

### 10.4 Calls and the contract trust principle

For a call `g(args)` from `f` with continuation `S`:

> wp(g(args) ; S, Q) ≡
>     Pre_g[params := ⟦args⟧]
>   ∧ ∀ result.
>         (Post_g[params := ⟦args⟧, result := result, old := ⟦args⟧])
>      ⇒ wp(S, Q)[«side-effect of g» := result]

That is: at the call site we *check* `g`'s precondition and *assume*
its postcondition. The body of `g` is *not* re-analysed at the call
site; its proof obligations were discharged when `g` itself was
verified. This is the Hoare-logic principle of *contract trust*, and
it is the reason `@proof_required` callees must themselves be
`@proof_required` or `@axiom`.

### 10.5 Construction obligations

For any expression `e` of a refined or invariant-bearing type `T`,
the VC generator emits an additional obligation `Inv_T(⟦e⟧)`. For
range subtypes, this is the obvious arithmetic constraint. For
opaque types with `invariant: φ`, it is `φ[self := ⟦e⟧]`.

### 10.6 Branches that lead to `Bug`

In the wp calculus, a path that would produce a `Bug` is treated as a
postcondition-violation and so generates a VC of the form `false ⇒ Q`
on that branch — equivalently, the VC requires the path to be
*unreachable*. The runtime semantics observed for the same path is
"`Bug` propagates", which the proof semantics rules out at compile time.


## 11. The decidable fragment

The SMT solver Lyric ships with (Z3 per Q020) is decidable (or
practically efficient) on the following sub-theories:

| Sort                     | Theory used               | Decidable?    |
|--------------------------|---------------------------|---------------|
| `Bool`                   | propositional             | yes           |
| `Int`, `Long`, `Nat`     | linear integer arithmetic | yes           |
| range subtypes           | bounded LIA               | yes           |
| `UInt`, `ULong`, `Byte`  | bitvector arithmetic      | yes           |
| `Float`, `Double`        | floating-point (IEEE 754) | yes (slow)    |
| inductive datatypes (records, unions, enums, slices of finite length) | SMT-LIB datatypes | yes if quantifier-free |
| user-defined functions   | EUF + congruence          | only when `@pure` and structurally recursive over a measure |

A contract whose VCs all live in this fragment is **decidable**: the
solver returns `sat` or `unsat` deterministically (modulo a configurable
time budget). Outside the fragment, the solver may return `unknown`;
the verifier reports such cases as *unverified obligations* with their
full SMT context attached, so the user can inspect or refactor.

Practical guidance, captured here for the Phase 1 implementer:

- Keep `@proof_required` modules small and arithmetic-heavy.
- Avoid quantifiers over collections without explicit length bounds.
- Avoid string-typed contracts beyond equality and length.
- Avoid `Float`/`Double` in postconditions whenever possible; the
  IEEE 754 theory is decidable but quickly hits time limits.

A `--prove-with-counterexample` flag (Phase 4) reports a counterexample
for `unsat` queries that *should* have been `sat`; this is the model
SPARK uses and is the standard for verification UX.


## 12. `@axiom` boundaries

An `@axiom` declaration is an *assumption* — its contract is not
discharged by the verifier; it is added to Γ as if proved.

> ⊢_axiom { p₁: T₁, …, pₙ: Tₙ | Pre_f } f(p₁…pₙ): U { result | Post_f }

The VC generator treats the call rule (§10.4) for an `@axiom` callee
identically to a normal callee — it checks `Pre_f` at the call site and
assumes `Post_f` on return. The difference is only that no VCs are
*generated* for the body of an `@axiom` function: there is no body to
analyse.

Soundness in the presence of axioms is *as good as the axioms.* A
wrong axiom produces a wrong proof; the language reference (§6.5)
discusses the social mechanisms (visible code review, listed in the
contract metadata) used to keep the axiom set small and trustworthy.

`unsafe { … }` blocks inside `@proof_required(unsafe_blocks_allowed)`
modules are treated equivalently: the block's effects are opaque to
the prover, and the surrounding proof must rely on whatever
postconditions the user *asserts* (with `assert φ`) at the unsafe
block's exit.


## 13. Soundness, completeness, and worked examples

### 13.1 Theorem 1 (Soundness of proof relative to runtime)

> *For any `@proof_required` package P that successfully verifies,
> every execution of any function in P under the runtime semantics
> (§6–§9) produces no `Bug` of tag `PreconditionViolated`,
> `PostconditionViolated`, or `InvariantViolated` originating in P.*

Sketch: the VC generation rules in §10 derive `wp(body, Post)` from
the body's syntax under the assumption that called contracts hold;
each VC reduces to "the program does not reach a state where the
runtime semantics would raise `Bug`." Z3's decision over the
decidable fragment (§11) yields `unsat` exactly when no such state
is reachable. Outside the fragment, the verifier requires user
discharge or `assert`-based axioms; in both cases, soundness is
relative to the axioms admitted.

We are not claiming completeness — there are programs free of `Bug`s
that the verifier cannot prove. The expected user response is
narrowing the proof obligation, refactoring, or shifting the function
to `@runtime_checked`.

### 13.2 Worked example — `Money.make`

From `docs/02-worked-examples.md`:

```
pub func make(c: in Cents): Result[Amount, ContractViolation]
  ensures: result.isOk implies result.value.value == c
{
  return if c > 0 then Ok(Amount(value = c))
                  else Err(ContractViolation("amount must be positive"))
}
```

`Cents` is a range subtype: `Long range 0 ..= 1_000_000_000_00`.
`Amount`'s `invariant: value > 0`.

Runtime semantics. On entry: parameter-side invariant on `c` checks
`0 <= c <= 1_000_000_000_00` (succeeds, by construction of `c` as a
`Cents`). No `Pre_f`. Body produces `Ok(Amount(value = c))` or
`Err(...)`. Return-side invariant: `Result[Amount, ContractViolation]`
has no top-level invariant; on the `Ok` branch, the construction of
`Amount(value = c)` *does* trigger `Inv_Amount`: `c > 0`. This is
satisfied because the body only constructs `Amount` on the `c > 0`
branch.

If a caller passes `c = 0`, the function reaches the `Err` branch
and never constructs an `Amount`; no `Bug` is raised; the caller
receives `Err(...)`.

Proof semantics. The VC generated for `make` is:

> ∀ c: Long. (0 ≤ c ≤ 1_000_000_000_00) ⇒
>     (c > 0 ⇒ (∃ a: Amount. a.value = c ∧ a.value > 0)) ∧
>     (¬(c > 0) ⇒ true)

The first conjunct discharges trivially: pick `a := Amount(c)`; the
invariant `c > 0` is the antecedent of the implication.

### 13.3 Worked example — `Transfer.execute`

The conservation property in `docs/02-worked-examples.md` is:

```
ensures: result.isOk implies {
  val (newFrom, newTo) = result.value
  newFrom.balance + newTo.balance == from.balance + to.balance and
  newFrom.balance == from.balance - amountValue(amount) and
  newTo.balance == to.balance + amountValue(amount)
}
```

The proof relies on `debit` and `credit`'s postconditions:

> debit(a, m).isOk ⇒ result.value.balance = a.balance - amountValue(m)
> credit(a, m).isOk ⇒ result.value.balance = a.balance + amountValue(m)

By the call rule (§10.4), the VCGen for `execute` *assumes* these
postconditions at the call sites; the conservation conjuncts then
follow by linear arithmetic. Z3 discharges the resulting VC in
milliseconds; this is the canonical example of "small-arithmetic-domain"
verification working as intended.


## 14. References

- C. A. R. Hoare, *An Axiomatic Basis for Computer Programming*, CACM
  1969 — the source of `{P} S {Q}` notation.
- Bertrand Meyer, *Object-Oriented Software Construction*, 2nd ed. —
  the source of `requires`/`ensures` terminology.
- Tucker Taft et al., *Ada 2012 Rationale*, Chapter on Pre/Post
  conditions and type invariants — closest precedent for our boundary
  rules.
- *SPARK 2014 Reference Manual* — proof model for module-level opt-in
  and axiom boundaries.
- K. Rustan M. Leino, *Dafny: An Automatic Program Verifier for
  Functional Correctness*, LPAR-16, 2010 — the wp/VC machinery used in
  §10 follows Dafny closely.
- L. de Moura, N. Bjørner, *Z3: An Efficient SMT Solver*, TACAS 2008.
- *Lyric Decision Log* (`docs/03-decision-log.md`), entries D013, D024.
- *Lyric Open Questions* (`docs/06-open-questions.md`), entries Q020
  (solver choice), Q014 (operator overloading and `@pure`).

---

## Appendix A. Quick-reference table of `Bug` tags

| Tag                       | Raised at                               | Catchable? |
|---------------------------|-----------------------------------------|------------|
| `PreconditionViolated`    | start of body, after parameter invariants | yes (smell) |
| `PostconditionViolated`   | return, after return-invariant            | yes (smell) |
| `InvariantViolated`       | parameter / return / construction         | yes (smell) |
| `BarrierViolated`         | protected entry barrier evaluation raised a Bug | no (terminates) |
| `ProtectedInvariantUnrecoverable` | post-rollback `Inv_P` still false | no (terminates) |
| `ArrayBoundsViolated`     | array/slice indexing                      | yes (smell) |
| `IntegerOverflow`         | range subtype operation                   | yes (smell) |
| `UnwrapOnError`           | `.unwrap()` on `Err`/`None`               | yes (smell) |

"Catchable but a smell" means the language permits `try ... catch Bug
as b { ... }` to handle the `Bug`, but the compiler emits a warning
on such handlers in normal application code (see language reference
§8.2).
