# D-progress-1016 — Native: `Self` in an interface method signature erases to a pointer-width raw pointer, matching the box's own `obj` slot (#7585)

**Status:** shipped (bare `Self` lowering; the `N0006` diagnostic for `Self` nested inside a generic type argument, added in review before merge — see "revision" note below).

Follow-up to D-progress-1013 (#7550), which shipped `Self` in an impl
method's signature on a protected type for `--target dotnet`/`--target
jvm` and explicitly left `--target native` as a pre-existing, unrelated
gap: `registerInterfaceTypes` resolves every interface method's declared
param/return types through `typeExprToNType`, whose fallback arm panicked
("this type form is not yet supported for --target native") on a bare
`TSelf`, at interface vtable-type registration time, before any
record- or protected-type-specific lowering ever ran. This affected
record impls (pre-existing since interfaces shipped, D-progress-568) and
protected-type impls (newly reachable once D-progress-1013 lifted the
shared type checker's T0136 rejection for `Self` on protected impls).

## Decision

A BARE `Self` (a parameter, a return, or the implicit receiver's own
type — never one nested inside a generic type argument) erases to a
pointer-width `i8*` in the interface's own vtable slot signature
(`typeExprToNType`'s `TSelf` arm). This is the SAME erased representation
the interface box's own `obj` slot already uses (`03-type-mapping.md`'s
"Interface dispatch" section, D-N-016), and every implementer of `Self`
on this backend — a record or a protected type — is a heap-boxed,
pointer-width object, so the erasure is ABI-compatible with any concrete
impl's own pointer type via the SAME unchecked function-pointer bitcast
`ifaceVtableInitStr` already performs for every vtable slot (a
`bitcast` between LLVM pointer types never fails, regardless of the
declared signature on either side, as long as the calling convention and
pointer width match — which they always do here).

This mirrors, at the erased-slot level, what MSIL and the JVM already do
(erase `Self` to `object`/`Object` in the interface slot) — but native's
representation of "an interface value" is a genuinely separate heap-boxed
fat pointer (D-N-016), not a native subtype relation the host runtime
enforces for free, so three call-site behaviors needed real codegen (not
just a type-resolution fix):

1. **The record/protected impl's OWN signature** is substituted to the
   concrete type before it ever reaches codegen, exactly as it already
   was for record impls (`substSelfInFn`/`collectImplMethods`,
   pre-existing). Protected-type members did NOT have this substitution
   (`registerProtectedMember`/`collectProtectedMethods` used the member's
   raw, unsubstituted `Self`-mentioning params/return directly) — this
   was the SAME class of gap #6421/#6426 already fixed for record/impl
   methods and for MSIL/JVM protected entries in D-progress-1013 §"CODEGEN-
   INTERNAL body-typing bookkeeping"; native gets the analogous fix here.
2. **A `Self`-typed argument dispatched through an interface receiver**
   (its checker-assigned static type is the interface itself —
   `substituteMethodSig`'s `Self`-to-`recv` substitution, T0113) is
   unboxed to its raw `obj` pointer at the call site (`coerceTo`'s new
   branch: extract `obj` from an already-boxed interface value, or plain
   bitcast an as-yet-unboxed concrete record/protected value — both a
   borrow, no retain, Rule 5). Native has no free subtype relation the
   way MSIL/JVM's object model gives them, so this extraction is real
   codegen, not a no-op.
3. **A `Self`-typed return dispatched through an interface receiver**
   reboxes the erased `i8*` result into a FRESH interface box
   (`lowerIfaceDispatch`'s new `ii.methodRetIsSelf[slot]` branch,
   `reboxErasedSelfResult`), reusing the SAME vtable pointer already
   loaded from the receiver's own box — sound because the checker only
   accepts a `Self`-declared return as exactly the callee impl's own
   target type, which is by construction the same concrete runtime type
   as the receiver, so its vtable for THIS interface is identical to the
   receiver's. No extra retain: the called method already transferred a
   fresh rc=1 ownership of the raw result to this call site (Rule 6), and
   that ownership moves directly into the new box's `obj` slot; the box's
   own destructor (`synthIfaceBoxDtor`, pre-existing) is the one release
   that balances it.

Calling a `Self`-mentioning method on the CONCRETE receiver needs none of
the above: the callee's own (now-substituted) signature already declares
the concrete type, so the call resolves and types normally with no
narrowing bookkeeping — unlike MSIL/JVM, which erase-then-narrow
(`narrowSelfCallResultMsil`/`narrowSelfCallResult`) even for the concrete
path, because their interface-slot erasure is shared with EVERY
call, not just the dynamically-dispatched one.

## `Self` nested inside a generic type argument: still unsupported, reported as `N0006`

`Self` nested inside a generic type argument (`List[Self]`, `Option[Self]`)
is a SEPARATE, still-unsupported shape on native. MSIL and the JVM support
it for free (their generics erase to `object`/`Object` regardless of
nesting depth), but native's generic types monomorphize per concrete type
argument (D-N-010, `Lyric.Mono`) — there is no call site to infer a type
argument from at an interface DECLARATION the way an ordinary generic call
infers one from its arguments, so there is no single erased "`List` of
`Self`" instantiation to register uniformly across every future
implementer. Building one (a synthesized "erased-element" monomorphization
bypassing `Lyric.Mono`'s call-site inference entirely) is a separate,
larger piece of design work, tracked in #7603.

### Revision (pre-merge review): a proper `N0006` diagnostic, not a panic

The first version of this fix detected the shape in
`registerInterfaceNames` (deep inside `Lyric.LlvmCodegen`, at interface
vtable-type registration) and reported it via `panic(...)` — a message-
quality improvement over the OLD generic "type form is not yet supported"
panic, but still an unhandled `System.Exception` with a
`Lyric.LlvmCodegen`-internal stack trace reaching the user, which
CLAUDE.md's "no untyped panics" rule and the issue's own ask ("a proper
diagnostic ... not an untyped panic from inside codegen") both rule out.

The shipped fix moves detection to a PRE-PASS, `Lyric.LlvmCodegen
.nativeSelfShapeDiagnostics(units: List[CodegenUnit]): List[Diagnostic]`
— a pure function (no panic) that walks every non-generic interface across
the compiled units and returns one `errorDiagnostic("N0006", ...)` per
nested-`Self` parameter/return, mirroring the SAME traversal
`registerInterfaceNames` uses. `Lyric.LlvmBridge.linkAndEmitNative` (the
convergence point both `compileToNativeWithFlags` and
`compileProjectToNativeWithFlags` funnel through) runs this pre-pass and
`Lyric.DiagnosticUtil.diagReportAndAbort`s on it BEFORE calling into
codegen at all — the SAME pattern the mode checker's own pre-codegen gate
(`N0100`) already uses. `lyric build --target native` on an offending
program now prints a normal `error[N0006] file:line:col: message` line to
stderr and exits non-zero, with NO exception and NO stack trace — see the
`N0001`-`N0006` table in `book/chapters/appendix-b-quick-reference.md`
§B.11.

`registerInterfaceNames`'s own `panicUnsupportedSelfShape` call is kept as
a defensive fallback, unreachable for any caller that goes through
`Lyric.LlvmBridge` (the pre-pass always catches the shape first), but
still reachable for a caller that invokes `Lyric.LlvmCodegen.codegenNativePackage`/
`codegenNativeBundle` directly without running the pre-pass — a real
(if narrow) case: `llvm_self_test_self_iface.l`'s OTHER tests do exactly
this for their own (non-nested-`Self`) shapes, and a future direct caller
of codegen deserves the same message quality as the bridge's diagnostic,
not a regression to the old generic panic.

## Tests

`llvm_self_test_self_iface.l` (new, 9 tests): record and protected impls,
`Self` parameter and `Self` return, via a CONCRETE receiver (protected
only — record impls are only reachable through an interface receiver on
native today, a separate pre-existing gap unrelated to this feature) and
via an INTERFACE receiver, chained `Self`-returning calls, a not-yet-boxed
concrete argument at a `Self`-through-interface parameter, an ASan-clean
ARC check for both record and protected paths, and two nested-`Self`
cases: `nativeSelfShapeDiagnostics` returns exactly one `N0006` diagnostic
with a real span and a message naming the interface/method (asserting the
STRUCTURED diagnostic, not a caught panic), and `compileToNativeWithFlags`
on the same source returns `false` (a full end-to-end proof that the real
`lyric build --target native` entry point fails cleanly, before codegen,
with no exception). Added to `scripts/ci/native-backend-self-tests.sh`.

`protected_iface_impl_self_type_self_test.l` now runs on `--target
native` too (added to `native-backend-self-tests.sh`'s explicit
`--target native` loop) — its bare-`Self` cases (4 tests) pass unchanged
on all three targets. Its `List[Self]` case was split out to a new file,
`protected_iface_impl_self_type_nested_self_test.l` (dotnet/JVM only),
so the nested-`Self` gap does not block the rest of the file's native run
(native fails to compile the WHOLE test module if any interface it
declares hits the nested-`Self` diagnostic, since interface registration
runs over every interface in the compiled unit regardless of which test
invokes it).

Regression: `scripts/ci/native-backend-self-tests.sh` (25 files/loops, 0
`not ok`), `scripts/ci/native-target-smoke-test.sh`, and
`scripts/ci/compiler-self-tests-batch.sh` (66 test-file runs, 0 `not ok`)
all green.
