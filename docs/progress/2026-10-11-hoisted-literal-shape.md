# A literal bound to a temporary keeps the shape its position gives it (#8190)

#8190 reported that `sum3([7, 8], ok(1)?)`, with `sum3` taking an
`array[2, Int]`, failed with `InvalidCastException` (`Int32[]` to
`List<Int32>`) on dotnet and `N0007` ("cannot pass a list where `[2 x i32]` is
expected") on native, while the JVM printed the right result. Passed directly,
the literal was fine.

**Root cause.** A bracket literal is built as an `array[N, T]`, a `List[T]` or
a `slice[T]` of the expected element type according to the position it is
written in, not from its elements (D167, docs/01 §4.1). When an argument after
it holds a `?` or an `await`, `Lyric.HoistEngine` (or the D171 argument-order
rewrite) binds it to a fresh local so it still runs first. That local has the
type the type checker records for the operand
(`SymbolTable.hoistOperandTypeSites`, read by `Lyric.Mono` as the local's
annotation), and `recordHoistOperandTypeOver` recorded only a closed generic
instantiation, plus a special case for a list literal where a `List[T]` is
expected (#8171). An `array[2, Int]` is neither, so the local took the
literal's own slice type and was built as one.

**Fix.** `recordHoistOperandTypeOver` now asks `shapedOperandType` whether the
operand's value is a literal its position shapes: a bracket literal where an
`array[N, T]`, a stdlib `List[T]` or a `slice[T]` is expected, a tuple literal
holding one (each element at its own expected type), or an `if`, `match` or
block whose value is one. Such an operand is recorded at that shape whatever
its element type, with the expected element type each element is widened to;
any other operand is still recorded only at a closed generic instantiation.
The `?` hoist, the `await` hoist, D171 argument-order temporaries, method-call
and constructor arguments, tuple elements and list elements all record through
this one function, so every one of them now builds its temporary as the
direct-argument path builds the literal.

**JVM.** A `?` inside an array literal of primitives (`[ok(3)?, 4]` where an
`array[2, Int]` is expected) failed with `J008` ("reference
'__lyric_array_of' resolves to no local"). The JVM builds such a literal with
the `__lyric_array_of[array[N, T]](...)` intrinsic, and the hoist bound any
callee that was not a bare name to a local when an argument holds a hazard.
A type application of a name now names its function as a bare name does and is
bound only when that name is a reassignable local (`hzStackedCallee` keeps the
old behaviour for any other callee).

Tests: `hoisted_literal_shape_self_test.l` (13 cases, dotnet, JVM, native):
the issue's repro and a parenthesised literal; array and widened-element array
literals, list literals and widened slice literals before a `?` and before an
`await`; named arguments in and out of order with the source-order trace, with
and without a `?`; a by-reference variable and an array element passed beside
the literal (D171, D179); a method call; constructor fields of array and list
type, named out of order, and a union case's array field; a generic callee
taking `array[2, T]` at `Int` and `String`; arrays of arrays, a `List` of
arrays with a `?` in an inner literal, and a tuple holding an array; an `if`
and a `match` whose value is an array literal; and the failing-`?` path. Wired
into the compiler, JVM-generics and native batches and the `ilverify` list.
`typechecker_self_test.l` checks the recorded types directly, including that a
call operand of array type is not recorded.
