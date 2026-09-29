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
this change and 45 across 17 after it, with every test's exit status unchanged.
Three of those 45 are closed-generic values this change deliberately leaves
uncast, because their runtime representation is not guaranteed (see below): a
`MapEntry[Int, String]` slice element, an `Option[Int]` tuple element, and the
erased list in `unannotated_list_result_self_test.l`.

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
  most once. It casts only where the declared type has exactly one runtime
  representation: `String`, and a non-generic class or interface declared in
  Lyric (#7775's `isLyricDeclaredClassMsil`). A closed generic or a concrete
  `List`/`Map` is never cast: a construction with no type hint (an
  unannotated `newList()`, a bare `None`) builds the erased `List<object>` /
  `Option<object>` instance while the checker types it `List[Foo]`, and CLR
  generics are invariant, so the cast would throw — as it did in `lyric-proto`,
  whose `decodeMessage` builds `val fields = newList()`. Host types are never
  cast either, in particular `Func`/`Action` delegates (a Unit lambda is built
  as a `Func<…, object>`). `castObjectToMsil` also casts a `Func`-typed lambda
  parameter read back out of its `object` slot; every non-Unit lambda uses the
  uniform `Func<object, …>` ABI, so that value genuinely is a `Func`.
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

**Restored generic bodies with a block expression.** Casting call arguments to
`String` exposed a separate, pre-existing miscompile. A library ships each
generic function's body in its contract metadata as Lyric text
(`Lyric.ContractMeta.funcBodyText`), rendered by `Lyric.Fmt` from the
post-`Lyric.Mono` AST. Three Mono desugars produce block expressions: a call
through a function value (#7716: `f(x)` becomes
`{ val __lyric_fv_0: T = f; __lyric_fv_0(x) }`), a record `.copy`, and a
tuple-pattern guard (#7728). `Fmt` prints a block as an arrow-less `{ … }`, but
the consumer re-parsed the synthesised source as ordinary Lyric, where an
arrow-less brace expression is a zero-parameter lambda. So a consumer's
specialised copy of a library generic evaluated such a call as a `Func<object>`
thunk instead: `lyric-ui`'s `formFields` passed a thunk to `fieldViewAt`'s
`value: String` parameter, which `examples/ui-customers` stored as a prop value
unnoticed until the argument cast rejected it. `Lyric.RestoredPackages` now
marks the synthesised source with the file annotation `@contract_source`, under
which the parser reads an arrow-less brace expression as a block
(`ParseState.blockBraces`). The encoding is unambiguous because `Fmt` always
prints a lambda with its arrow (`{ -> … }`, `{ x -> … }`, `() -> e`).
Hand-written source is unchanged. The JVM was not affected: it calls a
library's compiled generic rather than specialising a restored body. Covered by
`restored_packages_self_test.l` (a synthesised block expression parses back as
`EBlock`; an unmarked brace expression stays a lambda) and by
`scripts/ci/crosspackage-restored-generic-values.sh`, a two-package build on
both targets wired into the `crosspackage-and-codegen-tests` CI job (which now
installs Java). The script also covers the `lyric-proto` shape across the
package boundary: a library's unannotated list returned in
`Ok(value = …)` and passed back to a library `List[T]` parameter.

New regression tests: the dual-target `erased_receiver_narrowing_self_test.l`
(tuple-element `List`/`Map` receivers, `Long` locals from `Int` literals, an
uninitialized `String` var, a record named `Point_2D`, `Self`-returning calls
used as receivers and typed arguments), the dual-target
`unannotated_list_result_self_test.l` (an unannotated list returned inside a
`Result[List[Seed], String]` is not cast to `List<Seed>`; not ilverified, since
the producer's store of the erased list is itself unverifiable), and the
dotnet-only
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
