# A generic call passed to another generic takes the outer call's expected type (#8590)

`val v: View[Msg] = keyed("outcomes", paragraph("Outcomes"))`, with `keyed`
and `paragraph` the `Ui.Widgets` generics, failed with
`System.ArrayTypeMismatchException` when `v` was added to a
`List[View[Msg]]` on dotnet. Binding `paragraph(...)` to a typed local first
worked, and D272 left that workaround in two files.

Two places in `Lyric.Mono`, and the native backend's own inference, lost the type:

- **`markArgsExpectedMono`** gives a generic argument its expected type only
  from a substitution built from the outer call's other arguments.
  `"outcomes"` binds nothing, so the substitution was empty. `paragraph`,
  whose type parameter appears only in its return type, then fell back to
  `Object`. The outer call's own expected type (`expectedAt`, D-progress-947)
  now also binds the substitution through the callee's declared return type,
  the way it already did for the outer call itself. Whether a parameter type
  is concrete is now decided by which type variables are bound, not by
  looking for their names in the substituted type. The old check refused
  `View[Msg]` when the caller's own type was named like the callee's type
  variable, which is the `Ui.Widgets` case.
- **The outer call's argument evidence** read the un-rewritten argument, whose
  inferred type is the `Object` default (`View[Object]`). So `keyed` bound
  `Msg = Object` even after `paragraph` had been specialised at `Msg`. A
  generic call argument is now read after its own rewrite
  (`paragraph__Msg(...)`, a `View[Msg]`).

- **The native backend** infers type arguments in `Lyric.LlvmCodegen`, and
  lowered each argument of a generic call without an expected type, so the
  same call failed to build for `--target native` (N0007, `cannot infer type
  argument 'Msg' for generic function 'paragraph'`). A call argument whose
  parameter type mentions a type parameter now gets that type as its
  expected-type hint (`genericCallArgWant`), bound from the earlier arguments
  and then from the outer call's expected type. The hint fills only what the
  inner call's own arguments leave unbound, and a non-generic call ignores it.

Covered by a `mono_self_test.l` case (a binding annotation, `List.add`, and a
doubly nested `keyed`, with a type parameter named like the caller's union).
The run-time half is a cross-package fixture,
`lyric-compiler/fixtures/nested_generic_expected/`, run by
`scripts/ci/nested-generic-expected-test.sh`: its test suite on dotnet and JVM
from `scripts/ci/test-multi-package-examples.sh`, and its `NestedMain` program
on native from `scripts/ci/native-target-smoke-test.sh`. The JVM erases
generics, so there it only guards against regressions. The intermediate bindings in
`lyric-ui/plugins/e2e/host/src/host.l` and
`examples/plugins/ui-widgets/review/src/view.l` are removed.
