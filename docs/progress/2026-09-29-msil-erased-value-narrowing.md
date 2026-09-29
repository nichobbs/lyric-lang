# MSIL: values erased to `object` are narrowed where a typed value is required (#7755)

`ilverify` over the compiled output of the generator self-tests reported
`StackUnexpected` errors in consumer code: an `object` on the evaluation stack
where the called member, parameter or local slot expected `List<T>`,
`HashSet<T>`, a record, a string or a `Long`. #7754 had already cast the
generator `for` loop's own enumerator slots; the rest were general codegen gaps
that only the generator tests happened to exercise. The JIT does not verify IL
for trusted assemblies, so most of them ran correctly — except one, which was a
real miscompile (below). A sweep of every `lyric-compiler/lyric/*_self_test.l`
that compiles on `--target dotnet` found 117 errors across 33 test DLLs before
this change and 42 across 14 after it, with every test's exit status unchanged.

Root causes and fixes, all in `lyric-compiler/msil/codegen.l`:

- **Legacy erased collection receivers.** `Set[T]`, and `List`/`Map` whose
  element type has no concrete instantiation (tuples, for example
  `List[(Int, Int)]`), are stored as `HashSet<object>` / `List<object>` /
  `Dictionary<object,object>`, and their parameters, locals, fields and returns
  are `object` in every signature — that is the cross-assembly ABI, so it
  stays. The `add`, `contains`, `containsKey`, `remove`, `removeAt` and `.count`
  arms called the `HashSet<object>`/`List<object>`/`Dictionary<object,object>`
  member on that `object` receiver directly. `emitErasedCollRecvCastMsil`
  now casts the receiver to the member's declaring type right after it is
  pushed. This covers the monomorphized `Std.Set` helpers (`setAdd__Int`, …).
- **Records whose name contains `_`.** `caseParentFqnMsil`, which computes the
  result type of the shared record/union-case construction path, fell back to
  splitting the name at its last `_` for any key without a `caseParentUnion`
  entry — which is every plain record. `Pkg.Point_2D(...)` was therefore
  tracked as the nonexistent class `Pkg.Point`, whose locals the LocalVarSig
  encoder erased to `object`. Passing such a local to a `Point_2D` parameter was
  unverifiable, and for a record constructed and passed in the same `test`
  block it was an `InvalidProgramException` at run time. The weaver's B′-mode
  records (`__LyricBModeCallContext`, `__LyricBModeArgs_*`,
  `__LyricBModeCfg_*`) hit it on every woven call. A record key now returns
  itself; the split applies only to a registered union-case key.
- **`Self`-typed results and parameters.** A `Self`-returning method's erased
  `object` result was re-tracked as the receiver class without a cast
  (`narrowSelfCallResultMsil`, and the in-bundle generic `Self`-return path);
  both now emit the matching `castclass`. A by-value non-receiver `Self`
  parameter (`other: in Self`), tracked as the class while its signature slot
  stays `object`, is copied once through `castclass` into a class-typed local
  in the method prologue (`narrowSelfParamsMsil`).
- **`object` flowing into a typed slot.** A local bound to a reference-typed
  annotation from an `object` initializer — notably the
  `val name: String = __lyric_tp_<n>` that #7728 desugars tuple-pattern names
  into — an `object` value returned from a reference-typed function, an
  `object` argument added to a concrete `List<Foo>`, and a `slice[T]` element
  read through `IList.get_Item` are narrowed with `castclass`. This extends
  the consumer-side downcast #7775 (#7752) added for `if`/`match` joins of
  distinct classes: the two are one helper, `narrowObjectToDeclaredTypeMsil`,
  used by every return, argument (`coerceCallArgMsil`), binding, assignment,
  constructor-field, list-add and slice-read consumer, so a value is cast at
  most once. It casts to `String`, a concrete `List`/`Dictionary`, and a
  Lyric-declared class, interface or closed generic (#7775's
  `isLyricDeclaredClassMsil`, applied to a generic's head too); host types are
  never cast — in particular `Func`/`Action` delegates, since a Unit lambda is
  built as a `Func<…, object>` and a cast to `Action` would throw.
  `castObjectToMsil` also handles by-name closed generics, which covers a
  `Func`-typed lambda parameter read back out of its `object` slot.
- **Integer widths.** A `Long` local, record-constructor argument or method
  argument bound from a 32-bit integer (the literal in `var t: Long = 0`) is
  widened with `conv.i8` (`widenIntToLongMsil`).
- **Uninitialized `var`.** `var s: String` (and the weaver's lifted `ret`
  slot) was initialized with an `int32` `0` for every non-numeric type. It now
  pushes the declared type's own default (`pushDefaultValueMsil`: `ldnull`,
  `initobj`, or the right-width zero).

`scripts/ilverify-selfhosted.sh` gains a second phase, so the required
`ilverify-required` CI job (and `make ilverify`) now also compiles and runs
`generator_for_loop`, `async_generator`, `generator_control_flow`,
`generator_control_flow_dotnet`, `generator_dispose`,
`generator_closure_var_capture` and the two new regression tests with
`lyric test --target dotnet`, then ilverifies each emitted test DLL against the
stdlib DLLs staged beside it and fails on any error.

New regression tests: the dual-target `erased_receiver_narrowing_self_test.l`
(tuple-element `List`/`Map` receivers, `Long` locals from `Int` literals, an
uninitialized `String` var, a record named `Point_2D`, `Self`-returning calls
used as receivers and typed arguments) and the dotnet-only
`erased_receiver_narrowing_dotnet_self_test.l` (`Set[Int]`/`Set[String]`
receivers and the `Std.Set` helpers; `Std.Set` is unusable on the JVM, #7312).
Both run in the compiler self-test batches and are ilverified in CI.

Remaining `ilverify` findings in the self-test corpus are other shapes, left
for follow-ups: a Unit lambda (`Func<object>`) passed where an `Action` is
declared; `bool[]` element stores; `Long` narrowed to `Int32` in compound
assignment and range-subtype factories; generic extern parameters typed as
`object` (`IEnumerable<T>`, `System.Array`, `List<ExternType>`); array-typed
elements of nested slices, whose run-time value may be `List`-backed; and an
`inout Self` parameter encoded as `object&`.
