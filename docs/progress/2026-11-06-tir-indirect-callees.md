# 2026-11-06 - Calls through function values are marked indirect (D364)

`SymbolTable.indirectByNode` marks calls whose callee is a function value, and
the `Result`/`Option` accessors and an integer's bitwise methods record their
built-in name. The census over the stdlib tests now lists interface, extern and
host members only (plus a few computed callees). `tir_build_self_test.l` has an
indirect-call case and a bitwise-method case (14 cases); the two cases that
expected a function-value call to stay uncovered now expect it covered.
