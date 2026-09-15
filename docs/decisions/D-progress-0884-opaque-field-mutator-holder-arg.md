# D-progress-884 — JVM codegen: the opaque-field mutator routing from D-progress-883 extended to the out/inout holder-argument codegen path (#5937 review follow-up, #6944)

**Status:** shipped

**Context.** Automated review of D-progress-883's PR (#6912→#6911) correctly
identified a second, independent call shape reaching the same underlying
bug: an opaque type's mutable field passed **directly as an `out`/`inout`
call argument** (e.g. `bumpInout(h.count)`) rather than assigned
(`h.count = ...`). This routes through an entirely separate codegen path —
`Jvm.Codegen.prepareHolderArg`/`writeBackHolderArg` (`04_calls.l`) — which
D-progress-883's fix did not touch.

**Root cause.** `prepareHolderArg`'s `EMember` arm (reading the field's
current value into the holder before the call) and `writeBackHolderArg`
(writing the holder's post-call value back to the field) both emitted raw,
unconditional `LGetfield`/`LPutfield` under the field's unmangled name —
exactly the two problems D-progress-883 fixed for plain assignment
(`NoSuchFieldError` against the real mangled `$<name>` field, or a
verifier-rejected write to a `final` field), reached via a different call
shape entirely untouched by that fix.

**Fix.** Both call sites now route through the same
`emitFieldLoadOpaqueAware`/`emitFieldStoreOpaqueAware` helpers
D-progress-883 introduced in `05_stmts.l` (visible from `04_calls.l` — both
files are the same `Jvm.Codegen` package). The stack shape at each call site
already matches what the helpers expect (receiver below the field
value/argument, `invokevirtual`'s expected order for the mutator/getter is
identical to `putfield`/`getfield`'s), so no other change was needed.

**Verification.** New `projectable_jvm_self_test.l` case: an opaque type
with a `var count: Int` field, mutated three times by passing `h.count`
directly as an `inout Int` argument to a free function (not via assignment),
asserting the mutation count and a sibling immutable field's continued
readability — `projectable_jvm_self_test` 8/8. No regression in
`out_inout_jvm_self_test` (18/18) or `out_inout_instance_jvm_self_test`
(9/9).
