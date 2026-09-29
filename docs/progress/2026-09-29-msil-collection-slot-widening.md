# MSIL: collection element, key and value arguments widen to the slot's type (#7785)

The `--target dotnet` counterpart of the JVM erased-slot fix (#7782). The
checker lets an `Int` (an unsuffixed literal or any `Int` expression) or a
`Byte` flow into a wider collection slot, and admits an `Int` argument to the
host collection methods of a `List[Double]`/`Map[K, Double]` (whether it
should is #7786; the checker is unchanged here). `Msil.Codegen` passed such an
argument as its own type:

- `Set[T]` is an erased `HashSet<object>`, so `s.add(5)` on a `Set[Long]`
  stored a boxed `Int32`. A lookup by a `Long` (`s.contains(five)`,
  `setContains(s, 6)` — `T = Long`, `s.remove(five)`) never matched it, and
  iterating the set into a `Long` binding threw `InvalidCastException`. A
  silent miscompile.
- A concrete `List<T>`/`Dictionary<K, V>` method takes the element type
  unboxed, so `List[Double].add(1)` and `Map[String, Double].add(k, n)` pushed
  an `int32` where a `float64` is required: `InvalidProgramException`. The
  `Int`-into-`Long` forms (`xs.contains(5)` on a `List[Long]`, `m[2]` on a
  `Map[Long, V]`) ran only because the JIT tolerated the unverifiable `int32`.
- `xs.indexOf(x)`/`xs.lastIndexOf(x)` on a `List[T]` were routed to the
  `String.IndexOf` intrinsic (`InvalidProgramException` for any argument), and
  `xs.remove(x)` on a `List[T]` was a pop-only stub that removed nothing and
  returned `false` — both silent gaps the JVM backend already lowered.

**Fix.** One rule, applied wherever a value is passed to a collection's
element, key or value slot: `collSlotArgMsil` widens the value to the slot's
declared type (`widenPrimToSlotMsil`: `conv.i8` into `Long` from
`Byte`/`Int`/`Char`, `conv.r8` into `Double` from `Byte`/`Int`/`Long`, a
`Byte` into `Int` retyped as `Int32`; never narrows) and then boxes it *as
that type* for an erased receiver. The slot type is the receiver's tracked
element/key (`collElemSlotTyMsil`) or value (`collValueSlotTyMsil`) type.
Covered: `add` (List/Set element, Map key and value), `contains`,
`containsKey`, `remove` (Map key, Set element, List element), `indexOf`,
`lastIndexOf`, indexed reads and stores (`m[k]`, `m[k] = v`, `xs[i] = v`,
compound `m[k] += v`), `mapGet`/`tryGetValue` keys, and list-literal elements.
`List.indexOf`/`lastIndexOf`/`remove(x)` now lower to
`List`1<T>::IndexOf(!0)`/`LastIndexOf(!0)`/`Remove(!0)` through new
`ListOp`s (`LoIndexOf`, `LoLastIndexOf`, `LoRemove`) whose MemberRefs are
interned on first use (`listElemMethodTokenForLowering`).

**Before / after** (`--target dotnet`):

| case | before | after |
|---|---|---|
| `Set[Long]`: `s.add(5)`; `s.contains(five)` | `false` | `true` |
| `Set[Long]`: `s.add(n)` (`n: Int`); `s.contains(six)` | `false` | `true` |
| `Set[Long]`: `setContains(s, 6)` | `false` | `true` |
| `Set[Long]`: `s.remove(five)` | `false` | `true` |
| `Set[Long]`: `for v in s { total = total + v }` | `InvalidCastException` | `3000000005` |
| `List[Long]`: `xs.indexOf(3000000000)` / `xs.indexOf(n)` | `InvalidProgramException` | `1` / `0` |
| `List[Double]`: `add(1)`, `add(n)`; `ds[0] + ds[1]` | `InvalidProgramException` | `3` |
| `Map[String, Double]`: `m.add("b", n)` | `InvalidProgramException` | `6` (sum) |
| `List[Long]`: `xs.remove(5)` | `false`, nothing removed | `true`, removed |

**Tests.** The Set/List/Map cases of the JVM-only
`lyric-compiler/jvm/erased_slot_widen_jvm_self_test.l` now pass on dotnet and
moved into the dual-target `lyric-compiler/lyric/erased_slot_widen_self_test.l`;
the emptied JVM-only file is deleted and dropped from
`scripts/ci/jvm-generics-self-tests-batch.sh`. New cases cover
`List[Long]` `remove`/`lastIndexOf` with an `Int` argument, a `Byte` element
of a `Set[Int]`/`List[Int]`, and a `Map[Long, Long]` read, compound-assigned,
probed and removed through an `Int` key. The test is also added to the
consumer-DLL phase of `scripts/ilverify-selfhosted.sh` (it verifies clean).
