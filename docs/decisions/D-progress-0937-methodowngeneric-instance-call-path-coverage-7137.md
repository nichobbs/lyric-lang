# D-progress-937 — `emitGenericMethodExternCall`'s INSTANCE-call path gets real regression coverage (review follow-up, #7137)

**Status:** shipped

**Context.** A `claude-review` pass on PR #6981 flagged (REQUIRED) that every
existing regression test for Gap 2 (`emitGenericMethodExternCall`, D-progress-929)
exercised only the STATIC method-own-generic path (`Enumerable.Empty<T>`,
`Repeat<T>`, `First<T>`, `ElementAt<T>`) — deliberately chosen so CI needs no
`lyric-grpc` package dependency. But Gap 2's own motivating real-world API,
`CallInvoker.BlockingUnaryCall<TRequest,TResponse>`, is an **instance**
method. The receiver-load / `MCallvirt` (vs. plain `MCall`) /
`isValueTypeReceiverMsil`-decline / `mpIdx` parameter-offset logic specific
to the instance path (an instance call's `this` occupies argument slot 0,
shifting every declared parameter's index by one relative to the static
path) was therefore completely unexercised, in a code family that had
already needed five follow-up fixes discovered post-review within the same
PR (D-progress-930 through 936).

**Finding a BCL-only instance method matching the shape.** Most generic-method
BCL APIs with a bare (non-wrapped) method-own-generic parameter or return
turn out to be STATIC on inspection, even when called with instance-like
syntax in C# — `Enumerable.*`/`Array.Empty<T>`/`Activator.CreateInstance<T>`
are all static utility methods, and `DataRow.Field<T>`/`SetField<T>` (an
initially promising candidate) turned out to be **extension methods**
declared `static` on `System.Data.DataRowExtensions`, not genuine instance
methods on `DataRow` itself — confirmed by `@externTarget`'s own hint-less
`F0027` warning refusing to verify the call against reference-assembly
metadata when declared as an instance call, then an `InvalidProgramException`
at runtime when force-declared with `@externInstance` anyway (the wrong
calling convention against a real static MemberRef).

`System.Text.Json.Nodes.JsonNode.GetValue<T>(): T` is a genuine, always-available
(`System.Text.Json`, no extra NuGet/gRPC package) BCL instance method
matching Gap 2's exact shape: `JsonNode` is a non-generic declaring type,
`GetValue<T>()` is declared with its own method-level generic parameter (not
an extension method), witnessed as `System.Object` by the MethodSpec exactly
like the static-path methods, with a bare MVAR return — so both the
box/unbox-at-witnessed-Object dance (#6989/D-progress-930) and the
reference-type `castclass` narrowing (D-progress-936) get exercised on the
instance path too.

**Fix.** No code change — `emitGenericMethodExternCall`'s existing instance
branch (added in the original Gap 2 fix, D-progress-929) already handles
this shape correctly; the gap was purely in test coverage. Added
`jsonGetValueInt`/`jsonGetValueStr` (`@externInstance` + `@externTarget`)
wrapping `JsonNode.GetValue<T>()`, backed by `JsonValue.Create(v)` to
construct the receiver, to `generic_extern_methodspec_self_test.l`.

**SUGGESTION (acted on).** The same review pass flagged a stale one-line doc
comment directly above `scoreSigType` in `metadata_reader.l`
("2 = exact, 1 = widening / boxes to object, -1 = incompatible") describing
the PRE-D-progress-934-renumbering tier scale, left in place two lines above
the accurate post-renumbering tier-scale block added by that same entry.
Deleted the stale line.

**Verification.** New test "JsonNode.GetValue<T>() exercises the
INSTANCE-call path through emitGenericMethodExternCall (#7137)" asserts both
a real `Int` value (42, boxed-argument/unboxed-return) and a real `String`
value ("hello", reference-type castclass-narrowed return) round-trip
correctly through a genuine instance call, not merely that the call doesn't
crash — proving both the `Int` and `String` variants of the same
box/unbox/castclass machinery already verified on the static path also work
correctly when the receiver is loaded via an instance dispatch.
`generic_extern_methodspec_self_test.l`: 7/7 pass (6 prior + this one).

**Related:** #6581/D-progress-929 (Gap 2, this entry's base — the instance
branch this entry adds coverage for was already implemented there, just
untested), D-progress-930 (#6989, the box/unbox dance this entry proves also
works on the instance path), D-progress-936 (the reference-type `castclass`
narrowing this entry proves also works on the instance path), #7137 (this
review finding), PR #6981.
