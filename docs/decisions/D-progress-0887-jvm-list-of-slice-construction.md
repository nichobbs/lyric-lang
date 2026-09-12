# D-progress-887 — JVM: `List[slice[T]]` (a `List` whose elements are arrays) is now constructible and indexable, closing two construction bugs plus a read-back gap the fix exposed (#6546)

**Status:** shipped

**Context.** #6546 (filed while adding a regression test for #6541/#6542)
reported `List[slice[T]]` — a `List` whose elements are themselves arrays —
completely unusable on `--target jvm`: constructing one hit two separate,
pre-existing bugs independent of the #6541 `for`-loop fix.

**Bug 1 — a bare slice-literal `.add()` argument stored a raw `ArrayList`,
not a real array.** `xs.add([1, 2, 3])` on `xs: List[slice[Int]]` compiled
clean, but reading the row back and iterating
(`for row in xs { for v in row { … } }`) crashed with `ClassCastException:
class java.util.ArrayList cannot be cast to class [Ljava.lang.Object;`.
Root cause: a bracket literal (`EList`) always lowers to a
`java.util.ArrayList` first (`02_exprs.l`'s `EList` case) — only a call site
with a KNOWN DECLARED `slice[T]` parameter type later converts it into a
real array via `coerceArgTo`'s `JArray` arm (`ArrayList.toArray()`).
`List[T].add(value: T)` has no such declared param type of its own: on the
JVM, `List[T]` compiles straight to `java.util.ArrayList`, so `.add()`
dispatches through the generic JDK auto-FFI instance-call resolver
(`lowerAutoFfiInstanceCall`, `04_calls.l`) against the REAL
`ArrayList.add(Ljava/lang/Object;)Z` — genuinely opaque to Lyric's
`slice[T]` vs `List[T]` distinction — so `emitFfiCoerce` saw an
`ArrayList`-typed argument headed for an `Object` parameter and (correctly,
for every OTHER `T`) left it untouched: an `ArrayList` IS-A `Object`, no
coercion needed. **Fix** (`04_calls.l`'s `lowerMethodCall`): intercept
`.add` before the auto-FFI dispatch whenever the RECEIVER's own recorded
generic instantiation (`scrutineeGenericArgs` + `sliceElemTypeExpr`) names a
`slice[Elem]` element type, and route the argument through the same
`coerceArgTo` `JArray` arm a normal `slice[Elem]`-parameter call site would
use. `indexedElemTypeOverride` itself could not be reused for this
detection: it deliberately returns the safe `JVoid` sentinel for exactly
this "element type is itself array-shaped" case (its own `case JArray(_) ->
return JVoid` comment) — a defensive bail-out for its OTHER callers (plain
element-type narrowing on READ), not applicable to this WRITE-side coercion
decision.

**Bug 2 — the same value routed through an explicit `slice[Int]`-typed
helper failed EARLIER, at compile time.** `func intRow(vals: in
slice[Int]): slice[Int] { vals }` then `xs.add(intRow([1, 2, 3]))` panicked
before Bug 1 was even reached: `error[J008]: JVM auto-FFI: no matching
instance or inherited method for
'java.util.ArrayList.add([Ljava/lang/Object;)'`. Root cause
(`auto_ffi.l`'s `scoreParamMatch`): once the argument's static type was
precisely `slice[Int]`, `ffiScoreDescFor` narrowed its SCORE-ONLY
descriptor to a primitive-array shape (`[I`, via `indexedElemTypeOverride`
resolving the call's declared element type) — the #6745 mechanism, meant to
let a `slice[T]` argument's scoring correctly prefer a real
`int[]`/`char[]`/… JDK overload over a same-named `Object[]`-erased generic
one. But `scoreParamMatch` had a reverse-compatibility arm accepting a
narrowed primitive-array descriptor against an `Object[]` PARAMETER (line
603, #6696) and a separate arm accepting a REAL (un-narrowed) reference
array against a bare `Object` PARAMETER (line 551, #4775) — with no arm at
all for a NARROWED primitive-array descriptor against a bare `Object`
parameter, exactly `ArrayList.add`'s real shape. So the one real overload
never scored, and the call panicked at compile time despite being a
perfectly ordinary `List[T].add()`. **Fix**: added the missing arm —
`argIsNarrowedSliceErasure and isPrimitiveArrayDesc(argDesc) and paramDesc
== "Ljava/lang/Object;"` scores 3 (matching the real-array-to-Object arm's
score) — gated on `argIsNarrowedSliceErasure` for the identical reason as
the sibling #6696 arm: a Lyric `slice[T]`'s REAL runtime representation is
always `Object[]`, `Object`-assignable regardless of which primitive
element type `ffiScoreDescFor` narrowed it to for scoring, whereas a
GENUINELY primitive-array-typed argument's real class is the primitive
array itself and needs the flag to stay excluded (unrelated `emitFfiCoerce`
codepath).

**Read-back gap fixing Bug 1 exposed (not in the original report, but
required to construct a working value at all).** With both bugs fixed,
`val row = xs[0]` compiled and ran, but a FURTHER index into that element
(`row[0]`, or directly `xs[0][1]`) threw the SAME `ClassCastException`
shape Bug 1 did — `[Ljava.lang.Object; cannot be cast to class
java.util.ArrayList`. Root cause: `EIndex`'s own codegen
(`indexedElemTypeOverride`'s `JVoid` bail-out, same one Bug 1's fix works
around) leaves `xs[0]`'s result an erased `Object`; `EIndex`'s "unknown
`JRef` receiver → assume `ArrayList`" default (`02_exprs.l`, load-bearing
for match-bound `List[YamlPair]`-shaped payloads) then mis-cast the real
array. This is exactly the read-back normalization #6546's own tracking
issue anticipated, mirroring `emitNormalizeErasedSlice`
(`03_match.l:1610`) — the same fix #6541's `for`-loop already used for
nested-slice iteration. **Fix**: a new `applyIndexedElemOverrideNormalizingSlice`
(`02_exprs.l`) consults the SAME `forLoopNestedArrayElemTypeExpr` detector
#6541 introduced; when the receiver's element type is itself `slice[Elem]`,
`checkcast [Ljava/lang/Object;` instead of leaving the value erased.
Deliberately does NOT reuse `emitNormalizeErasedSlice`'s full dual
real-primitive-array/boxed-`Object[]` `instanceof` check the `for`-loop fix
needs: that check exists because ITS consumer (`SFor`'s `emitArrayLoad`)
already dispatches every JVM primitive element type correctly, while
`EIndex`'s own per-element `match` only special-cases `JByte` and `JRef` —
every other primitive falls to a bare `aaload`, so returning a genuine
`JArray(elem = JInt)` here throws `VerifyError: Bad type on operand stack
in aaload` (confirmed by testing this exact variant before simplifying).
Every producer that can reach a nested `slice[T]` element the Lyric way (a
bare slice literal or a `slice[T]`-typed function's return) flows through
`coerceArgTo`'s `ArrayList.toArray()` conversion (Bug 1's own fix),
ALWAYS yielding the boxed `Object[]` uniform representation — never a
genuine primitive array — so the simple checkcast is sufficient and
correct here.

**Scope.** JVM-only, matching the tracking issue's own scope (MSIL's
`List[T]` backing is not `ArrayList`-based and never hit either bug).
The new self-test's empty-slice-element-row case does surface a separate,
pre-existing MSIL bug (`--target dotnet` throws "Attempted to access an
element as a type incompatible with the array" on the same case) — filed
as #6945 rather than folded into this fix, which is scoped to `--target
jvm` per #6546. Both fixes key off `scrutineeGenericArgs`, which does not
resolve a receiver's generic instantiation for a plain field-access
receiver (`someRecord.rows.add([1, 2, 3])`) — a pre-existing limitation,
not a regression this PR introduces — tracked separately as #6957.

**Verification.** New `@test_module`
`lyric-compiler/jvm/list_of_slice_construction_jvm_self_test.l` (4 cases:
bare-literal `.add()` round-trip + iteration, `slice[Int]`-typed-argument
`.add()` compiling and round-tripping, an empty-slice-element row, and a
3-row `List[slice[Int]]` with `xs[i][j]` nested-index reads on every row) —
4/4 on `--target jvm`. No regression: `auto_ffi_jvm_self_test.l` 52/52
(including the #6662/#6745 overload-scoring cases the `scoreParamMatch`
change sits beside), `erased_element_checkcast_jvm_self_test.l` 16/16,
`generic_uint_erasure_jvm_self_test.l` 5/5, `subscript_assign_jvm_self_test.l`
19/19, `silent_miscompile_guard_jvm_self_test.l` 44/44,
`chained_elem_jvm_self_test.l` 2/2, `list_literal_uint_elem_jvm_self_test.l`
3/3, and `nested_slice_for_jvm_self_test.l` 4/4 on both targets. The
`List[slice[T]]` (List-outer) test cases `nested_slice_for_jvm_self_test.l`
dropped from PR #6542 for this exact blocker are NOT restored there — the
new dedicated self-test file is the intended home for that coverage; that
file's header comment is updated to note the blocker is resolved.
