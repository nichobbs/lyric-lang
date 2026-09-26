# D-progress-986 — Labelled loops

**Status:** shipped

Closes #7349.

The language reference and `docs/grammar.ebnf` define `label: for|while|do`
with `break label` / `continue label`. The self-hosted compiler did not
parse the label prefix (`outer: while ...` was P0050), but it did parse
`break outer` and `continue outer`, and every backend ignored the label. A
labelled jump from an inner loop therefore compiled and silently left only
the innermost loop.

## Parser

In statement position, an identifier followed by `:` and `for`, `while` or
`do` is a loop label. The two-token lookahead means no other statement is
reinterpreted: `x: T` never starts a statement, and a label is only taken
when a loop keyword follows. The formatter already printed labels.

## Type checker

A new walk over each function body (`typechecker_labels.l`) keeps the stack
of enclosing loops:

- **T0130**: `break`/`continue` outside any loop, or a label that names no
  enclosing loop. Before this an unlabelled `break` outside a loop reached
  codegen: MSIL indexed an empty stack, the JVM emitted a `nop`, and native
  panicked.
- **T0131**: a loop reuses the label of a loop it is nested in. Rejecting
  the shadow keeps `break label` naming exactly one loop. Sibling loops may
  share a label.

A lambda body, a `defer` body and a `finally` block start with an empty
stack. None of them can transfer control to a loop outside it: a lambda is
a separate method, and on MSIL a branch out of a `finally` handler is
invalid IL.

## Backends

MSIL, JVM and native each already kept parallel per-loop stacks (break
target, continue target, and the try depth, defer depth or ARC scope depth
at loop entry). Each loop pushes exactly one entry, so a labelled loop
records its label against the stack depth just before it is lowered, and a
labelled jump uses that index instead of the top:

- **MSIL** uses the target loop's try depth to choose `leave` or `br`, so a
  jump out of a `try` or `defer` region runs the `finally`s in between.
- **JVM** replays the defers down to the target loop's entry depth, which
  runs the defers of every inner loop left as well.
- **Native** releases ARC scopes and runs defers down to the target loop's
  floors.

Native also gains the two loop forms the test needs, which it rejected with
a panic before: `do { }` and a counted range `for` (`lo ..< hi`,
`lo ..= hi`). The range loop evaluates both bounds once at entry, as the
MSIL and JVM counting loops do, and uses unsigned comparison for `Byte`
bounds (#4628).

A loop in a `defer` or lambda body may reuse an enclosing loop's label (the
checker starts those bodies with an empty stack). The backends keep one
label map per function, so entering such a loop saves the outer entry and
leaving it restores the entry rather than deleting it. Deleting it made a
later `break outer` in the enclosing loop panic the compiler (#7394).

The contract elaborator's loop-exit invariant walk (D-progress-981) already
treated `break label` inside a nested loop as leaving the labelled loop.
It now receives real labels.

## Tests

- `labelled_loops_self_test.l`, which runs on dotnet, JVM and native, has
  nine cases: `break`/`continue` to an outer `for`, `while` and `do` loop;
  three nesting levels; jumps from a `match` arm; defers on `break outer`
  and `continue outer`; and sibling label reuse.
- `typechecker_self_test.l` has eight cases for T0130 and T0131, including
  lambda and `defer` bodies.
- `loop_invariant_self_test.l` checks that `break outer` from a nested loop
  skips the outer loop's exit check.

## Docs

- Language reference, loop control: labels, `do`, T0130 and T0131.
- Book chapter 4 and appendix B.
