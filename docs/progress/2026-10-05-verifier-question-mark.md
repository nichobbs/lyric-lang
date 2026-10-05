# Verifier: `?` splits the path, and `Result`/`Option` are modelled (#8108)

`lyric prove` translated `val x = g()?` as an unconstrained success value,
so the early return `?` introduces was never checked against the
function's `ensures:`: `ensures: result.isOk` with a `?` in the body was
proved. `.isOk`, `.value` and the other `Result`/`Option` accessors were
not modelled either, so every postcondition that used them failed closed.

- **`Result[T, E]` and `Option[T]`** are SMT datatypes (`Lyric!Result`,
  `Lyric!Option`, declared in the query preamble) — only the standard
  library's: a type of that name the file or another file of its package
  declares, the file imports by name, or it may import through a
  whole-package import outside `Std.*` is an ordinary uninterpreted type,
  and generic types are now declared as uninterpreted sorts of their arity.
  `lyric prove --manifest` passes each file its package's type names across
  all its files; `lyric prove <file>` and the LSP read the sibling `.l`
  files declaring the same package, and a sibling that cannot be read or
  parsed, or a caller with no scope, counts both names as declared.
  `scripts/ci/prove-package-scope.sh` (CI, with
  `examples/prove-package-scope/`) checks both modes. `Ok`, `Err`, `Some` and
  `None` take their type where they meet a typed slot (a return, an
  annotated binding, an argument, the other operand of `==`, both branches
  of an `if`), positionally or with their field named (`Ok(value = v)`);
  a value of another sort at such a slot fails closed. `.isOk`, `.isErr`, `.isSome`, `.isNone` and the
  `isOk(r)`-style calls are case tests; `.value` and `.error` read the
  payload, with the obligation that the value is that case.
- **`?` splits the path** where it runs. On the `Err`/`None` path the
  function returns `Err(e.error)` or `None` at its own result type, as
  `Lyric.Propagate` lowers it, and its postcondition must hold for that
  result: a caller assumes the postcondition of every value a function
  returns, though the runtime does not check it on this exit (D172). On the other path the binding is the payload, and the callee's
  `ensures:` about it (`result.isOk implies result.value > 0`) is a fact
  for the postcondition. Side goals (a later `requires:`, an `assert`)
  still see no earlier facts; that is #8103 item 1.
- **Evaluation order**: a statement's `?`s are first given bindings of
  their own in evaluation order, and everything evaluated before a `?` is
  bound before it, so a precondition or an `out`/`inout` change before a
  `?` is checked on both paths and one after it only on the success path.
  This covers bindings, expression statements, assignments, `return`, a
  statement `if`'s condition and branches, `assert`, and call arguments,
  receivers and operands. An `out`/`inout` argument or a receiver before a
  `?` stays the variable itself, so the call's write lands on it; one that
  an operand hoisted ahead of the call changes fails closed. (The compiler
  copies such an argument today; that miscompile is tracked separately.)
- **Argument order (D171)**: arguments are translated as written, named
  and positional alike, and pass to the parameters by
  `Lyric.Parser.pairCallArgs`; the interim V0033 for named arguments
  written out of parameter order with an `out`/`inout` effect (#8107) is
  gone, and a `?` among such arguments splits like any other.
- **Fails closed**: a `?` that runs only conditionally within its
  statement (an `if`/`match` expression's branch, the right operand of
  `and`/`or`/`implies`/`??`, a lambda, a block used as a value), on a
  value not known to be a `Result`/`Option` (an unresolved callee), or
  whose error type differs from the function's is V0033; in a loop body or
  condition it stays V0026.

Verified by `lyric-compiler/lyric/verifier_self_test.l` (152 tests; new
refute and discharge cases for the error path, the success payload, an
`Option`, each statement form, argument order and every fail-closed case),
the CI `lyric prove` examples and `core_proof.l`, the earlier review repros
(no regression), and the compiler self-test batch (3419 tests).
