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
- **Legacy metadata.** A contract with no `reexports` key was written
  before D309, when D141 let every whole import reach consumers. It reads
  its whole imports as its re-exports, so a dependency built then, or a
  stdlib built by a seed that predates D309, keeps the reach it was built
  with. The emitters now always write the key, an empty list included, so
  a current contract is never read this way. When the stdlib is rebuilt
  from `Lyric.Stdlib.dll`'s metadata (an install with no source tree), a
  re-exported package renders as `pub use`, so the rebuilt `Std.Collections`
  still re-exports `Std.CollectionsHost`.
- The seed accepts the migrated sources. It reads `pub use` as an import
  and still applies D141, so no release is needed between the two steps.

## Verification

`typechecker_self_test`:
- the re-export cases: bare, type, chains, a selective import of a
  re-exported name, union cases, a qualified call, a qualified type;
- #7556's ambiguity, #7345's type receiver and #7371's T0128 restated over
  re-exports, with the import-only forms as T0020.

`contract_meta_self_test`: a contract without the key reads its whole
imports as re-exports; an empty list round-trips empty.

Also the compiler build and stage-2 bootstrap, and the census.
