# D224 - Operators on a type parameter its `where` clause bounds

**Status:** accepted, implemented (#7996, #8017)

## Context

`where T: Add` constrained callers (T0108 when the argument type does not derive `Add`)
but the generic body could not use the operator the bound promises: `a + b` over a bare
`T` was T0030, `a > b` under `where T: Compare` was T0033, and the docs/01 `sum[T]`
example only type-checked because its operands were erased to the lenient wildcard.
Accepting the operator in the checker alone is unsound. Lyric lowers an operator on a
distinct type (`type Cents = Long derives Add`, #7361) to `T.from(a.value + b.value)` and
a derived operator on a homogeneous numeric record (D155) to a component-wise
constructor, from sites the checker records while it sees the concrete operand type. A
generic body is checked once, over `T`, so it records none, and a specialisation at
`Cents` would compile `a + b` on two wrapper objects.

## Decision

1. **Checker.** An arithmetic operator on a type parameter is valid when the enclosing
   function's `where` clause bounds that parameter by the operator's marker: `+` and `+=`
   by `Add`, `-` by `Sub`, `*` by `Mul`, `/` by `Div`, `%` by `Mod`, and `<`, `<=`, `>`,
   `>=` by `Compare`. Without the bound the operator stays T0030 (T0033 for a
   comparison), and a compound assignment on an unbounded parameter is now T0030 too
   (it was silently accepted).
2. **One parameter.** When either operand is a type parameter bounded by the operator's
   marker, both operands are that one parameter: `a + 1`, `1 + a` and `a + b` over two
   different parameters are T0031 (T0033 for a comparison). The result is the parameter,
   `Bool` for a comparison. A specialisation binds one type, so a mixed operand has no
   meaning at a distinct type or a record.
3. **Lowering by re-check, not by recording the generic site.** Each specialisation that
   binds an operator-bounded parameter to a type that is not a scalar primitive is
   type-checked again as the non-generic function it is (the mechanism of #7842 and
   D172), and the distinct-type, distinct compound-assignment and record-arithmetic sites
   that check records on the specialised body are lowered on that function alone, by the
   same rewrites as for hand-written code. This keeps one source of truth for what an
   operator means at a type (the checker's operand-type analysis) and re-uses the
   per-specialisation site plumbing the array and equality sites already use, rather than
   encoding the operator and the type variable in the generic site and re-deriving the
   operand analysis in `Lyric.Mono`. A scalar primitive needs no rewrite: the operator is
   the primitive's own, and `UInt`/`ULong` are already re-checked (#7842).
4. **Cross-package.** A generic declared in another package is checked in that package's
   scope, where a distinct or record type declared by the caller is not visible, so its
   operator cannot be lowered for that type. Such a specialisation is **M0008**, a hard
   error, rather than a silent miscompile. Calling the generic from the declaring package,
   or at a scalar primitive, is unaffected. Lifting the restriction needs the re-check to
   run in a scope that sees both packages' names; tracked in #8530.
5. **Restored generics carry their marker bounds.** The contract metadata repr of a
   generic function now ends with its `where` bounds that name a built-in marker
   (`Add`, `Compare`, `Plain`, ...), so a consumer of a restored package sees the bound
   (T0108 at the call, and the specialisation flagged for item 3). A bound naming an
   interface is still omitted, since the consumer's scope need not resolve its bare
   name.
6. **`T.default()`.** Over a type parameter bound to a scalar primitive, `T.default()`
   is that primitive's zero value (`0`, `0i64`, `0u32`, `0.0`, `false`, `""`, ...),
   substituted in the specialised body. Other bindings (a distinct type, a record) keep
   the call, which does not resolve; they are not supported yet (#8531).

## Overflow checking (resolved, #8532)

Overflow checking (D163) of `+`, `-` and `*` is recorded from the checked result type,
which is the type parameter in a generic body, so at first a generic `a + b` specialised
at `Int` wrapped where the same expression written at `Int` panics in a debug build.
The owner decided that an operator-bounded generic must behave exactly as the same code
written at the concrete type, per specialisation, so item 3 now also applies to a
parameter bound by `Add`, `Sub` or `Mul` that a specialisation binds to `Int`, `Long`,
`UInt`, `ULong` or `Byte`: that specialisation is type-checked again, the overflow sites
(and compound-assignment temporaries) the check records on the specialised body are
lowered on that function alone by `Lyric.ContractElaborator.lowerOverflowChecks`, and the
build profile decides panic or wrap as for hand-written code. The semantics of D163 are
unchanged, so this needs no new decision. A generic declared in the standard library is
left alone (the standard library always wraps, D163 item 3); a generic restored from
another package is checked in its declaring package's scope and follows the consumer's
profile. This is backend independent: the rewrite runs in `Lyric.Pipeline` before any
backend sees the file, and `scripts/ci/overflow-profile-e2e.sh` pins the debug panic and
the release wrap of a generic `Add` on dotnet, the JVM and native.

## Notes

- A bound naming an interface is dropped from the restored (contract metadata) repr of a
  generic function, as item 5 says; only built-in markers survive the round trip. A
  consumer of a restored package therefore does not see an interface bound on the
  generic, and T0108 is not raised for it at the call.
- The operator-marker list is written three times because the packages cannot share a
  helper (`operatorMarker` in the type checker, `isOperatorMarker` in `Lyric.Mono`,
  `isBuiltinMarkerName` in `Lyric.ContractMeta`); `contract_meta_self_test.l` asserts that
  they agree.
