# MSIL: in-bundle generic tuple destructure cast (#7517) and T0120 operand guard tests (#8344)

## #7517 - in-bundle generic value destructured from a tuple

`val (m, j) = (Just(value = b), 1); maybeN(m)` bound `m` at `Maybe<Box>` but
left the `object` from the tuple's `List<object>` on the stack, so ilverify
reported `found ref 'object', expected Maybe<Box>` at the first use. Same for a
generic record (`Pair<Box,int32>`). `Std.Core.Option`/`Result` elements were
already cast.

Root cause: the tuple `PTuple` bind narrowed each element with
`castObjectToMsil`, which deliberately emits nothing for an in-bundle
`MGenericInstByName` (its other callers can hold an erased `Box<object>`
construction, #7755, so a cast there would throw).

Fix (`lyric-compiler/msil/codegen.l`, `lowerPatternBindMsil` `PTuple` arm): an
element whose tracked type is an in-bundle closed generic is cast with
`MCastclassGeneric`. The tracked element type comes from the tuple literal's
own construction (or the declared tuple type's construction hint, #4965, and
the branch-join hole fill, #7455), so at this site the element is that
instantiation. `castObjectToMsil` and `narrowObjectToDeclaredTypeMsil` are
unchanged, so #8349 (lambda parameters, which can receive erased values) is
not affected and stays open.

JVM: generics are erased there and the cases were already correct; the test runs
on both targets to keep parity.

Tests: `lyric-compiler/lyric/tuple_inbundle_generic_self_test.l` (6 cases:
union, record, match after destructure, nullary beside payload, two generics in
one tuple, returned tuple) passes on dotnet and the JVM, was 7 ilverify errors
before, 0 after, and is in the ilverify gate list.

## #8344 - `+` and operators on object-typed operands

The MSIL guards (#8432, #8620) raise T0120 when an operand is known only as
`object`. JVM audit (#8641): `Jvm.Codegen` `BAdd` already panics at compile time
for two `Object` operands (#6398) and the other operators resolve a numeric or
string operation from the known side.

No source program can produce an erased operand today: the checker types
function-value call results (the #8283 trigger) and rejects an extern
`System.Object` operand with T0030. The two shared guard functions are now
`pub` and `lyric-compiler/msil/msil_operand_guard_self_test.l` (10 cases) feeds
them synthetic erased operand types: arithmetic `+ - * / %` and unary `-`
(both sides the same expression) and ordering `< > <= >=`, asserting a T0120
error at the erased operand's span, and no diagnostic for typed operands or an
erased operand against a value type (unboxed). It runs in the MSIL backend CI
step.

No language-reference or book change: no surface change.
