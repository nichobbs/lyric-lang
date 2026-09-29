# JVM: values in erased generic slots are boxed as the slot's type; `Map.remove` is `Bool` (#7782)

Two `--target jvm` bugs, both silent or late failures on programs the type
checker accepts.

**Erased-slot boxing.** On the JVM every generic slot is an erased `Object`:
the element of a `List[T]`/`Set[T]`, the key and value of a `Map[K, V]`, a
generic record field declared as a bare type parameter, a type-parameter
argument of a generic function the monomorphizer leaves generic. The checker
lets a narrower primitive flow into a wider slot (`Int` into `Long`, `Byte`
into `Int`), but codegen boxed each value as its *own* type. So:

```
val xs: List[Long] = newList()
xs.add(5)           // stored java.lang.Integer
val v: Long = xs[0] // ClassCastException: Integer cannot be cast to Long
```

and a `Map[Long, V]` key or `Set[Long]` element added from an `Int` never
compared equal to the same number as a `Long`, so lookups silently missed
(`m[2]` after `m.add(2, "two")` read `null`). Every shape was affected: `.add`
on a `List[Long]`, `xs[i] = 5`, a list literal bound to `List[Long]`/
`slice[Long]`, a `Map[String, Long]` value (`m["a"] = 5`, `m.add(k, 5)`),
`Map[Long, V]` keys (`m[1] = ...`, `m.add`, `m[k]`, `containsKey`, `mapGet`,
`remove`), `List[Int].add(aByte)`, `List[Double].add(1)`, and a generic record
built with arguments of two widths (`Two(a = aLong, b = 4)`, where `T` is
`Long`), whose field reads (`t.a + t.b`) also failed to compile with J008
because they stayed erased `Object`.

The fix boxes by the slot's declared type through one helper,
`boxForErasedSlot` (`Jvm.Codegen`, `02_exprs.l`), which widens a primitive
value to the slot's primitive type (`coerceArgTo`) before boxing it. The
slot's type comes from the receiver's recorded instantiation, the same
`scrutineeGenericArgs` registry element *reads* already narrow with
(`erasedSlotJvmType`): the `HashMap` intrinsics (`add`, `remove`,
`containsKey`, `m[k]` read and write, `mapGet`), the auto-FFI instance path
for `ArrayList`/`HashSet`/`HashMap` element methods
(`erasedCollectionArgSlotTys`: `add`, `set`, `contains`, `indexOf`,
`lastIndexOf`, `remove`, `put`, `get`, `getOrDefault`, `putIfAbsent`,
`containsValue`), and an annotated list-literal binding (`lowerBindingInit`).
A generic function call solves each type parameter to the widest primitive
its arguments pin it to, as the checker does (`genericCallArgSlotTys`), and
a generic record construction does the same per field (`genericCtorParamPrimitives`),
so `setAdd(s, 5)` on a `Set[Long]` stores a `Long`. A read of a generic record
field declared as a bare type parameter now unboxes to the receiver's
recorded instantiation (`narrowGenericFieldRead`), through `java.lang.Number`
so a value boxed at another numeric width still reads correctly.

`Set[T]` was unusable on the JVM before this: `newSet()` had no intrinsic
(unlike `newList`/`newMap`), so it linked against a nonexistent
`Std/CollectionsHost.newSet()` and threw `NoSuchMethodError`. It now
constructs a `java.util.HashSet` like its siblings.

**`Map.remove`.** `m.remove(k)` is `Bool` (true iff the key was present), as
the checker and the MSIL backend type it, but the JVM lowered it as `Unit`
(popping `HashMap.remove`'s previous value), so `val r = m.remove(k)` or
`if m.remove(k) { ... }` failed with J008 "stackmap simulation underflow".
It now lowers to `m.keySet().remove(k)`, which removes the entry and answers
exactly whether the key was present, even for a key mapped to `null` (which
`HashMap.remove`'s return value cannot distinguish). A statement-position
`m.remove(k)` pops the boolean.

Verified by `lyric-compiler/lyric/erased_slot_widen_self_test.l` (10 cases,
both targets; in `compiler-self-tests-batch.sh` and
`jvm-generics-self-tests-batch.sh`) and
`lyric-compiler/jvm/erased_slot_widen_jvm_self_test.l` (4 cases, `--target
jvm`; in `jvm-generics-self-tests-batch.sh`). Run one case per module
before the fix, 8 of the 10 dual-target cases failed on `--target jvm` (5
with `ClassCastException`, 1 with a `null` map lookup, 2 with J008); the
other two (a same-file generic function, which the monomorphizer
specializes, and statement-position `m.remove(k)`) passed and guard against
regressions. Of the JVM-only cases, the two `Set[Long]` cases failed with
`NoSuchMethodError` and the `List[Double]` case with `ClassCastException`;
the `List[Long]` lookup case passed before (the element and the lookup were
both boxed as `Integer`) and guards that lookups widen as the stored
elements now do. Everything passes after, and the dual-target file passes
on `--target dotnet` before and after.

The JVM-only file holds shapes `--target dotnet` does not pass today, for
reasons in the MSIL backend: a `Set[Long]` whose elements were added from an
`Int` stores `Int32` boxes, so lookups by a `Long` (and `setContains(s, 6)`)
miss and iterating it into a `Long` throws `InvalidCastException`; and
`xs.contains(5)`/`xs.indexOf(n)` on a `List[Long]` and `List[Double].add(1)`
throw `InvalidProgramException`.
