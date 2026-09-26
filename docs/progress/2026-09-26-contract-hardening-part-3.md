# Contract hardening, part 3: enforcement the language already promised (#7377)

Each item was a silent miscompile, a missing check, or a contract that was
declared but not enforced. The decision entries hold the detail.

- **Labelled loops** (D-progress-988, #7349). `label: for|while|do` with
  `break label` / `continue label` on MSIL, JVM and native, replaying the
  `defer`s of every loop left. The checker reports T0130 for a jump outside a
  loop or to an unknown label, and T0131 for a nested loop reusing a label.
  A loop in a `defer` or lambda body may reuse an enclosing label (#7394).
  Native gains `do` loops and range `for`.
- **Contract clauses** (D-progress-990, D-progress-985, #7228).
  - Clauses are type-checked and must be `Bool` (T0132).
  - A call inside a clause must resolve to a `@pure` signature (T0133).
    That covers functions, record, impl and protected `func` members, and
    purity survives package boundaries for functions and record methods.
  - A quantifier's conjunct is skipped soundly at runtime (W0002).
  - A quantifier outside a `requires:`/`ensures:`/`decreases:`/`invariant:`
    clause, including in a `when:` barrier, is P0344.
- **Loop invariants** (D-progress-983, #7224). Checked on normal loop exit,
  not on `break`. A `for` clause over the loop's own element is not
  re-checked after the loop. The verifier rejects a `break` rather than
  assuming the invariant after it.
- **Integers** (D-progress-984, #7346, #7350, #7382).
  - An unsuffixed literal above `Int` is a `Long`, and an out-of-range
    binding is T0015.
  - `-2147483648` and `-(2147483648)` fold to one literal.
  - Mixed-width arithmetic and ordering comparisons widen on every backend,
    zero-extending a `UInt`.
- **Range refinements** (D-progress-986, #7226, #7398). Inline refinements
  are checked at runtime wherever an assignment can appear.
- **Distinct types** (D-progress-991, #7361). Operators act on the
  underlying value on every target; compound assignment needs a path target
  (T0134).
- **Protected types** (D-progress-987, #7363, #7384, #7400).
  - Every `entry` and `func` holds the instance lock.
  - `when:` barriers work on entries and funcs on dotnet and the JVM, and
    every member notifies on exit.
  - An async or method-generic protected `func` is T0135.
- **MSIL literal `val`s** (D-progress-989, #7403). A literal `pub val` read
  by a package codegen'd before its own resolves. A literal outside `Int`
  stays out of the contract instead of being inlined truncated.
- **Stdlib** (D-progress-982, #7251, #7401).
  - HTTP, HTTP/2, TLS, process, random and property-test contracts, with
    zero process timeouts allowed.
  - XML character references are validated.
  - `Std.Json` getter preconditions, and `@generate(Json)` readers that
    return `Err` for a wrong-kind field.
  - `Std.Rest` path confinement that treats an encoded `/` as a separator.

Verification: the type checker, parser, formatter, contract-metadata and
verifier self-tests; new runtime suites on each target they cover; the
compiler self-test batch; ilverify (126 DLLs, 0 errors); every ecosystem
library; and the stdlib main-style tests.
