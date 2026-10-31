# D300 - A name a file does not import is an error (docs/70 phase 2a, #8612)

**Status:** shipped. Completes docs/70 §13 phase 2a (D267, §4.1), except
retiring B0012 and the cross-file T0148 (#8690).

## Context

D267 decided that imports belong to the file that writes them (docs/70
§4.1). Phase 2a reached that in steps, each released on its own so the
compiler, the stdlib, the ecosystem and users could move with it:

1. Positions name their file (`Position.fileId`), and every file is lexed at
   its own offset base, so offsets stay unique across a package (#8650).
2. A package is assembled from its files' own parses
   (`Lyric.PackageMerge.assemblePackageFiles`), and the text merge and its
   line-origin table are deleted (#8650, #8660). Each file parses on its
   own and its diagnostics carry its own path and line.
3. Each file gets its own import rule, every item is checked in the scope
   of its file, and aliases and renames rewrite per file (#8676). Names
   still resolved through the union of the files' imports, and a name a
   file saw only through a sibling's import was the warning `W0032`. The
   seven uses it found, all in the compiler, were fixed in the same change.

## Decision

1. **A name a file sees only through a sibling's import is the error
   T0219.** The message names the sibling file and the import to add:
   `'joinList' is not imported by this file; only `import Std.String as Str`
   in src/format.l makes it visible, and a file's imports are its own: add
   `import Std.String as Str` to this file`. It is reported once per name and
   file, for bare names, calls, constructors and cases, types, qualified
   references, aliases, renames and `import extern` names. `W0032` is
   retired.
2. **The candidates for a bare name stay the union's.** The per-file rule
   adds T0219. It does not narrow resolution, so a sibling-only use still
   resolves and is reported once instead of as an unknown name followed by
   cascading errors. The alias rewriter does the same for aliases and
   renames only a sibling binds. Narrowing was tried and reverted: with
   `Std.String.join` imported in one file and `Std.Path.join` in another,
   the checker accepted both files, but the MSIL and JVM backends resolve
   a bare call across the package and called `Std.String.join` from the
   second file, which crashed at run time. A bare name two files import from
   different packages therefore stays T0123, whose message now says that
   the files import the packages, until the backends receive resolved
   symbols (docs/70 2d, #8690).
3. **B0012 and the cross-file T0148 stay too, tracked in #8690.** docs/70
   §4.1 retires both, but an audit of the passes after the per-file rule
   found several that still read aliases and renames from the union of the
   files' imports, first or last match winning:
   - plugin expansion and component glue, before the alias rewrite;
   - the MSIL alias fallback for calls that survive the rewrite;
   - the JVM's renamed-constructor and selective-import maps;
   - the weaver's A0047 lookup;
   - the alias rewriter's environment for synthesised items.

   With either restriction lifted they could pick the wrong package without
   a diagnostic. Both stay errors until those passes read each file's own
   imports (or are folded into `Lyric.Resolve`, phase 2c). Their messages
   now give that reason rather than a shared import scope.
4. **Synthesised items keep the union.** An item with no source position
   (a derive's or the weaver's output) is checked against the union of the
   files' imports, as before.

## Behaviour changes in phase 2a

- A file that relied on a sibling's import no longer builds (T0219); in the
  previous release this was the warning W0032.
- Each file of a package must parse on its own, and its diagnostics name
  its own path and line (#8650, #8660).
- An implicit tail alias that two files bind to different packages
  rewrites each file's uses to that file's own package (#8676).
- A bad selective import repeated in two files is reported once per file
  (#8676).

## Not changed

- The tiers of a bare name (the current package, then direct imports, then
  packages reached only through a whole import's own imports, D141) still
  use the union's set of direct imports when two candidates the file sees
  differ only in tier. Phase 2c's resolver (`Lyric.Resolve`) replaces the
  tiers with the rules of docs/70 §4.3-§4.4 and removes D141's transitive
  rule.
- Every declaration of a package is visible in all of its files; a
  file-private tier stays deferred (Q-TIR-004).

## Verification

`typechecker_self_test` (per-file scope cases, including same-named imports
in two files), `package_merge_self_test`, `source_path_diagnostics_self_test`
(T0219 through real dotnet and JVM builds),
`scripts/ci/multi-file-package-merge-e2e.sh` (on each target: a sibling-only
name is T0219, same-named imports in two files are T0123, an alias bound two
ways is B0012) and the stage-2 bootstrap.
