# D886 - A `return` of a value whose type implements the declared interface result is built as an upcast

**Status:** accepted, implemented in the TIR builder and the contracts census output (docs/70 phase 3c, §6.3, §7.2; found by the wide census)

## Decision

1. **`return v` in a function (not a lambda) whose declared result is an interface `v`'s type implements builds `v` as `XConvert(CvUpcast(iface), v)`.** The tail of a body already carried the upcast; a `return` statement did not, so a function such as `func staticFiles(cfg): Middleware requires: ... { return StaticFileMiddleware(cfg = cfg) }` returned a node typed as the record. The contracts pass binds a returned value to `__lyric_result_n` declared at the function's result type, which then did not match its initialiser: `I0003 let-type: binding pattern: expected Middleware but found StaticFileMiddleware` (`staticFiles`, `corsMiddleware`, `corsAnyOriginMiddleware` of `lyric-web`). Any other conversion keeps the returned value as built.
2. **The contracts census names the function and the symbols behind a diagnostic's ids**, as the builder census does, so a census count points at a declaration.

## Effect

`lyric-web`'s contracts census is 0 (it was 3). `tir_contracts_self_test.l` covers a precondition-bearing function returning a record as its interface.
