# D-progress-966 — A specialised generic resolves its type names in its own package

**Status:** shipped

## Problem

A generic function imported from another package is specialised into the
calling package (#6363). D-progress-946 made the copy's function calls resolve
in the declaring package's scope, but both backends still resolved its bare
TYPE names in the calling package's scope. When the caller could see an
unrelated type of the same name, the specialised body silently named it:

- `Ui.Core.fire` matches on its own `Handler[Msg]` union. Specialised into an
  application that also depends on `lyric-web`, whose `Web.Handler` interface
  was the newest registration, MSIL resolved `Handler` to the interface; the
  `OnClick(m)` pattern then found no case field and bound nothing (T0115 on
  `m`).
- The JVM mapped the same bare name through the caller's extern/type map and
  cast the union case to the interface (`ClassCastException`).

## Decision

While lowering a function annotated `__lyric_origin` = P (a specialised copy,
or a lambda lifted out of one), bare type names resolve in P's scope first:
P's own declaration, then the newest one from a package P imports; only then
the calling package's tiers.

- **MSIL.** `CodegenCtx.typeScopeOrigin` holds P while a specialised
  function's signature is registered (`addPackageTokens`) and while its body
  is lowered (`lowerFuncMsil`); `resolveTypeFqn` consults it first.
  `liftLambdasMsil` tags every lambda lifted from such a body (nested ones
  included) with the same origin.
- **JVM.** Each package's type map also records its generic type names and
  its imports under reserved keys, seeded bundle-wide like other
  package-qualified keys. `originScopedExternTypes` overlays P's imports'
  and P's own types onto the calling package's map for the specialised
  function's signature (`collectFileSigsSeeded`,
  `collectMonoSpecializedSigs`) and body (`lowerFunc`); a generic type of P
  drops a same-named entry so it erases as generic types do.

## Verification

`emitter_project_self_test.l` (EPHs) specialises a generic matching on its
own `Handler` union into a package that imports an unrelated `Handler`
interface, on MSIL and the JVM.
