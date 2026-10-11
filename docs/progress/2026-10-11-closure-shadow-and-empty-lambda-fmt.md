# A nested binding shadowing a closure-captured `var`, and `lyric fmt` on `{ () -> e }` (#8200, #8201, #8202)

**#8201.** On `--target dotnet` and `--target jvm`, a nested block that
declared a `var` of the same name as an enclosing `var`, where a lambda read
either of them, crashed codegen:

```
var x = 1
val f = { -> x }
if c {
  var x = 100
  x = 5
}
```

`error[T0120]: MSIL codegen failed: An item with the same key has already been
added. Key: x` (`J008` on the JVM).  A nested `val`, `for` or match-arm binding
of the name did not crash but was miscompiled: every read of it loaded the
enclosing `var`'s heap cell, so `val x = 100; x` gave 1.

Root cause: a `var` that any lambda in the function reads is hoisted to a
one-element heap cell, and both backends kept the name-to-cell map
(`hoistedCellSlot`/`hoistedCellType`) for the whole function.  Reads and
writes consult that map before the slot map, and #5191's block-scope undo log
restored only the slot map.  Now a new binding of a name hides the enclosing
cell and the undo log brings it back when the block ends: MSIL logs a `"cell"`
entry (`hideHoistedCellMsil`, `finishHoistedCellMsil`), and the JVM's
`ScopeUndo` carries the prior cell.  On MSIL the `mutableLocals` list, which
backs the "captured `var` was not hoisted" internal check, is scoped the same
way (`"mut"` entries), so a shadowing `val` captured by a lambda no longer
trips that check on its enclosing `var`'s name.  Native captures a value and
was already correct.

The same name-keying broke dotnet `async` functions across a real suspension.
The async state machine kept each local in a field named `__local_<name>`, so
a nested binding and the enclosing one of the same name shared one field (even
at different types, an `int[]` cell and an `Int`) and a resume reloaded only
the first binding's slot.  A plain nested shadow with no lambda already came
back wrong before this change (`var x = 1; if c { var x = 10; await …; x = x
+ 5 }; await …; x + 2` gave 507 for 1503); with the cell fix the captured
shapes would have joined it silently instead of failing to compile.  Promoted
locals are now keyed by IL slot (`slotAwaitFieldKeyMsil`, already used for
`for` and `match` bindings) in `phaseBRegisterAndSyncLocal` and
`phaseBSyncLocalIfPromoted`; the field-row prediction (`countPromotedLocalsStmt`)
counts every binding instead of every distinct name (and now walks an
assignment's target, whose element index can hold the array bounds check's
binding), and
`rollbackFuncCtxSlotsSinceMsil` drops the fields of the slots it discards.
The JVM and native were already correct.

Tests: `lyric-compiler/lyric/closure_shadow_self_test.l` (15 cases: the
issue's two repros, a captured shadow of a captured `var`, a `val` shadow read
directly and through a lambda, sibling and two-level nesting, a loop body, `for`
and match-arm bindings, a shadow of another type, a write to the enclosing
`var` after the block, and five cases that suspend for real inside or after a
shadowing block, plain and captured), on all three targets: `compiler-self-tests-batch.sh`,
`jvm-generics-self-tests-batch.sh`, `native-backend-self-tests.sh`, and
`ilverify-selfhosted.sh`.

**#8200.** `lyric fmt` refused every file with a brace lambda whose parameter
list was an empty `()`, `{ () -> e }` (`lyric-stdlib/tests/core_tests.l`
among them): the parser reads it as the same parameterless `ELambda` as
`{ -> e }`, the formatter writes `{ -> e }`, and the loss-check flagged the
dropped `(` `)`.  `{ -> e }` is now the canonical spelling and the loss-check
(`codeTokens` in `fmt/fmt.l`) ignores an empty `()` directly between a `{` and
a `->`; a paren-arrow lambda `() -> e` and a non-empty parameter list still
compare token by token.  Documented in docs/01 §"Canonical style rules".
Tests: two `fmt_self_test.l` cases.

**#8202** was fixed by #8290 (`Lyric.SelfFields`): a lambda in a protected
`entry` or a record method reads a field by its bare name when it runs, on all
three targets.  `member_local_shadow_self_test.l` covered the protected entry;
it now also covers the record method (`Live.readLater`).
