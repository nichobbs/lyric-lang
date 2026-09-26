# D-progress-990 — Literal module vals are registered in the MSIL pre-pass

**Status:** shipped

On MSIL, a module-level `val` whose initializer is an `Int`-sized literal is
inlined as `ldc.i4` at each use instead of being read from a field. Its value
reached `cctx.constValues` only when the declaring package was code-generated.
A non-literal `val`, by contrast, gets its field token in the
`addPackageTokens` pre-pass, which covers every package before any is
code-generated.

A bundle code-generates packages in list order. So a package listed before
the one declaring a literal `val` (for example, a `lyric test --manifest`
test package ahead of the library it imports) found neither a constant nor a
field. It failed with T0115 ("cannot resolve name").

D-progress-985 (#7346) made this visible. The pipeline now folds `-N` into a
single literal, so lyric-jsonrpc's `pub val methodNotFound: Int = -32601`
became a literal and its test suite stopped compiling. Positive literals had
the same failure all along.

## Fix

- The pre-pass registers each literal val's value under the `Pkg/name` and
  `Pkg.name` keys. It registers the bare name only when this package claimed
  it: the first package to declare the name, the same first-wins rule
  emission applies.
- `constBareClaimed` records the claiming package, not just that the name
  is claimed. Emission then suppresses the `.cctor` initializer exactly when
  the pre-pass predicted it would. Before, emission tested "is the bare key
  already present", which the pre-pass registration would now make true for
  the owner too.
- Contract metadata carries negative constants: `isIntLiteralExpr` accepts
  `-N`, and `renderConstExpr` keeps the sign. A consumer that re-parses
  `-N` from the synthesised source folds it in `foldConstInitToInt` instead
  of reading only the `ldc`, which would have inlined `N`.
- A consumer inlines a restored constant as an `Int`, so a literal outside
  `Int` range (`pub val big: Long = -5000000000`) is left out of the
  contract; a consumer naming it fails to resolve instead of reading a
  truncated value. `foldConstInitToInt` refuses such a value from an older
  package rather than truncate it (#7403).

## Tests

`msil_project_bridge_self_test.l` has a new case: an app package listed
before its library reads a negative and a positive literal `val`, both
bare and qualified. `contract_meta_self_test.l` checks that out-of-range
literal `val`s and `const`s stay out of the contract. The lyric-jsonrpc suite passes again.
