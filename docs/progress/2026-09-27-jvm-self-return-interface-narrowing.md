# JVM: `Self`-returning interface calls now narrow to the interface (#7586)

Follow-up to D-progress-1013 (#7550): a `Self`-returning method called
through an INTERFACE-TYPED receiver (`func fresh(): Self` on `interface
Maker`, called as `m.fresh()` where `m: in Maker`) is typed by the checker
as the interface itself (T0113). On `--target jvm`, the call-site
codegen-internal narrowing helper (`narrowSelfCallResult`,
`lyric-compiler/jvm/codegen/04_calls.l`) used to early-out for an interface
receiver (`sig.isIface`) and leave the tracked type at the erased
`java/lang/Object` — sound for the emitted bytecode (the descriptor stays
erased either way) but wrong for a LATER unannotated binding: `val x =
m.fresh()` tracked `x` as raw `Object` codegen-internally, so a following
method call (`x.size()`) fell to the erased instance auto-FFI guess instead
of dispatching via `invokeinterface`, and panicked
(`error[J008]: no matching instance or inherited method for
'java.lang.Object.size()'`). Reproduces with a plain record `impl`, not just
a protected type.

## Fix

`narrowSelfCallResult` no longer early-outs on `sig.isIface`: when
`sig.retIsSelf`, it always emits a `checkcast <cls>` and narrows the tracked
type to `JRef(cls)`, where `cls` is the dispatch/receiver class name — the
interface's own class for an `invokeinterface` call, exactly as
`invokevirtual` narrows to the concrete class. `checkcast` against an
interface type is legal JVM bytecode (JVMS §6.5 places no restriction on
the target being a class vs. an interface), and it can never throw for a
checker-accepted program: `checkImplConformance` only accepts a
`Self`-declared return as exactly the impl/record's own target type, which
by definition implements the interface it's dispatched through.

Three JVM call sites needed the same fix, all previously returning the
erased `sig.ret` directly on their `sig.isIface` branch instead of calling
`narrowSelfCallResult`:

- The main instance-method-call path (`lowerVirtualCall`'s
  `<cls>#<memberName>` lookup) — the one in the issue.
- `lowerVirtualCallWithHolders` (a `Self`-returning method that also has an
  `out`/`inout` parameter).
- The bare intra-impl sibling call inside an interface DEFAULT method body
  (`lowerGeneralStaticCall`'s `ctx.selfClass` branch, where `selfClass` is
  the interface's own class for an `IMFunc` body).

MSIL needed no fix: `narrowSelfCallResultMsil` (`lyric-compiler/msil/codegen.l`)
already has no interface guard — its dispatch key IS the receiver's tracked
static type FQN, and MSIL emits no cast instruction at all (the CLR JIT
does not enforce CIL type-safety verification at load time for ordinary
trusted assemblies), so narrowing the codegen-internal tracked type to the
interface class was already sound and already happening there.

Also fixed a stale doc comment on `emitSelfParamChecksJvm`
(`lyric-compiler/jvm/codegen/06_items.l`): it said the function's
`selfTypeName` parameter is always non-empty at "both call sites"
(`lowerImplMethod`, `lowerRecordMethod`); #7550 added a third,
`lowerProtectedMethod`.

## Tests

`bare_func_ref_self_test.l` (dotnet and JVM batches): five new cases
(`Maker7586`/`R7586`, a plain record impl) covering an untyped local bound
from an interface-receiver `Self`-returning call, the same shape through an
interface-typed function parameter, chained `.fresh().fresh()` calls
through an interface receiver, a `var` reassigned across two calls, and the
result flowing into another interface-typed parameter. Added to
`scripts/ci/jvm-generics-self-tests-batch.sh` (was dotnet-only before this).

`protected_iface_impl_self_type_self_test.l`: the "Self return … via an
interface binding" test's `val f: Merger = m.fresh()` workaround annotation
is removed — the test now exercises the untyped `val f = m.fresh()` form
that motivated this fix, on both the dotnet and JVM batches it already ran
in.

Regression: `scripts/ci/compiler-self-tests-batch.sh` and
`scripts/ci/jvm-generics-self-tests-batch.sh` both green (no `not ok`
lines); `scripts/ci/jvm-ecosystem-suites.sh` all suites `0 failed`;
`scripts/ilverify-selfhosted.sh` reports 0 IL-validity errors across 126
self-hosted-emitted DLLs.
