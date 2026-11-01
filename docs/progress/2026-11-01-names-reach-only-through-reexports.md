# A whole import reaches only re-exports, docs/70 phase 2c step 2 (#8612)

D311.

- **Bare names:** `collectImportSets` widens a file's whole imports by each
  imported package's re-exports, no longer by its whole imports.
- **Qualified names:** `pkgReexportsFrom`, `packageReexportsMember` and
  `symTableImportReachable` follow re-exports (`symTableReexportClosure`).
  `qualifiedPkgReachable` accepts only a package the file imports.
- **Deleted:** W0033 and its bookkeeping (`transitiveOnly`,
  `transitiveFrom`, `noteTransitiveBare` and kin).
- **`Grpc` re-exports `Grpc.Types`** (`pub use`): its calls return
  `GrpcStatus`, which `examples/product-catalog` names through `import
  Grpc`. The step-1 census missed it because that example needs restored
  gRPC packages the census environment lacks.
- **The last W0033:** `stdListRecvKeyPrefix` (`Lyric.TypeChecker`) is
  replaced by `stdListRecvSiteKey` (`Lyric.Parser`), used by the checker
  and the MSIL backend.

Visible changes: a name reached only through an imported package's own
import is T0020 (T0010 for a type); a qualified type of a package the file
does not import is T0020.

Tests: `typechecker_self_test`'s re-export cases now expect errors for the
import-only forms; #7556, #7345, #7548 and #7371's cases are restated over
re-exports.

Docs: language reference §9.2, docs/70 (phase 2c status, §14), book chapter
6 and appendix B (W0033 retired).
