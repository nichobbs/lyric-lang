# D-progress-883 — JVM codegen: a mutable (`var`) opaque-type field now gets a `$<name>(T)V` mutator so same-package `inout` mutation works (#5937)

**Status:** shipped

**Context.** A `pub opaque type` with a `slice[Byte]` field, mutated through
an `inout` parameter from WITHIN the declaring package (legitimate
same-package field access, not a cross-package opacity violation), failed
at runtime with `NoSuchFieldError` — the caller looked up the field by its
unmangled source name (`buf`), but the declaring class's actual backing
field is name-mangled (`$buf`, reflection-sealing per language reference
§2.8). The identical field shape on a plain (non-`opaque`) `record` worked
correctly.

**Root cause.** `Jvm.Lowering.lowerOpaqueType` marks EVERY opaque backing
field `ACC_PRIVATE + ACC_FINAL`, unconditionally, regardless of whether the
source field was declared `var`. `Jvm.Codegen`'s field-assignment lowering
(`lowerAssignExpr`'s `EMember` arm and its implicit-self sibling) had no
opaque-awareness at all: it always emitted a raw `putfield <cls>.<fieldName>`
under the UNMANGLED name. Two independent problems: (1) that field doesn't
exist under that name (`$fieldName` does) — `NoSuchFieldError`; and (2) even
under the right name, a `final` field can only be assigned once, from the
declaring class's own `<init>` — a same-package `inout` mutation from a
DIFFERENT class could never legally write it at all. The read side already
routed through the `$<name>()T` getter accessor
(`Jvm.Codegen.lowerExpr`'s plain field-read path); only the write (and the
compound-assignment read) never got the equivalent treatment.

**Fix.** `LOpaqueField` gains an `isMutable` flag threaded from the source
`FieldDecl` (`OMField(f) -> ... isMutable = f.isMutable`). A mutable field's
backing field drops `ACC_FINAL`, and `lowerOpaqueType` additionally emits a
`$<name>(T)V` mutator (`Jvm.Lowering.lowerOpaqueSet`) — a legal
method-overload of the existing getter's name with a `(T)V` descriptor, not
a collision. `Jvm.Codegen`'s field-assignment lowering routes every write
(and compound-assignment read) through `emitFieldStoreOpaqueAware`/
`emitFieldLoadOpaqueAware`, which check `ctx.opaqueTypes` and dispatch to the
mutator/getter for an opaque receiver, falling through to the pre-existing
raw `putfield`/`getfield` for a plain record. `@projectable` opaque types
(a separate, unimplemented mutation surface) are left at the pre-existing
getter-only, `final` shape (`isMutable = false` at both of that path's
`LOpaqueField` construction sites) — out of scope for this fix.

**Verification.** New `projectable_jvm_self_test.l` case declares a plain
(non-`@projectable`) opaque type with a `var buf: slice[Byte]` field mutated
through `inout` from a free function in the same package, asserting the
mutation is visible afterward and a sibling immutable field is still
readable — `projectable_jvm_self_test` 7/7. No regression in
`record_method_jvm_self_test`, `out_inout_jvm_self_test`,
`out_inout_instance_jvm_self_test`, `control_flow_jvm_self_test`,
`silent_miscompile_guard_jvm_self_test`,
`iface_default_method_out_inout_jvm_self_test` (all green).
