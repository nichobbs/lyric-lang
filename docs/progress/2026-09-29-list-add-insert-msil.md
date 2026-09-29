# Two-argument `List.add(index, item)` inserts on `--target dotnet` (#7797)

`xs.add(index, item)` on a `List[T]` inserts `item` before position `index`.
The JVM backend always did this, through `ArrayList.add(int, E)`. The MSIL
backend chose between `List.Add` and `Dictionary.Add` by the call's arity, so
it lowered every two-argument `add` as a map entry. On a list receiver that
meant `Dictionary<object,object>::Add` called on a `List<T>`, which is invalid
IL. Every such call threw `InvalidProgramException` when its method was
JIT-compiled. ilverify reported 31 errors on the new test file, and none of
its insert cases ran.

`add` now dispatches on the receiver. A `List` receiver's two-argument form
lowers to `List`1<T>::Insert(int32, !0)` through a new `LoInsert` list
operation, whose MemberRef is interned on first use like `IndexOf`/`Remove`
(#7785). An erased `List<object>` receiver binds the `List<object>`
instantiation. The index is coerced to `int32`. The element gets the same
treatment as `add(item)`'s: the element type pushed as the construction hint,
widening to the slot's type (`collSlotArgMsil`: `List[Long].add(0, 5)`), and
narrowing of an `object`-typed argument. A map receiver's `add(key, value)`
is unchanged.

The language reference (§2.7) now documents the insert form and its
out-of-range behaviour. An index outside `0 ..= count` raises
`ArgumentOutOfRangeException` on dotnet and `IndexOutOfBoundsException` on the
JVM, and leaves the list unchanged. `--target native` does not lower the
two-argument list form yet and rejects it at build time with `N0007`.

Verified by `lyric-compiler/lyric/list_insert_self_test.l`, which runs on both
targets. It covers insertion at the front, middle and end and into an empty
list, both out-of-range directions, `Int` widened into `List[Long]` and
`List[Double]`, a record element, a call through a generic function, and a
map's two-argument `add`. On dotnet it went from 3/9 passing with 31 ilverify
errors to 9/9 with none. The two out-of-range cases had "passed" only because
the `InvalidProgramException` was caught. On the JVM it is 9/9 before and
after. The file is in `compiler-self-tests-batch.sh`,
`jvm-generics-self-tests-batch.sh`, and `scripts/ilverify-selfhosted.sh`
phase 4.
