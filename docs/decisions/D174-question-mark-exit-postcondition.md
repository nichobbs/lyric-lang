# D174 — `lyric prove` checks the postcondition on the `?` exit

**Status:** accepted, implemented (#8108)

## Context

The `?` operator returns early from a function with the callee's `Err` or
`None` (docs/01 §4.5). `Lyric.Propagate` lowers that exit after the
contract elaborator has rewritten the function's `ensures:` into runtime
checks, so the runtime does not evaluate the postcondition there, and
docs/01 (the `ensures` entry of the contracts section) says so, advising
postconditions of `Result`/`Option`-returning functions in the
`result.isOk implies ...` form.

The verifier, however, reasons about calls with the callee's contract: at
every call it assumes the callee's `ensures:` of whatever value the call
returns. If a proof could leave the `?` exit unchecked, a caller could
assume a postcondition the callee does not establish on that path, and a
property proved of the caller would not hold of the program.

## Decision

1. `lyric prove` requires a function's `ensures:` to hold on the early exit
   a `?` takes, for the value it returns there (`Err(e.error)` or `None` at
   the function's result type), in the state at that point, exactly as on
   any `return`.
2. The runtime is unchanged: the `?` exit still does not evaluate the
   postcondition.
3. A postcondition written as docs/01 advises (`result.isOk implies ...`,
   `result.isSome implies ...`) holds on that exit trivially, so it
   satisfies both the runtime rule and the proof. A postcondition that
   constrains every result, such as `ensures: result.isOk`, is refuted when
   the function contains a `?` that can fail.

## Consequences

- docs/01 states that `lyric prove` checks the postcondition statically on
  the `?` exit.
- docs/15 §5.4 describes the path split; the verifier models `Result` and
  `Option` as SMT datatypes for it (#8108). They are the standard library's
  only where no other type of that name can be in the file's package, and
  the package is the build's file set. A single-file proof holds for a
  standalone build of the file and for the builds its ancestor manifests
  define. It does not see a manifest outside the file's tree that lists
  the file, and it does not resolve symbolic links or filename
  normalisation; prove such a package with `--manifest`, which warns
  about an entry file outside the manifest's tree.
- Runtime-checked and proof-required code can differ on a postcondition
  that is false only on a `?` exit: the program runs without a
  `PostconditionViolated`, and `lyric prove` reports the goal as failed.
  The proof is the stronger guarantee, and the advised form avoids the
  difference.
