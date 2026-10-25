# Mono: a generic call passed to another generic takes the outer call's expected type

`val v: View[Msg] = keyed("outcomes", paragraph("Outcomes"))`, with `keyed`
and `paragraph` the `Ui.Widgets` generics, failed with
`System.ArrayTypeMismatchException` when `v` was added to a
`List[View[Msg]]` on dotnet. Binding `paragraph(...)` to a typed local first
worked, and D230 left that workaround in two files.

Two places in `Lyric.Mono` lost the type:

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

Covered by a `mono_self_test.l` case (a binding annotation, `List.add`, and a
doubly nested `keyed`, with a type parameter named like the caller's union).
The run-time half is a cross-package fixture,
`lyric-compiler/fixtures/nested_generic_expected/`, run on dotnet and JVM by
`scripts/ci/nested-generic-expected-test.sh` from
`scripts/ci/test-multi-package-examples.sh`. The intermediate bindings in
`lyric-ui/plugins/e2e/host/src/host.l` and
`examples/plugins/ui-widgets/review/src/view.l` are removed.
