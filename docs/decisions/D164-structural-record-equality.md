# D164 — `==` on a record with no `var` field compares field by field

**Status:** accepted, implemented

Part of docs/67 phase G1 (#7940); a prerequisite for lowering records by
value on native (docs/67 §4.2).

## Context

D157 says a record with no `var` field is a value, so whether a backend
copies or shares it is unobservable. `==` made it observable. On dotnet and
native, two independently built `Point(x = 1, y = 2)` compared unequal (`==`
was reference identity), and so did two records annotated
`@derive(Equals)`; the JVM compared derived records structurally. `docs/01`
§2.4 described a third rule (structural for a `readonly struct`-backed
record, identity otherwise), and `docs/09` §5.3 a fourth (always
structural). A record lowered to an LLVM struct has no identity at all, so
native by-value records needed one answer.

## Decision

1. **`==` and `!=` on a record with no `var` field, or on a record annotated
   `@derive(Equals)`, compare the two records field by field on every
   backend.** A field that is itself such a record is compared by its
   fields; a field of a non-generic distinct type by its underlying value;
   every other field with its own type's `==`. So a `String` field compares
   text, a union field compares structurally, a mutable record field
   compares identity, and a `Float`/`Double` field follows IEEE rules
   (`NaN` is never equal, `0.0 == -0.0`). Each operand is evaluated once,
   left to right. A record with no fields compares equal.
2. **A record with a `var` field that does not derive `Equals` keeps
   identity.**
3. **T0153:** `==` on a record that compares field by field, where the
   expansion reaches a function-typed field, is an error.
4. **Mechanism.** The type checker records each such operator with the
   member paths of its leaf comparisons (`SymbolTable.recordEqSites`).
   `Lyric.ContractElaborator.lowerRecordEq` runs in the shared pipeline,
   after the distinct-type and record-arithmetic passes. It rewrites each
   site into a block that binds both operands to typed temporaries and
   compares the leaves. No backend changes.
5. **Unions on native.** `docs/01` §2.5 gives unions structural equality
   unconditionally, but `--target native` compared union values by
   pointer, so even two `None`s differed. Native now synthesises one
   equality function per union, which compares the discriminants and then
   each payload field. A union field inside a record compares the same way
   on every target.
6. **Not covered yet:** equality a backend runtime performs on its own
   (`Map`/`Set` keys, `List.contains`, record payloads inside union
   equality) still uses each backend's object equality. Tracked in #8003.

## Consequences

- `docs/01` §2.4 replaces its representation-dependent rule.
- The book's records section and appendix B (T0153) follow.
- Code that used `==` on two value records to ask whether they were the
  same instance now gets field-by-field comparison. Identity is only
  meaningful for mutable records, which keep it.
