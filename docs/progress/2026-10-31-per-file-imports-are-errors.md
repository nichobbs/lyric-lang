# A name a file does not import is an error: T0219, docs/70 phase 2a (#8612)

The last step of docs/70 phase 2a (D300). A file's imports now decide what
the file may name.

- **T0219 replaces W0032.** A name a file sees only through a sibling
  file's import is an error. The message names the sibling's path and the
  import to add. It is reported once per name and file by the type checker
  (`symTableNoteBareUse` and kin) and by `Lyric.AliasRewriter`
  (`reportSiblingUses`) for an alias or rename only a sibling binds.
- **Candidates stay the union's.** A sibling-only use still resolves, so it
  is one T0219 rather than an unknown name followed by cascading errors.
  Narrowing bare names to the file's own imports was tried and reverted.
  `Std.String.join` in one file and `Std.Path.join` in another passed the
  checker, but the backends resolve bare calls package-wide and crashed at
  run time. Such a name stays T0123; its message now says the files of the
  package import the packages.
- **B0012 and the cross-file T0148 stay (#8690).** An audit found passes
  that still read aliases and renames from the union of the files' imports:
  - plugin expansion and component glue, before the rewrite;
  - the MSIL alias fallback;
  - the JVM rename maps;
  - the weaver's A0047 lookup;
  - the rewriter's environment for synthesised items.

  Both restrictions remain errors until those passes read each file's own
  imports. Their messages now say so instead of citing a shared import
  scope.
- **`AliasEnv`** keeps the entries only a sibling binds as `SiblingEntry`
  records, and the rewrites through them as `SiblingUse` records. This
  replaces five parallel lists (review suggestion on #8676).

Visible changes:
- A file that relied on a sibling's import fails with T0219 (the warning
  W0032 in the previous release).

Tests:
- `typechecker_self_test`: the per-file cases now expect T0219, with a new
  case for same-named imports in two files (T0123).
- `source_path_diagnostics_self_test`: T0219 through real dotnet and JVM
  builds.
- `multi-file-package-merge-e2e.sh`: on each target, a sibling-only name
  is T0219 and `Std.String.join` in one file with `Std.Path.join` in
  another is T0123.

Docs: language reference §9.2, docs/19 (header, §4 step 2), docs/70 (phase
2a status, §14), the docs/10 status row, book chapter 6 and appendix B.

Next in docs/70: #8690, then phase 2b (`DefPath`, `SymbolId`, `LocalId`)
and 2c (`Lyric.Resolve`).
