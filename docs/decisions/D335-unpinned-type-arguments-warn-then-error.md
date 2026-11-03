# D335 - A type argument nothing fixes is W0034, then error T0224 (docs/70 phase 3a, #8613)

**Status:** shipped in two steps. Step one (#8757) added the warning W0034 and
migrated the sources; step two (this entry's items 6 and 7) turned W0034 into
the error T0224 and deleted the `Object` default for ordinary generics.

## Context

docs/70 §5.2: a generic call solves its type arguments from the arguments and
the expected type, and an argument that is still unsolved is an error, never a
default. The monomorphiser instead defaults every unpinned type argument of an
imported generic to `Object` (`mono.l`, the imported-generic fallback), which
produced `View[Object]` (afe3b73) and made `isNone(None)` silently mean
`isNone[Object](None)`.

D331 and D329 recorded the code for this as T0222; that was wrong (D312 owns
T0222). The code is **T0224**; T0210 is the selective-import error and T0223
belongs to the package-interface work.

## Decision

1. **W0034** is reported at a call to an imported generic whose type argument(s)
   neither the arguments, the expected type nor the checker's resolved type
   arguments (`genericCallTypeArgSites`) fix, where Mono would default them to
   `Object`: "cannot infer type argument(s) 'T' of 'f' from the call's
   arguments or its expected type, so they default to 'Object'; write
   'f[...](...)'". The call still specialises as before.
2. **An `@externTarget` generic never warns.** Its type arguments belong to a
   host boundary (`ConcurrentDictionary`2` through a `newConcurrentDict()`
   wrapper) and are erased; there is no specialisation to get wrong. The
   census's ten ecosystem hits were all of this kind.
3. **A call with no source position** (a generated declaration) never warns.
4. The same-package generic case keeps its existing errors (M0002), and an
   imported generic whose parameter shape makes the default unsafe keeps M0004.
5. **Migration (docs/70 §12.2).** The remaining hits were genuinely unpinned
   calls in `lyric-stdlib/tests/core_tests.l` and `book_ch07_tests.l`
   (`isSome(None)`, `isOk(Ok(value = 7))`, `mapResult(Ok(...), ...)`,
   `unwrapResult(Err(...))`); each now writes its type arguments
   (`isSome[Int](None)`), a form the seed also accepts. An `assertPanics`
   lambda that must return `Unit` is `unwrapResult[Unit, String](...)`.
6. **Step two: T0224.** The warning is the error **T0224** ("cannot infer
   type argument(s) 'T' of 'f' from the call's arguments or its expected type;
   write 'f[...](...)' or give the call an expected type") and the call is not
   rewritten. The `Object` default is deleted for an ordinary imported
   generic. It stays, silently, for three calls that have no call the user can
   write type arguments on: an `@externTarget` generic (a host boundary), a
   name the local environment binds (a function value) and a call without a
   source position (generated code).
7. **What the Mono unit tests pin.** Five tests encoded the default
   (`isEmptyLike(NoneLike)`, a partially pinned union constructor, a binding
   from an unpinned call, an ambiguous lambda body, a slice-shaped opaque
   argument). They now assert T0224 and no `Object` specialisation, and the two
   that tested instantiation tracking write their type arguments. The
   compile-fail corpus case `unpinned_type_argument` pins the diagnostic on
   both targets.
8. **Not changed.** The `Ok(value = 7)` expression that stands alone keeps its
   `Result[Int, Object]` typing in Mono's result-type inference until the
   checker reports the unsolved parameter itself (the `TyInfer`-at-the-call
   work); it is an inferred type, never a specialisation.

## Census

`lyric check` over the manifests that build here and the stdlib tests, and
bootstrap stage 2 (compiler and stdlib built with the warning): 22 hits, 10 of
them `@externTarget` generics (excluded by item 2) and 12 in the two test files
(migrated by item 5); a rerun finds none. Manifests whose local dependencies
are unbuilt, the JVM and native paths, tests in `tests/` directories, embedded
programs and generated source are covered by CI's logs, which this PR's run
provides.
