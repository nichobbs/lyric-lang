# A package-qualified or alias-qualified callee records its callee (docs/70 phase 3a, #8613)

**Status:** shipped; checker.

## Context

`Core.unwrapOr[Int](o, 5)` (a package-qualified callee under explicit type arguments) and `Buf.fromSlice(xs)` with `import Std.Buffer as Buf` (an alias-qualified call) recorded no callee: the explicit-type-argument arm of `recordCalleeSite` knew only a one-segment name, and the member arm read a one-segment uppercase qualifier as the type of a dot-named function (`Buf.fromSlice` as `Type.f`), so the TIR gate (D347) stopped the bodies (`explicit_type_args_checked_self_test.l`, `lyric-game/tests/audio_tests.l`).

## Decision

A callee `Q.f` or `Q.f[A]` whose qualifier `Q` is an import alias, or whose package path is the one `f` is declared in, records the function declared at the signature's span (`symTableQualifiedFuncDefPathKey`), whatever path names it (a `pub use` facade included). It is found by its declaration, never by name or arity, so a path that names no such function records nothing, as before.

## Results

`tir-builder-shapes-e2e.sh` (`qualified_generic_and_alias_calls`).
