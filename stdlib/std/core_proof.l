// std/core_proof.l — proof-required nucleus of the standard library.
//
// Shipped under M4.2 close-out (`docs/15-phase-4-proof-plan.md` §11,
// `docs/12-todo-plan.md` Band D-D1.1).  Bootstrap-grade: contains the
// minimum surface a `@proof_required` user package can lean on without
// V0001-importing a `@runtime_checked` callee.
//
// Every function in this file:
//   * is `@pure` so the caller's wp gets a per-call equality
//     hypothesis `f(args) == body` via the §5.5 unfold rule;
//   * carries a postcondition the trivial syntactic discharger closes
//     so the package self-verifies in environments without an SMT
//     solver on $PATH (M4.2 exit criterion: a no-op edit re-verifies
//     in < 1 s under cache hit, which presupposes baseline discharge).
//
// Aspirational `List[T]` / `Result[T,E]` proofs land later — Phase 4
// follow-up — once the verifier's structural-induction support
// matures past the bootstrap-grade primitives shipped in M4.2 core.

@proof_required
package Std.Core.Proof

// =====================================================================
// Identity witnesses.
//
// Used in proofs that need a per-call equality the verifier can lean
// on (e.g. `let p = identity(x); …` rebinds `p` to a term the call
// rule constrains to `x` via the @pure unfold).
// =====================================================================

@pure
@experimental
pub generic[T] func identity(x: in T): T
  ensures: result == x
  = x

// Two-argument projections.  The contract picks out which argument
// the result equals so callers can name the fact at the proof site.
@pure
@experimental
pub generic[T, U] func pickFirst(a: in T, b: in U): T
  ensures: result == a
  = a

@pure
@experimental
pub generic[T, U] func pickSecond(a: in T, b: in U): U
  ensures: result == b
  = b

// =====================================================================
// Boolean constants.
//
// Useful as proof-time anchors when a contract needs `result == true`
// or `result == false` to close.  The `not` helper is contracted
// against both literals so callers get the tautology in either polarity.
// =====================================================================

@pure
@experimental
pub func trueLit(): Bool
  ensures: result == true
  = true

@pure
@experimental
pub func falseLit(): Bool
  ensures: result == false
  = false

// =====================================================================
// Statement-fragment helpers.
//
// These rebind through a `let` so the @pure unfold makes the equality
// available in the caller's wp without exposing the body.  Equivalent
// to `identity` semantically; distinct for clarity at proof sites.
// =====================================================================

@pure
@experimental
pub generic[T] func tag(x: in T): T
  ensures: result == x
{
  let y = x
  return y
}

// `assertEq(x, x)` is a tautology; consumers use it to thread a
// reflexive hypothesis into the wp without changing the runtime
// shape (M4.1 §5 — `assert φ` becomes both a side-goal *and* an
// assumed hypothesis).
@pure
@experimental
pub generic[T] func assertEq(x: in T): T
  ensures: result == x
{
  assert(x == x)
  return x
}

// =====================================================================
// Composition witnesses.
//
// `apply` lifts a value through a no-op pipeline; `wrappedIdentity`
// exercises the cross-call rule (§10.4) plus the @pure unfold so a
// caller can rely on `wrappedIdentity(x) == x` even though the body
// goes through `identity`.
// =====================================================================

@pure
@experimental
pub generic[T] func wrappedIdentity(x: in T): T
  ensures: result == x
{
  return identity(x)
}
