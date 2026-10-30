# A `?` that never yields a value lowers to a return (#8257); T0161 compares defaults semantically (#8100)

## #8257

`Err(error = x)?`, `None?` and an `if`/`match`/block whose branches all end in
one never produce a value; they always return. The `match` lowering gave the
result a type no path could fill, so reading a member of it
(`val s = None?` then `s.length`) was unverifiable on dotnet and rejected on
native (N0007). `Lyric.Propagate` (`propagate.l`: `staticDivergeStmts`,
`divergeFromExpr`, `divergeFromStmt`, `rewriteBlock`) now recognises such an
operand at the head of a statement (initializer, assignment value, return value,
expression statement; through the first-evaluated position of a tuple, list,
member receiver, index receiver, prefix/binary left operand or call argument)
and lowers the whole statement to the return, keeping the statements before it
and dropping the unreachable ones after it (nested item declarations stay). An
error that widens to the function's keeps its conversion
(`errReturnStmts`, shared with `buildResultMatch`). Operands the type checker
typed (`{ val __lyric_ho_n: T = e; __lyric_ho_n }`) are seen through.

Test: `propagate_never_value_self_test.l` (7 cases) passes on dotnet, JVM and
native; `propagate_ctor_operand_self_test`, `propagate_hoist_self_test` and
`propagate_ctor_operand_try_self_test` still pass. Registered in the CI lists
beside `propagate_ctor_operand_self_test.l`.

Not done: a checker warning for the dropped code (the issue's optional
follow-on).

## #8100 item 3

T0161 compared the canonical text of the two defaults. It now folds both to
integers with each name read in its declaring package (`1 + 1` equals `2`;
`tryFoldIntInPackage`), and otherwise requires equal text plus the same
resolved declaration for every name (`collectDefaultNameOrigins`), so two
packages' same-named constants differ. Test: `T0161 compares defaults by folded
value and resolved name (#8100)` in `typechecker_self_test.l`.
