# D-progress-886 — JVM emitter parity for `@externTarget` `Option[T]` null-coercion, D107 Phase 2 (#3932)

**Status:** shipped

**Context.** D107 (Phase 1, MSIL-only) lets an `@externTarget` function
(non-ctor, non-async) declare its return as `Option[T]` (`T` a reference type)
and have the emitter bind the MemberRef to the host method's real nullable
reference return, coercing `null -> None` / value `-> Some(value)` at the call
boundary. The self-hosted JVM backend (`lyric-compiler/jvm/`) had no
counterpart: `typeExprToJvm`'s `TGenericApp` arm erases every non-`List`/`Map`
generic head — `Option[T]` included — to `Ljava/lang/Object;`, so the invoke
descriptor built for e.g. `@externTarget("java.lang.System.getenv"):
Option[String]` bound to `Object getenv(String)` instead of the JDK's real
`String getenv(String)`. Bytecode verification/linking rejects the mismatched
descriptor outright (`NoSuchMethodError: 'java.lang.Object
java.lang.System.getenv(java.lang.String)'` at the first call) — the JVM path
was not merely missing the coercion, it did not compile to a runnable call at
all.

This entry supersedes the "Phase 2: stdlib migration + `case null` removal
deferred" status line on D107 (the frozen archive entry, `docs/03-decision-
log.md`) only insofar as JVM emitter parity — a prerequisite for that Phase 2
— has now shipped; D107's own text is left byte-frozen per the archive
convention (`docs/decisions/README.md`).

**Decision.** Ported the MSIL convention to `lowerExternTargetBody`
(`jvm/codegen/04_calls.l`): a new `externOptionCoerceInnerJvm` helper mirrors
MSIL's `externOptionCoerceInner`/`externOptionCoerces` pair, pattern-matching
`decl.ret`'s raw `TGenericApp` for a bare `Option` head with one type argument
(the same `lastSegment(head) == "..."` idiom `isResultJvmException` already
uses for `Result[T, JvmException]`, so no type-checked/resolved type is
needed) and returning the coercion inner `JvmType` only when it is a JVM
*reference* type (`not isJvmPrimitiveElemType(inner)` — reusing the existing
primitive-descriptor predicate rather than adding a duplicate one; `Option[T]`
over a JVM primitive never needs coercion, since a primitive return can never
be null). `isAsync` short-circuits to `None`, mirroring MSIL's exclusion
(neither backend's `@externTarget` async path composes with this convention).
When the convention applies, `javaRet` (which feeds both the F0015-J metadata
verification and the actual `invokestatic`/`invokevirtual` descriptor) is
overridden to the coercion inner type instead of the erased `Object`, and the
post-call sequence stashes the (possibly null) result to a local, `ifnull`
branches to construct `Std/Core/Option$None`, otherwise
`Std/Core/Option$Some` from the stashed value — the same `LNew`/`LDup`/
`LInvokespecial(<init>)`/`LAstoreAs` shape `lowerBuiltinOrStaticCall`'s
`mapGet` lowering already uses for its `containsKey`-gated Option
construction, so no new construction idiom was introduced. Static-field-typed
`@externTarget`s (`decl.params.count == 0` resolving to a `getstatic`, not a
method call) are explicitly out of scope, matching Phase 1's field exclusion
(`msil/codegen.l`'s field-read branch also never applies `externOptionCoerceInner`).

**Verification.** `extern_option_self_test.l` extended with `@cfg(target =
"dotnet")` / `@cfg(target = "jvm")` variants of `getEnvOpt` (dotnet:
`System.Environment.GetEnvironmentVariable`; jvm: `java.lang.System.getenv`)
sharing one set of target-agnostic test cases — an unset, guaranteed-unique
env var name coerces to `None`, and `PATH` (set in every real process on both
targets) coerces to `Some` — so no per-target setter extern was needed to
exercise either branch. `lyric test --target dotnet
extern_option_self_test.l`: 2/2 (unchanged from Phase 1). `lyric test
--target jvm extern_option_self_test.l`: 2/2 (new; both cases failed with the
`NoSuchMethodError` above before this fix). `auto_ffi_jvm_self_test.l`: 52/52
(no regression — confirms `isResultJvmException`'s `Result[T, JvmException]`
convention, which shares the `wrapResult`/`javaRet` computation this change
touches, is unaffected since the two conventions are mutually exclusive by
generic head name).

**Related:** D107 (MSIL Phase 1, `docs/03-decision-log.md`),
docs/01-language-reference.md §11.3 (`@externTarget` reference),
docs/18-jvm-emission.md (Q-J010), `jvm/codegen/04_calls.l`
(`lowerExternTargetBody`, `externOptionCoerceInnerJvm`), `msil/codegen.l`
(`externOptionCoerceInner`, the ported convention), `book/chapters/13-
interop-and-ffi.md` §13.5.1.
