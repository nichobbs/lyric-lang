# Verifier: vcgen.l split into focused files (#8160)

`lyric-compiler/lyric/verifier/vcgen.l` (about 10,000 lines) held every
soundness-critical walker. It is now a family of files in the same
`Lyric.Verifier` package, one per walker, so each can be audited on its own:

| File | Contents |
|---|---|
| `vcgen.l` | `VEnv`, sorts of type expressions, scopes, record sort helpers |
| `vcgen_calls.l` | resolved-call translation, contract unfolding |
| `vcgen_equality.l` | which terms `==` may compare, structural equality keys |
| `vcgen_callee.l` | computed, method and static callee resolution |
| `vcgen_arith.l` | width and overflow obligations, integer width inference |
| `vcgen_expr.l` | expression translation, value blocks, quantifiers, lambdas |
| `vcgen_match.l` | match arms, patterns, scope case facts |
| `vcgen_wp.l` | the weakest-precondition statement walk |
| `vcgen_sequence.l` | evaluation-order hoisting of `?` operands |
| `vcgen_loops.l` | assignments and `while` loops |
| `vcgen_effects.l` | effect analysis, havoc, environment updates |
| `vcgen_scan.l` | yield and propagate scans |
| `vcgen_goals.l` | goals for a function and protected members |
| `vcgen_register.l` | registering a file's declarations |
| `vcgen_file.l` | goals for a file and its package scope |
| `vcgen_methods.l` | record and `impl` methods, inherited clauses |
| `vcgen_contracts.l` | contract-call cycles, diagnostic de-duplication |
| `vcgen_monad.l` | `Result` and `Option` values |

The move is mechanical: the non-blank, non-header lines of the new files are
identical to the old file's, and `verifier_self_test.l` reports the same 218
results before and after.
