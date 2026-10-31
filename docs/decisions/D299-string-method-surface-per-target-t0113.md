# D299 - T0113 for an unknown `String` method, per target (#7204)

**Status:** shipped (dotnet, JVM; native and target-less checks unchanged)

**Supersedes** the decision in `D-progress-0941` (the reverted #7188
allowlist): that arm could not be correct for both targets because the
shared checker did not know which one it fed.

## Context

An unknown method on a `String` type-checked cleanly. On dotnet the
closed `lowerMethodCallMsil` cascade then panicked at codegen (`T0120`); on
the JVM `lowerAutoFfiInstanceCall` resolves any name against
`java.lang.String`, so `s.getBytes()` is valid and a typo fails only inside
auto-FFI. A single allowlist in `maybeUnknownMemberDiag` broke
`hash_jvm_self_test.l` and `try_catch_expr_jvm_self_test.l`
(`getBytes()`), so #7099's diagnostic was reverted.

## Decision

1. The checker takes the target's `String` surface, `StringMethodSurface`
   (`typechecker_symbols.l`): `SMSUnchecked` (default: the language server,
   the contract checks, native), `SMSClosed` (dotnet) and
   `SMSOpen(hostMethods)` (JVM).
2. The entry point `checkWithImportedPackagesForTarget` carries it from
   `MiddleEndOptions.stringSurface`. `Msil.Bridge` passes `SMSClosed`;
   `Jvm.Bridge` passes `SMSOpen` with every instance method name of
   `java.lang.String` and its supertypes, read once per process from the JDK
   metadata by `Jvm.AutoFfi.instanceMethodNames`.
3. A call `s.m(...)` on a `String` is T0113 when `m` is none of: a universal
   method (`toString`, `equals`, ...), `length`/`isEmpty`, `indexOf`/
   `lastIndexOf`, a name `stringHostMethodType` types (the intrinsic set that
   both backends implement), a `Std.String` function or extension the imports
   reach, or, on the JVM only, a method in `hostMethods`.
4. Native stays unchecked: its `String` lowering is not a closed set this
   decision has audited; that is tracked on #7204's follow-up.

## Consequences

- A typo such as `s.toLowerInvariant()` is a check-time T0113 on dotnet and
  on the JVM (no such `java.lang.String` method), and `s.getBytes()` stays
  valid on the JVM.
- The intrinsic set has one definition, `stringHostMethodType`; adding a
  backend intrinsic means adding it there, or the call is rejected.
- Tests: `typechecker_self_test.l` (per-surface cases) and the JVM
  `getBytes` self-tests.
