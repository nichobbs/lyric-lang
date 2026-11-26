# An omitted default runs after every explicit argument on TIR (docs/70 phase 3c, #9430)

## What shipped

- The TIR call builder treats an omitted defaulted parameter that precedes an explicit argument as a reorder, so explicit arguments that are not plain are bound to temporaries in source order and the default thunk runs after them (D171). `mid(a = note("a", 1), b = note("b", 2))` over `func mid(a, d = note("d", 4), b)` now evaluates a, b, d, as the AST path does.
- `tir_build_self_test.l`: a call with an omitted default between two explicit arguments binds both to temporaries; a call whose arguments are plain binds none.
