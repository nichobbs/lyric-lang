# D270 — Contract and range soundness batch (#7900, #7901, #8145, #8226, #8331, #7410, #7529, #7436)

**Status:** shipped

Several places let a value outside a type's contract through without a
diagnostic or a runtime check.  Each was closed the conservative way, and the
choices the specification left open are recorded here.

## Decisions

1. **A range bound must fit the base type (T0190).**  `Byte range 0 ..= 300`,
   `UInt range -1 ..= 5`, `Int range 0 ..= 2147483648` and a negative `Nat` or
   `ULong` bound are rejected at the bound, for named subtypes and inline
   refinements.  The exclusive end of `lo ..< hi` may be one past the base
   type's maximum, because the largest value is still reachable
   (`Byte range 0 ..< 256`).
2. **Unary minus on a `Nat` is T0147**, like the unsigned types.  `Nat` is
   non-negative by invariant, so `-n` has no value of its own type for any
   non-zero `n`; the alternative (a runtime check) would make the type's
   invariant a property of one operator.
3. **Unsigned-to-signed conversions read the value.**  `UInt.toLong()`,
   `toDouble()` and `toFloat()` zero-extend through `toULong()`, which every
   backend already implements, so no new codegen is needed.  A `ULong` has no
   `Long` or floating-point conversion yet (T0103); `toInt()` keeps truncating
   like `Long.toInt()`.  A checked `ULong`-to-`Long` conversion needs a new
   per-backend panic helper and is left to a follow-up.
4. **A variable with no valid default must be assigned before it is read
   (T0191).**  Rather than inventing a default inside a range (the lower bound,
   say), which would hide a missing assignment, the checker does a
   definite-assignment walk for a `var` declared without an initializer whose
   type is a range excluding zero or any named range subtype.  Ordinary types
   keep their zero default.
5. **Interface method contract clauses are type-checked** in the method's
   parameter scope, `result` bound to the declared return type (T0132 and the
   usual name and type errors).  An implementing method inherits the clauses
   after type checking, so an error is reported once, at the interface.
6. **`@pure` is accepted on an interface method signature.**  A call through
   the interface in a contract clause is then pure.  Because any
   implementation could otherwise have effects, an `impl` method of a `@pure`
   interface method must itself be `@pure` (T0192).  `@pure` stays a trusted
   declaration, as for functions.
7. **A protected `func` re-checks the type invariant on return**, as an `entry`
   does (docs/01 §7.5: "after every entry/func returns").
8. **A config value that does not parse exits 78 with G0003** on dotnet and the
   JVM.  `Bool` is read by hand (`1`/`0`/`true`/`false`, any case) so both
   targets accept the same spellings; a `Float`/`Double` is parsed with
   `NumberStyles.Float`, so `1,5` is a parse error rather than 15.  The message
   does not echo the value.

## Not decided here

The record/opaque `invariant:` public-boundary and `inout` re-checks (#7222),
running the prover from `lyric build` (#7431) and imported-function encoding in
proofs (#7532) remain open; the issues carry the plan.
