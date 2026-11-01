# D309 - `pub use` re-exports a package; D141's transitive reach is W0033 (docs/70 phase 2c, #8612)

**Status:** shipped. Step 1 of docs/70 §13 phase 2c: the source migration
and warning mode for §4.3's D141 change (§12.2).

## Context

D141 made a whole import reach every package the imported package itself
imports whole, bare and qualified. The stdlib's kernel/host idiom relied on
it (`Std.Collections` imports `Std.CollectionsHost`, which declares `List`
and `newList`). So did every file that used a name only an imported
package's own imports brought in. docs/70 §4.3 removes that reach in favour
of explicit re-exports.

Before this step, `pub use` was parsed, and for Lyric packages it behaved
as `import`. Only the extern form (`pub use extern`) had re-export
semantics.

## Decision

1. **`pub use P` re-exports the whole package `P`.**
   - It imports `P` as `import P` does.
   - A file that imports the re-exporting package whole sees `P`'s names
     bare, through any chain of re-exports.
   - A selective import of the re-exporting package lists them as well:
     `import Std.Collections.{newMap}` makes `Std.CollectionsHost`'s
     `newMap` visible.
   - A qualified name through it (`Coll.newList()`) resolves to the
     re-exported declaration (#7799).
   - `ImportedPackage.reexports` and the contract metadata key
     `reexports` carry it, so restored dependencies keep their re-exports.
   - The single-name form `pub use P.X` is not given these semantics yet.
2. **D141's other reach is the warning W0033.** W0033 fires in three
   cases:
   - a bare name visible only through a whole import that is not
     re-exported;
   - a qualified `X.y` that resolves to a declaration of a package `X`
     imports without re-exporting;
   - a qualified reference to a package the file reaches only through its
     imports' imports (a type path or pattern head).

   It is reported once per name and file (or package). The message names
   the first import on the chain that is not a re-export, and says what to
   add: the import of the declaring package, or `pub use` in the facade.
   A later step makes it an error and removes the reach.
3. **Migration.**
   - `Std.Collections` and `Std.Json` re-export their hosts: their public
     signatures expose the hosts' types.
   - Every other use got the import it relies on, or was qualified through
     an import the file already has.

   The census over the compiler, stdlib, every manifest in the repository
   and the single-file examples found 635 W0033 before the migration (609
   from `Std.Collections`) and 1 after.
4. **The one that remains.** `msil/codegen.l` reaches
   `Lyric.TypeChecker.stdListRecvKeyPrefix` through `Lyric.RestoredPackages`.
   Importing it selectively promotes every `Lyric.TypeChecker` name to the
   direct-import tier of bare lookups, in the checker and in the MSIL
   backend, so the file's bare `LocalBinding` binds to the wrong package.
   The tier rule is #8709. The resolver replaces it.
5. **Doctests.** The doctest module synthesised for a package copies a
   `pub use P` as `import P`. It used to drop it.

## Verification

`typechecker_self_test` covers:
- bare, type and qualified reach as W0033, and re-export, direct import and
  selective import as clean;
- the first non-re-export hop on a two-hop chain;
- a selective import of a re-exported name;
- a case of a union imported by name;
- updated #7799 and kernel/host idiom cases.

The census and the stage-2 bootstrap also pass.
