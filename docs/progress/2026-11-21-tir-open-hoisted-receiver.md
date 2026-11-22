# Builder: a method receiver the hoist recorded a closed type for (D379)

`emptyCell().tagged(await five())` builds at `Cell[Int]`. Self-test: `await_hoist_typed_self_test.l`.
