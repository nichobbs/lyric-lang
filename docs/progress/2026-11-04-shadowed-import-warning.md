# A declaration that shadows an import is W0037 (docs/70 phase 3a, #8767)

D350.

- `Lyric.Resolve.shadowedImports` (`resolve_shadow.l`) lists each top-level
  declaration of the package (function, type, module value) that hides a name
  of the same kind a file of the package imports directly (whole, or listed
  selectively); the checker reports it as **W0037** at the declaration, once per
  name. The rule stays (§4.3: the package's own declaration wins); the
  diagnostic only removes the silence #8767 found.
- Census over the compiler and stdlib closure (`./scripts/bootstrap.sh --stage 2`):
  26 declarations, e.g. `lexer.l` and `vcgen_arith.l` `maxInt` against
  `Std.Core`, `doc.l`'s `pathStr`/`typeStr` family against `Lyric.Fmt`,
  `typechecker_scope.l`'s `LocalBinding` against `Lyric.Parser`. They are left
  as warnings; renaming them is a follow-up, not part of this entry.
- Four `typechecker_self_test.l` cases that deliberately shadow an import now
  count errors, not diagnostics.
