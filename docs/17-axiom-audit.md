# 17 — Axiom Audit

Every `@axiom`-annotated declaration in the Lyric standard library
and bootstrap runtime shims (`std.bcl.*`).  This document is the
authoritative list.  Each entry records:

- **What** the axiom claims (the contract it asserts without proof).
- **Why** it cannot be proved inside Lyric (the BCL gap, performance
  concern, or decidability limit).
- **What callers must uphold** — the invariants a calling package
  must establish before it can rely on the axiom's postcondition
  soundly.
- **Review status** — whether the axiom has been independently
  reviewed and is considered stable.

The proof system uses every `@axiom` declaration as a *trusted fact*;
there is no proof obligation generated for its body.  This makes
axioms the only source of unverified assumptions in a
`@proof_required` call graph.  Per
`docs/15-phase-4-proof-plan.md` §3.2:

> The axiom whitelist is the entire trust boundary between Lyric
> and the host runtime.  Every axiom must have a rationale, a reviewer,
> and a scope limit.

---

## 1. How to read this document

Each entry is formatted:

```
### std.bcl.<Module>.<functionOrType>

@axiom("<claim>")
pub func …
  requires: …
  ensures: …

**Gap**: Why this cannot be proved in Lyric.
**Caller obligation**: What the caller must ensure.
**Review**: Stable / Under review / Provisional.
```

---

## 2. `std.bcl.Console`

### `std.bcl.Console.writeLine`

```
@axiom("System.Console.WriteLine is total and has no observable return value")
pub func writeLine(s: in String): Unit
```

**Gap**: The BCL `Console.WriteLine` call is I/O; it has observable
side-effects that cannot be modelled in first-order logic without an
explicit I/O monad (out of scope for M4.x).

**Caller obligation**: None.  The postcondition is vacuous (Unit);
the axiom merely stops the prover from treating the call as unknown.

**Review**: Stable.

---

## 3. `std.bcl.String`

### `std.bcl.String.length`

```
@axiom("String.Length is non-negative and equals the UTF-16 code-unit count")
pub func length(s: in String): Int
  ensures: result >= 0
```

**Gap**: The internal representation of .NET strings is opaque to
the Lyric prover; the BCL specification guarantees non-negativity.

**Caller obligation**: None.

**Review**: Stable.

### `std.bcl.String.concat`

```
@axiom("String concatenation is associative and length-additive")
pub func concat(a: in String, b: in String): String
  ensures: result.length == a.length + b.length
```

**Gap**: String internal layout is BCL-opaque.  The length-additivity
claim holds for all UTF-16 strings by definition of the BCL.

**Caller obligation**: The caller must ensure
`a.length + b.length <= Int.max` to avoid overflow — enforced by
V0008 when `@proof_required(checked_arithmetic)` is set on the
caller.

**Review**: Stable.

### `std.bcl.String.contains`

```
@axiom("String.Contains returns true iff the substring appears in the receiver")
pub func contains(s: in String, sub: in String): Bool
  ensures: result implies s.length >= sub.length
```

**Gap**: Full substring semantics require quantifier reasoning over
character sequences, which is outside the decidable fragment for
arbitrary-length strings.

**Caller obligation**: None — the postcondition is deliberately weak
(it only captures the necessary length condition, not the full
semantic definition).  Callers that need the full semantic guarantee
must use an `@axiom` contract at their own call site.

**Review**: Stable.

---

## 4. `std.bcl.Int`

### `std.bcl.Int.parse`

```
@axiom("Int.parse is total: it either succeeds with a value in [Int.min, Int.max] or fails")
pub func parse(s: in String): Result[Int, ParseError]
  ensures: result.isOk implies result.value >= Int.min and result.value <= Int.max
```

**Gap**: Parsing logic involves character-level iteration that is not
in the decidable fragment.  The range postcondition is trivially true
by type but is recorded explicitly so the prover can use it.

**Caller obligation**: None.

**Review**: Stable.

---

## 5. `std.bcl.Math`

### `std.bcl.Math.abs`

```
@axiom("Math.Abs returns the absolute value; result is non-negative")
pub func abs(x: in Int): Int
  requires: x > Int.min
  ensures: result >= 0
  ensures: result == x or result == (0 - x)
```

**Gap**: The CLR implementation is a branch or CMOV instruction;
the postcondition is definitionally true but the prover does not
have a built-in `abs` operator.

**Caller obligation**: The caller must ensure `x > Int.min`.
`abs(Int.min)` overflows in two's-complement arithmetic and the BCL
behaviour is undefined (returns `Int.min` on .NET but this is
a known BCL quirk).  V0003 fires if this `requires:` is not
established in proof-required code.

**Review**: Stable.  The `requires: x > Int.min` guard is the
deliberately conservative choice — tighter than the actual BCL
behaviour, but correct.

### `std.bcl.Math.min` and `std.bcl.Math.max`

```
@axiom("Math.Min/Max return the smaller/larger of two values")
pub func min(a: in Int, b: in Int): Int
  ensures: result <= a and result <= b
  ensures: result == a or result == b

pub func max(a: in Int, b: in Int): Int
  ensures: result >= a and result >= b
  ensures: result == a or result == b
```

**Gap**: Definition-level; the prover has comparison operators but
no built-in `min`/`max` terms.

**Caller obligation**: None.

**Review**: Stable.

---

## 6. `std.bcl.Array`

### `std.bcl.Array.length`

```
@axiom("Array.Length returns the element count; always non-negative")
pub func length[T](arr: in array[?, T]): Int
  ensures: result >= 0
```

**Gap**: The CLR array object carries its length as an internal
field; the Lyric sort encoding uses a logical `length` function but
does not model the heap.

**Caller obligation**: None.

**Review**: Stable.

### `std.bcl.Array.get`

```
@axiom("Array element access is defined for indices in [0, length-1]")
pub func get[T](arr: in array[?, T], i: in Int): T
  requires: i >= 0 and i < arr.length
```

**Gap**: Memory safety of the access is guaranteed by the CLR
bounds check; the postcondition (the returned value equals the
element) is a heap-modelling statement outside first-order scope.

**Caller obligation**: The caller must prove
`i >= 0 and i < arr.length`.  This is the primary use case for
`@proof_required` range subtypes or explicit contract clauses on
loop induction variables.

**Review**: Stable.  The `requires:` is the most important contract
in the array API — it is what allows bounds-check elimination in
`@proof_required` code compiled with the optimising back-end.

---

## 7. `std.bcl.Guid`

### `std.bcl.Guid.newGuid`

```
@axiom("Guid.NewGuid produces a value that is not equal to Guid.empty")
pub func newGuid(): Guid
  ensures: result != Guid.empty
```

**Gap**: Uniqueness of GUIDs is a probabilistic property; the prover
cannot reason about randomness.  The `!= empty` postcondition is
the weakest useful claim that can be axiomatised without a
randomness model.

**Caller obligation**: If the caller needs identity guarantees
(two calls produce distinct values), that cannot be established
through this axiom alone and must be handled architecturally (e.g.,
storing and comparing in a repository).

**Review**: Provisional.  The V4 UUID collision probability is
negligible in practice but not zero; a stronger model (e.g., an
opaque `UniqueId` type with a factory that tracks used values) is
tracked as a future improvement in `docs/06-open-questions.md`.

---

## 8. How to add a new axiom

1. Write the function or type in the appropriate `std.bcl.*` source
   file.
2. Annotate it `@axiom("<claim>")` where `<claim>` is a one-sentence
   plain-English description of what is being assumed.
3. Add an entry to this document in the appropriate section,
   following the template in §1.
4. Submit the entry for review.  The decision log entry
   (`docs/03-decision-log.md`) records the reviewer's sign-off.
5. The `lyric public-api-diff` tool includes `@axiom` declarations
   in its diff output; removing or weakening an axiom's `ensures:`
   is a semver-breaking change.

---

## 9. Axiom count by module (M4.3 baseline)

| Module            | Axiom count | Stable | Provisional |
|-------------------|-------------|--------|-------------|
| `std.bcl.Console` | 1           | 1      | 0           |
| `std.bcl.String`  | 3           | 3      | 0           |
| `std.bcl.Int`     | 1           | 1      | 0           |
| `std.bcl.Math`    | 3           | 3      | 0           |
| `std.bcl.Array`   | 2           | 2      | 0           |
| `std.bcl.Guid`    | 1           | 0      | 1           |
| **Total**         | **11**      | **10** | **1**       |

The single provisional axiom (`Guid.newGuid`) is tracked in
`docs/06-open-questions.md` for a future resolution.
