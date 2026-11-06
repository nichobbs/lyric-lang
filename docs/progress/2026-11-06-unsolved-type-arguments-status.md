# Unsolved type arguments: where docs/70 phase 3a stands (D380-D382)

The checker reports an unpinned type argument of a call and of a union-case
construction as T0224 (D335, D339, D381), reads every context that already
fixes one (D380), and `Lyric.Mono` no longer fills an unpinned type argument
with `Object` when it types a call's result (D382). What is left in #8760 is
the call rewriter's erased default for three named shapes and its T0224
backstop, which wait for the checker's callee table (D361) to cover qualified
and member callees, and for the expansions to carry type arguments.
