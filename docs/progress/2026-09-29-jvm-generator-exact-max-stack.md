# JVM async generators: exact `run()` max_stack, dedicated demand token (#7745)

Two follow-ups to #7720 in `lowerAsyncGenerator`
(`lyric-compiler/jvm/lowering.l`).

## `run()` max_stack is the tracked peak, with no slack

`run()` set `max_stack` to `peakStack + 1` with a floor of 2. The `+ 1` and the
floor covered instructions that `trackStack` never saw: the demand wait before
the body, the `aload_0; swap; invokevirtual _yield` sequence after each boxed
yield value, the `_finish` call at `run_body_end`, and the `run_catch_all`
handler (the exception reference plus `this`). The untracked yield sequence
also never popped the boxed value from the tracked depth. Each yield therefore
left the simulated stack one slot too high until the next label, so a body
with code after a yield was over-counted as well as padded.

These sequences now go through `lowerInsn` (`LAload`, `LGetfield`,
`LInvokevirtual`, `LPop`, `LLabel`, `LReturn`). The one raw emitter left is
`swap`, which does not change the depth and only ever sees the one-slot boxed
value or the exception reference. The catch-all entry resets to depth 1 with
`resetStackToHandlerEntry`. `max_stack` is `bodyAsm.peakStack` verbatim.

The same audit tightened two hand-set constants: `_pullHasNext` from 4 to its
true peak of 3, and the standalone kickoff method (used only when `hostClass`
is set, i.e. `self_test_b129.l`) from a flat 4 to `2 + <argument slots>`. The
flat 4 under-counted a kickoff with more than one Long/Double parameter.

`run()` `max_stack` from `javap -v`, for generators built from one probe file.
Every class loads and runs under the default verifier.

| Generator | Before | After | True peak |
|---|---|---|---|
| `yield 1` (Int) | 2 | 2 | 2 |
| `yield "s"` (String) | 2 | 2 | 2 |
| `yield a * b + c` (Long params) | 5 | 4 | 4 |
| `yield c + a * b` (Long params) | 7 | 6 | 6 |
| `yield (a + b) * (a - b)` (Double) | 7 | 6 | 6 |
| `yield Pt(x = 1, y = 2)` (record) | 5 | 4 | 4 |
| yield inside `try`, handler, yield after | 5 | 3 | 3 |
| `if n > 100 { yield n }` | 3 | 2 | 2 |

## Dedicated demand token

`_pullHasNext` put `_DONE_SENTINEL` on `_demand` as its "produce one element"
token. The producer only discards what it takes from `_demand`, so the reuse
was harmless, but the two channels shared one marker object. A new
`_DEMAND_TOKEN` static, created in `<clinit>` next to the sentinel, is now the
demand token. `_DONE_SENTINEL` appears only on `_channel`.

## Tests

- `async_generator_self_test.l` has two new dual-target cases. The first
  yields computed Long values (`k * b + c` and `c + k * b`, with 64-bit
  operands). The second yields Double values from both branches of an `if`
  inside a `while`, including a call inside the yielded expression. The file
  passes 22/22 on `--target dotnet` and `--target jvm`.
- `generator_body_try_catch_jvm_self_test.l` has two new JVM-only cases: Long
  yields inside and after a `try`, and Double yields inside a `try` and its
  handler. It passes 4/4.
