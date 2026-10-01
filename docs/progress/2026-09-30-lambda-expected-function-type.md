# Lambdas take the function type expected of them (#7865)

Found while fixing #7852. Three related gaps in how lambdas were typed.

**A generic call over a lambda could fail with `M0002`.** `Lyric.Mono`
infers a generic call's type arguments from its argument expressions, and it
types a lambda argument from its body's trailing value. It could not type a
body that read an unannotated module `val` (`applyT({ -> LIT_BYTE })` with
`val LIT_BYTE = 209u8`) or ended in an `if`, a `match` or a block. For a
same-package generic that left `T` unbound, which is `M0002` on both
targets; the type checker had typed the call correctly all along. The
checker now records each generic call's resolved type arguments
(`SymbolTable.genericCallTypeArgSites`, keyed by the callee's span, recorded
only when every argument is closed and has a source spelling). Mono takes any
type argument its own inference leaves unbound from there, before the
imported-generic `Object` default or `M0002`, in both the call rewrite and
the return-type inference that types a binding such as `val b = applyT(...)`.
A bare generic call's instantiated result type is also recorded in
`callResultTypes`, so Mono's fallback for an unknown call result covers it.

**A lambda's body did not widen to the expected return type.**
`val f: () -> Long = { -> 5 }` was `T0060` (`() -> Int` against
`() -> Long`), although `val x: Long = 5` is accepted and a function whose
body's value is `5` may declare `Long`. A lambda checked against a closed
function type now takes its return type as the lambda's declared return
type, as `checkFunctionBody` does for a function: the body's value, each
value-producing `if`/`match` branch and each `return` are checked against it
and widen to it along the lossless chains, recorded as conversion sites, so
both targets build the value at the wider type. Every lambda argument, not
only one with an unannotated parameter, is now checked in the call's
expectation-aware second pass, so `callLong({ -> 12 })` against a
`() -> Long` parameter widens too. Narrowing is unchanged: an `Int` literal
is not a `Byte`, `UInt`, `ULong` or `Double` at a binding
(`val b: Byte = 200` is `T0060`), so it is not one as a lambda's value either.
An expected `List[T]` return type is not adopted, because a bracket literal
as the body's value would then be typed `List` while each backend builds it
from the literal's own position, which a lambda body is not (MSIL built a
`T[]` and failed the cast).

**A `return` nested in a lambda body was checked against the wrong function.**
The lambda's top-level statements were checked with no return type, but a
`return` inside an `if`/`match` branch or block in the body used the scope's
return type, the enclosing function's: a `String` lambda's `return "pos"`
inside an `Int` function was `T0065`. The lambda body now gets its own
scope carrying the lambda's return type (or none).

**Unannotated lambda parameters were `Object` on the JVM.** The JVM backend
types an unannotated lambda parameter `Object`, so a method call on it
(`{ i -> i.toLong() }` against `(Int) -> Long`) failed with `J008`, and so
would the widening the second fix inserts for `{ n -> n }` against
`(Int) -> Long`. The checker records the type each unannotated parameter
took from the expected function type (`SymbolTable.lambdaParamTypeSites`,
closed types only, conflicting checks left alone) and Mono writes it onto the
parameter as its annotation, so every backend sees the checked type.

Tests: `function_value_typing_self_test.l` (new, dual-target, 6 cases) runs
in `scripts/ci/compiler-self-tests-batch.sh`,
`scripts/ci/jvm-generics-self-tests-batch.sh` and
`scripts/ilverify-selfhosted.sh` phase 4. `typechecker_self_test.l` covers
the widening and its conversion sites, zero-parameter lambda arguments,
narrowing and mismatch rejection, the nested-`return` scope, and both new
site channels.

docs/01 §5.4 describes lambdas checked against a function type and §2.11
the generic inference over a lambda argument; the book's closures section shows
the widening and the lambda-local `return`.
