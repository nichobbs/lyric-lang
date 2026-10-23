# Type-checker diagnostics batch (#8249, #7916, #7978, #8334, #8039, #8005, #8018, #7974, #8244, #7983, #7810, #7804)

The self-hosted type checker accepted several invalid programs that then
failed in a backend or at run time. This batch closes those holes. Every new
test was run against the unfixed compiler first and failed there.

New diagnostics (documented in `docs/01` and the book's appendix B):

- **T0195**: the operand of `?` is neither a `Result` nor an `Option` (an
  `Int`, a record, or a block `{ Ok(value = 1) }`, which is a lambda).
- **T0196**: a `match` arm that no value reaches: it follows an unguarded
  catch-all, or names a case earlier unguarded arms already match whole. A
  bare capitalised name below the scrutinee's own cases is not taken for a
  binding, so `Some(VInteger)` is a constructor test.
- **T0197**: a member read on a value of a type parameter of the enclosing
  generic. A field declared as the record's own type parameter and read
  through an instance at the enclosing generic's `T` is now that `T`
  (`eraseTyVars` used to turn it into an unknown type), so `b.value.zork`
  is reported.
- **T0198**: a tuple pattern in a `match` arm with the wrong element count.
- **T0199**: a string-literal `format1`..`format4` template that
  `Std.String.formatArgs` would reject at run time. The checker and
  `formatArgs` share one scanner, the new public `Std.String.formatTemplateProblem`,
  so they cannot drift.

Other behaviour changes:

- A generic's type parameter is rigid in a binding, an assignment, a return, a
  call argument and a stdlib collection member argument: `T` is only a `T`
  (or something an interface bound can satisfy). `typeEquiv` itself still
  treats a `TyVar` as a wildcard, because the same representation stands for a
  callee's instantiation variable; the rigid check (`rigidVarClash`) runs where
  the enclosing generic's names are known (#7974).
- `List`/`Map`/`Set` members: argument count is checked (T0042) and the
  `contains`, `containsKey`, `indexOf` and `lastIndexOf` results are typed
  (#7978).
- The bitwise methods `.and/.or/.xor/.shl/.shr` of an integer are typed (#8334).
- A name repeated after a positional argument that already supplies it is
  reported once (#8039); a positional constructor argument after a named one
  fills the next free field instead of the first (#8005).
- A single file carrying both `@pure` and `@io` is `Y0009` without a
  `[layers]` table (#8244).
- A local `val` constructor pattern gets a `match` arm's privacy and
  reachability checks, and a record head naming no record says so (#7810).

Found already fixed on main and covered by new regression tests or checked by
hand: #7777 (module val initialisers, except the JVM `J008` part), #7786
items 1 and 2, #7804 item 1, #8161, #8104 item 1, #8332 (the `if` condition;
the invariant quantifier body is the contracts group's), #7639 (a multi-file
package is merged before the check, so T0139 fires across files).

Left open with notes on the issues: #7099/#7204 (the unknown-`String`-method
error is today a codegen error on each target; a target-aware check is a
design question), #7218 (`.length` on a `List` is used in the compiler's own
sources, so the check needs a repository-wide audit first), #7996/#8017
(operators on a bounded type parameter need monomorphisation-time lowering in
`Lyric.Mono`), #7809, #8257, #8047, #8100, #8104 items 2 and 3, #7786 item 3.
