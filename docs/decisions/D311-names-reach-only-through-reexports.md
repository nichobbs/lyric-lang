# D311 - A whole import reaches only re-exports; W0033 retired (docs/70 phase 2c step 2, #8612)

**Status:** shipped. Step 2 of docs/70 §13 phase 2c, which switches §4.3's
D141 change on after the step-1 migration (D309).

## Decision

1. **A whole import reaches what the imported package re-exports, and
   nothing it merely imports.** `import Money` makes visible `Money`'s names
   and those of each package `Money` re-exports (`pub use`), transitively.
   A name a file could reach only through another package's import is
   T0020, or T0010 in type position. The existing hint names the declaring
   package to import.
2. **A qualified reference through a package resolves only to what it
   declares or re-exports.** #7799's `Coll.newList()` follows
   `Std.Collections`' `pub use Std.CollectionsHost`. A callee in a package
   the qualifier only imports is not found. `packageReexportsMember` and
   `pkgReexportsFrom` follow `symTableReexportClosure`.
3. **Only a package the file imports can be named.** A qualified type path
   or pattern head (`Lib.Rest.Widget`) needs an import of `Lib.Rest`. Being
   imported or re-exported by an imported package is not enough
   (`qualifiedPkgReachable`). `symTableImportReachable`, the check for a
   bare type receiver, follows the file's own imports and their re-exports.
4. **W0033 is retired**, along with its transitive-only bookkeeping.
5. **The last W0033.** `msil/codegen.l` used
   `Lyric.TypeChecker.stdListRecvKeyPrefix`, reached through
   `Lyric.RestoredPackages`. It is replaced by `stdListRecvSiteKey(sp)` in
   `Lyric.Parser`, beside the other site keys the checker and the backends
   share. That avoids the import whose tier side effect is #8709.

## Consequences

- Code that relied on D141's reach fails to compile. The census in D309
  migrated everything in the repository. The step-2 census shows the same
  manifests failing as before, all for reasons unrelated to imports.
- A restored dependency built before D309 has no `reexports` in its
  contract metadata, so a consumer reaches nothing through it beyond its
  own declarations.
- The seed accepts the migrated sources. It reads `pub use` as an import
  and still applies D141, so no release is needed between the two steps.

## Verification

`typechecker_self_test`:
- the re-export cases: bare, type, chains, a selective import of a
  re-exported name, union cases, a qualified call, a qualified type;
- #7556's ambiguity, #7345's type receiver and #7371's T0128 restated over
  re-exports, with the import-only forms as T0020.

Also the compiler build and stage-2 bootstrap, and the census.
