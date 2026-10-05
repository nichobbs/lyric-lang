# `out`/`inout` places are never copied by the `?` and `await` hoists (#8171)

`zap(x, g()?)` for `func zap(a: inout Int, b: in Int)` left `x` unchanged on
dotnet, the JVM and native. The `?` operand hoist (`Lyric.HoistEngine`, shared
by `Lyric.Propagate` and `Lyric.AwaitHoist`) binds every operand evaluated
before the argument holding the `?` to a fresh local, and it did that to the
`inout` argument too: the callee wrote the local, never `x`. The same held for
`await` in an `async func`, for `out` arguments, and for a field passed by
reference (`zap(c.v, g()?)`).

- The type checker now records a D171 argument-order site
  (`SymbolTable.argOrderSites`) for every call that passes a place to an
  `out`/`inout` parameter and has a `?` or `await` in an argument, whether or
  not its arguments are written out of parameter order.
  `Lyric.Mono.desugarCheckedFile` then evaluates the other arguments into
  temporaries in source order and leaves the place in the call, so the call no
  longer has an argument either hoist moves, and the hoists never see the
  place. When the `?` fails (or the task is cancelled at the `await`), the
  arguments written before it have run and the callee has not, so the place is
  not written.
- The D171 rewrite now evaluates the index operands of a place it leaves in
  the call, a by-reference argument (`xs[i()]`) or a receiver that is a place
  (`accs[i()].mix(b = ..., a = ...)`), into temporaries at the place's
  position, so each runs once and in source order. Before, `accs[i()]`'s index
  ran after the reordered arguments.
- An operand bound to a temporary keeps the type its position expects: a
  bracket literal passed where a `List[T]` is expected is recorded at that
  list type (`recordHoistOperandTypeOver`), so its temporary is a list, not
  an array read as one. This crashed on dotnet (`InvalidCastException`) and
  the JVM (`VerifyError`) through the D171 named-argument rewrite and the
  `?`/`await` hoist before this change too. The hoist no longer binds a
  lambda to a temporary (an unannotated local lost its function type on
  native). A call recorded only for a by-reference place beside a `?` or
  `await` binds no argument after the last one holding the hazard or the
  last by-reference place with a computed index, whichever is later, so
  `f3(ok()?, note(), cells[at()].v)` still runs `ok`, `note`, `at` in that
  order (the JVM had run `at` before `note`).
- Affected hoists: the `?` hoist and the `await` hoist (one engine). Not
  affected: the `.copy` lowering (its receiver and arguments are never passed
  by reference) and the backends, which only pair arguments and keep no
  temporaries of their own; the D171 rewrite already left by-reference places
  in the call.
- Tests: thirteen cases in `named_arg_eval_order_self_test.l` (dotnet, JVM,
  native): an `inout` variable, an `out` variable and a field before `?`, a
  named `inout` argument on either side of a `?`, a computed, a variable and
  an indexed receiver, the failing-`?` path for a positional and a reordered
  call, an `inout` variable and field before `await`, and a receiver element's
  index under a reordered call, a list literal after a `?` and in a
  reordered call, and `newList()`, `None`, lambdas, slice literals and an
  `Int` widened to `Long` bound before a `?` or `await`, an indexed place
  after a `?` and a later argument, and an argument after a `?` that reads
  the place the `?`'s call changed.
- Not covered: an array element passed as an `out`/`inout` argument
  (`zap(arr[i], v)`) is accepted by the type checker but no backend lowers it
  yet, independent of `?`; `self: inout` receivers are accepted but do not
  write back.
