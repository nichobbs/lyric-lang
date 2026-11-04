# Typing the first non-callee silent TyError sites (#8613)

D342.

- `LYRIC_TYERR_CENSUS=1` instrumentation merged (off by default).
- Qualified calls of codegen builtins, universal method results (`toString`,
  `equals`, `hash`) and `Map`/`Set` `.count` get real types. Non-callee silent
  sites: 1,163 -> 386 (compiler and stdlib closure, stage 2).
