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
A generic record construction (`lowerConstruction`) and a call to a generic
function the monomorphizer left generic (`lowerGenericStaticCallBoxingByType`)
first lower every argument into a temp, keeping a primitive bound to a bare
type parameter unboxed; each type parameter is then instantiated at the
widest of those arguments' *lowered* types (and, for a call, a container
argument's element type: `s: Set[Long]`), as the checker instantiates it,
and every such argument is widened to it and boxed as it on reload. So
`Two(a = longCall(), b = 4)` and `setAdd(s, 5)` on a `Set[Long]` store
`Long`s. `boxForErasedSlot` never narrows: a value wider than the slot type
it is given keeps its own box (`canWidenPrimitiveJvm`).

A read of a generic record field declared as a bare type parameter now
unboxes to the bound local's recorded instantiation (`narrowGenericFieldRead`),
through `java.lang.Number`. That instantiation is recovered before the
constructor call is lowered, from each argument's statically known type
(`peekPrimitiveJvm`: literals, locals, parameters, calls to non-generic
functions, primitive field reads, arithmetic on those). If any argument for a
primitive type parameter has no such type (a generic call, say), none is
recorded and the field reads stay erased, since the unseen argument could be
wider than the rest and a narrower read would truncate it.

A first version of this change took the widest type from that pre-lowering
peek alone, which skipped arguments it could not type. `Two(a = longCall(),
b = 4)` then boxed the `long` as an `Integer` without converting it, and the
class failed verification at load time (review finding #7790). The
record-construction cases in both test files cover that shape and failed with
`VerifyError` on that version.

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

Verified by `lyric-compiler/lyric/erased_slot_widen_self_test.l` (12 cases,
both targets; in `compiler-self-tests-batch.sh` and
`jvm-generics-self-tests-batch.sh`) and
`lyric-compiler/jvm/erased_slot_widen_jvm_self_test.l` (6 cases, `--target
jvm`; in `jvm-generics-self-tests-batch.sh`). Run one case per module
before the fix, 8 of the 10 #7782 dual-target cases failed on `--target jvm` (5
with `ClassCastException`, 1 with a `null` map lookup, 2 with J008); the
other two (a same-file generic function, which the monomorphizer
specializes, and statement-position `m.remove(k)`) passed and guard against
regressions. Of the JVM-only cases, the two `Set[Long]` cases failed with
`NoSuchMethodError` and the `List[Double]` case with `ClassCastException`;
the `List[Long]` lookup case passed before (the element and the lookup were
both boxed as `Integer`) and guards that lookups widen as the stored
elements now do. The four #7790 cases (two per file) are the
mixed-width record constructions and generic calls with a call, binary
operation, or field read on either side of a literal. Everything passes
after, and the dual-target file passes on `--target dotnet` before and
after.

The JVM-only file holds shapes `--target dotnet` does not pass today, for
reasons in the MSIL backend: `Two(a = longCall(), b = 4)` reads back a
wrong value (`t.a + t.b` is `-1294967292`, not `3000000004`; the other
argument order is correct); a `Set[Long]` whose elements were added from an
`Int` stores `Int32` boxes, so lookups by a `Long` (and `setContains(s, 6)`)
miss and iterating it into a `Long` throws `InvalidCastException`; and
`xs.contains(5)`/`xs.indexOf(n)` on a `List[Long]` and `List[Double].add(1)`
throw `InvalidProgramException`.
