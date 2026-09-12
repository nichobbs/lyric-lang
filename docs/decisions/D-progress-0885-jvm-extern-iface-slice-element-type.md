# D-progress-885 — JVM codegen: `impl <ExternInterface> for Record` with a `slice[ExternType]` param/return now resolves the real JVM array type, scoped to extern-interface impls only (#5931)

**Status:** shipped

**Context.** `impl JX509TrustManager for TrustAll { func checkServerTrusted(
chain: in slice[JX509Certificate], authType: in String): Unit { ... } }` —
implementing a real JDK interface with an array-shaped method (very common:
`X509KeyManager`, `X509TrustManager`, many collection/listener SPIs) —
compiled cleanly and even ran fine as long as nothing outside the impl's own
code called the method, but `javap` showed every `slice[JX509Certificate]`
param/return erased to `[Ljava/lang/Object;` instead of the interface's real
`[Ljava/security/cert/X509Certificate;`. The moment anything dispatches
through the interface type via `invokeinterface` — a real TLS handshake
calling `checkServerTrusted`, or the JVM's own SPI machinery generally — the
mismatched descriptor throws `AbstractMethodError`: a genuine binary-
compatibility bug, not merely "unsupported."

**Root cause.** `holderAwareParamTypes`'s `erase` branch (used for impl-
method params) and `lowerImplMethod`'s return-type resolution both called
`typeExprToJvmErasedExtern`/`typeExprToJvmExtern`, NEITHER of which has a
`TSlice` case — both fall through their generic catch-all to
`typeExprToJvm`'s `TSlice(_) -> JArray(elem = Object)`, which erases every
slice element type uniformly and never consults `externTypes` for the
element.

**Fix — scoped, not a blanket change.** Per the issue's own framing, an
ORDINARY (non-impl) Lyric function signature keeps the uniform, erased
`Object[]` `slice[T]` ABI ON PURPOSE (every Lyric-to-Lyric slice call site
agrees on it regardless of element type) — the shared `typeExprToJvmExtern`/
`typeExprToJvmErasedExtern` functions those signatures resolve through were
deliberately left untouched (an initial attempt to add a general `TSlice`
case there was reverted after the type-parameter-aware `erase` path started
resolving a truly generic `slice[T]` through `externTypes`/the in-package
guess instead of erasing `T` to `Object`, and — more fundamentally — because
widening the fix beyond impl methods risked the exact same descriptor-
mismatch class of bug for a `slice[UserRecord]` in an ordinary signature,
whose uniform `Object[]` erasure other call sites depend on). Instead, two
new impl-scoped functions (`implTypeExprToJvm` / `implParamTypesToJvm`)
recurse through a `TSlice` to the real element type UNCONDITIONALLY (an
extern interface's descriptor is fixed and foreign — a primitive slice
element needs the real primitive array too, not just an extern one) and are
wired into `lowerImplMethod` (the method body) ONLY when the impl's
interface is extern (`Lyric.ConstraintRef` resolves through `externTypes`,
via the existing `implIfaceExternDottedFqn` helper) — a NEW `isExternIface`
parameter selects between the impl-aware and ordinary resolution. The
signature REGISTRATION side (`IImpl`'s `registerInstanceSig` call, used by
`lowerMethodCall`'s J3 M-3 path for in-package Lyric callers) gets a parallel
`registerInstanceSigImplExtern`, selected by the identical extern check, so
the two never diverge. A plain (non-extern) Lyric interface impl is
completely unaffected — its OWN interface method descriptor is independently
registered via `registerIfaceSig`'s ordinary, uniform-erasure path, so
narrowing only the impl body would have made the concrete method fail to
override the interface's abstract one at all.

**Verification.** `javap` on the emitted class confirms the fix: `impl
JCallbackHandler for SliceIfaceHandler { func handle(callbacks: in
slice[JCallback]): Unit }` now emits `public void handle(javax.security.
auth.callback.Callback[]);` (was `(Ljava/lang/Object;)V`). A Lyric-authored
call site through an interface-TYPED extern receiver resolves via auto-FFI
rather than this impl's own registered signature — a separate, pre-existing
auto-FFI limitation this fix does not touch — so the new
`iface_dispatch_jvm_self_test.l` case instead pins construction and a direct
call on the CONCRETE record (mirroring `ffi_iface_impl_jvm_self_test.l`'s
pattern): `iface_dispatch_jvm_self_test` 7/7. No regression in
`ffi_iface_impl_jvm_self_test`, `record_method_jvm_self_test`,
`out_inout_jvm_self_test`, `out_inout_instance_jvm_self_test`,
`control_flow_jvm_self_test`, `iface_default_method_out_inout_jvm_self_test`,
`silent_miscompile_guard_jvm_self_test` (all green).
