# Literals and explicit type arguments beside `?` and `await` keep their meaning (#8190, #8279)

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
block whose value is one. Such an operand is recorded at that shape, with the
expected element type each element is widened to (or the literal's own where
the expected one is open); any other operand is still recorded only at a
generic instantiation. `typeExprForOpenBinding`, which spells the recorded type
inside a generic function, gained the `array[N, T]` arm it lacked, so an array
of the enclosing function's type parameter (`[x, y]` passed as an
`array[2, T]`) is recorded too; without it that local was a slice
(`InvalidCastException`, `N0007`) or left `Lyric.Mono` unable to infer the
callee's type argument (`M0002`). The `?` hoist, the `await` hoist, D171
argument-order temporaries, method-call and constructor arguments, tuple
elements and list elements all record through this one function, so every one
of them now builds its temporary as the direct-argument path builds the
literal.

**Callees under type arguments (#8279).** The hoist bound every callee that
was not a bare name to a local when an argument holds a hazard. Two callees
name a function under type arguments and are no value: the
`__lyric_array_of[array[N, T]](...)` intrinsic a JVM array literal of
primitives is built with (`[ok(3)?, 4]` failed with `J008`, "reference
'__lyric_array_of' resolves to no local"), and explicit type arguments written
in source, which the parser leaves as an index of the function's name
(`id2[Int](5, ok(1)?)` failed with `T0115` on dotnet, `J008` on the JVM and
`N0007` on native). A type application of a name is now bound only when the
name is a reassignable local, as a bare name is. For the source form, the
type checker records each indexed callee it resolves as a generic function
under type arguments (`SymbolTable.typeArgCalleeSites`: the name binds no
local, receiver field, `val`, `const`, wire or config of any package, and
names a function with one generic parameter per index), and both hoists
leave exactly those in their calls: the `?` hoist reads the record directly,
and the `await` hoist, which runs after `Lyric.Mono`, gets it through
`MiddleEndOptions.typeArgCalleesOut` and `pipeWeave`. Every other indexed
callee, including an element of another package's `pub val` used
unqualified (`fns[i](a, ok(4)?)`), is still bound before the arguments, so
its index runs first.

The type checker gives a call under explicit type arguments no direct
signature, so it recorded nothing for its arguments: a literal bound ahead of
a `?` there (`firstOf[Int]([7, 8], ok(1)?)`) was still built as a slice, and
named arguments written out of order ran in parameter order. Such a call now
looks up the function by its name, substitutes the explicit type arguments
into its parameter types (`recordExplicitTypeArgCall`), and records the
hoisted operands and the D171 argument-order site against them, so
`firstOf[Long]([7, 8], ok(1)?)` builds an `array[2, Long]`.

Tests: `hoisted_literal_shape_self_test.l` (14 cases, dotnet, JVM, native):
the issue's repro and a parenthesised literal; array and widened-element array
literals, list literals and widened slice literals before a `?` and before an
`await`; named arguments in and out of order with the source-order trace, with
and without a `?`; a by-reference variable and an array element passed beside
the literal (D171, D179); a method call; constructor fields of array and list
type, named out of order, and a union case's array field; a generic callee
taking `array[2, T]` at `Int` and `String`, from inside a generic function at
its own type parameter, and under explicit type arguments (`firstOf[Int]`,
`firstOf[Long]` widening the elements, `id2[Int]`, named arguments out of
order in source order); an `array[2, T]` tuple element; an indexed closure
callee, whose index still runs first; arrays of arrays, a `List` of arrays
with a `?` in an inner literal, and a tuple holding an array; an `if` and a
`match` whose value is an array literal; and the failing-`?` path. Wired into
the compiler, JVM-generics and native batches and the `ilverify` list.
`typechecker_self_test.l` checks the recorded types directly, including
`array[2, T]` in a generic function, `array[2, Long]` under an explicit type
argument, which callees are recorded as under type arguments (not an index
of a parameter or of a module-level `val`), and that a call operand of array
type is not recorded. `scripts/ci/hoisted-callee-cross-package-e2e.sh` (in the
compiler and native batches; dotnet, JVM, native) calls an element of another
package's `pub val` list of functions and that package's generic function
under explicit type arguments, beside a `?` and an `await`, as a sibling
package and as a restored dependency, checking the evaluation order.
