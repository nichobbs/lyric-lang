# D364 - Calls through function values are marked indirect; monad accessors and bitwise methods record their name (docs/70 phase 3a, #8613)

**Status:** shipped. Extends D361 (declared callees), D362 and D363 (built-in names).

## Context

After D363 the `LYRIC_VERIFY_IR=1` census over the stdlib tests still listed
calls through bare function values (`square(x)`, a parameter `pred`), the
reserved accessors of `Result` and `Option` (`isErr`, `isNone`), and the bitwise
methods of an integer. TIR names the first `Callee.Indirect(fnValue)`, the others
`Callee.Intrinsic(IoBuiltin(name))`.

## Decision

1. `SymbolTable.indirectByNode: Map[Int, Bool]` marks a call whose callee is a
   function value (`calleeIsFuncValue`: a local, a module-level `val`, a
   function-typed field, or any other expression). It holds no callee: the
   builder takes the function value from the callee expression, which is already
   a typed expression of the file. The mark is set where the call is checked
   against the function type, and not for a call already recorded as a built-in.
2. `isOk`/`isErr`/`isSome`/`isNone` (and the other reserved accessors) typed
   through the untyped-member fallback, and the bitwise methods of an integer
   (`.and/.or/.xor/.shl/.shr`, which return before the general call path),
   record `Receiver.member` in `builtinByNode`.
3. `callCovered` counts a call covered by `calleeByNode`, `builtinByNode` or
   `indirectByNode`.

## Not covered

Interface and extern member calls, channel and HTTP-style host members
(`.get`, `.send`, `.post`), the
instantiation, conversion and argument-order tables and the expression builder.
The `Result`/`Option` accessor route and a dependency union case are checked
through the census on real code, because the self-test harness checks single
files without the stdlib.
