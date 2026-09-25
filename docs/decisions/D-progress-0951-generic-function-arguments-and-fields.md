# D-progress-951 — Generic function-typed arguments and fields

**Status:** shipped

## Problem

Three related gaps surfaced when a generic library passed functions around
(`lyric-ui`'s `Program[M, Msg, E]`):

1. **Function references gave inference nothing.** `describeFn(toUi, xs)`,
   with `describeFn[E, Msg](f: (E) -> Option[UiEffect[Msg]], …)` and a named
   function `toUi`, left `Msg` unbound: `inferExprTE` did not type a bare
   function name. The imported-generic fallback then defaulted `Msg` to
   `Object`, and the specialised body cast `f`'s result to
   `Option<UiEffect<object>>`, an invalid cast at run time.
2. **That default was not refused.** The #5970 erasure-safety check
   (`typeExprUnsafeUnderErasure`) did not look inside function types, so a
   function-typed parameter whose result nests an unpinned type parameter in
   a generic (`(E) -> Option[U[Msg]]`) was treated as safe to default.
3. **Generic records' function fields got bogus MSIL types.** For
   `record Program[E, Msg] { classify: (E) -> Option[Effect[Msg]] }`,
   `addPackageTokens` resolved the field's parameter and result types in the
   record's own package with no knowledge of its type parameters, so `Msg`
   named a nonexistent class of that package and a call result carried a
   closed generic type no real instance has; a later `match` emitted an
   `isinst` against a nonexistent non-generic case class (T0120).

## Decision

1. `inferExprTE` types a bare reference to a known, non-generic,
   unambiguous function as `(P1, …, Pn) -> R` (`funcRefTEMono`), after
   locals and module `val`s.
2. `typeExprUnsafeUnderErasure` treats a function type as unsafe when any
   parameter type or its result is unsafe (a bare unpinned parameter or
   result stays safe: the delegate itself is erased), so such a default now
   raises M0004 instead of compiling to a crash.
   A bare union case name is never a function reference, even when
   nullary: `Go` of a non-generic union `Msg` types as `Msg`
   (`nullaryCaseTEMono`), so `clickHandlers(Go)` binds its type parameter
   to `Msg` without needing an annotated binding. A nullary case of a
   generic union, or a case name several unions share, stays untyped.
3. A generic record's function-typed field registers any parameter or result
   type that mentions the record's own type parameters as `object`
   (`recordFieldFuncTypeMsil`); the call result then takes the erased-value
   paths that test the runtime type.

## Verification

`mono_self_test.l` covers inference from a function reference and from a
bare nullary case, and M0004 for an unsafe function-typed default. `emitter_project_self_test.l` matches a
generic union returned through a generic record's function field and
through a function passed by name, inside an imported generic, on MSIL and
the JVM.
