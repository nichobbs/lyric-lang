# D604 - The conformance suites are their own package, `lyric-conformance` (#9090)

**Status:** accepted; shipped.

## Context

The conformance suites (`Testing.Conformance` and one suite per interface,
D552) were packages of `lyric-testing`, beside the mocks. The mocks cover
every interface, so `lyric-testing` depends on every interface package,
`lyric-db` and `lyric-mail` among them. Those two have backends on `dotnet`
and the JVM only. A native build compiles every package of every dependency,
so no backend could run a conformance suite on `--target native`, even one
whose own interface package builds there (`lyric-cache`, `lyric-mq`,
`lyric-session`, `lyric-feature-flags`).

Two more things stood in the way once that was out of it: `runCase` catches a
panicking backend with `try`, which native does not have (D-N-003), and
`lyric-jobs` and `lyric-storage` took their host primitives from kernels that
exist for `dotnet` and the JVM only.

## Decision

1. **`lyric-conformance` (`Lyric.Conformance`) holds the suites.** The module
   names do not change (`Testing.Conformance`, `Testing.Conformance.Cache`,
   `.Flags`, `.Session`, `.Mq`, `.Storage`, `.Jobs`, `.Search`), so imports
   stay as they are; a package that used the suites declares
   `"Lyric.Conformance"` where it declared `"Lyric.Testing"`. It depends only
   on the interface packages, each of which builds for every target.
2. **`lyric-testing` keeps the mocks and depends on `lyric-conformance`.**
   `TestContext` and every mock keep their names and shapes. Its conformance
   tests run the suites against the mocks and hold the negative cases that
   need a caught panic.
3. **A package says which targets it supports (D603).** `lyric-db` and
   `lyric-mail` declare `targets = ["dotnet", "jvm"]`, `lyric-testing`
   `["dotnet"]` (its `Testing` package does not compile for the JVM, J002 in
   `MockMessageQueue`, before and after this change). A native build that
   reaches one stops with `F0054`/`F0055` instead of an unknown name inside
   the dependency.
4. **What only the managed targets can do is one small file per library.**
   Catching a panic is the only such thing here. `Testing.Conformance.Guard`
   (a case), `Jobs.Kernel.Guard` (a job handler attempt) and `Storage.Port`
   (every host call of the local filesystem backend) are each one package in
   two files, gated `@cfg(not(target = "native"))` and
   `@cfg(target = "native")`, the shape `Ui.Kernel.Guard` already has. The
   rest of each library has no `try` and is the same code on every target.
5. **On native a panic is not a result.** A panicking conformance case or job
   handler ends the process there. Failed expectations are still collected
   and reported together.

## Alternatives

- **Move `MockDbConnection` and `MockMailSender` out of `lyric-testing`.**
  `TestContext` carries both as fields and is `@stable`; every user of the
  mocks would have to change code. Moving the suites changes one line of a
  manifest and only for the packages that run a suite.
- **Give `lyric-db` and `lyric-mail` a native build without a backend.** A
  package that compiles for a target on which nothing it offers can work is
  what D552 and D603 removed.
- **A feature that leaves the Db and mail mocks out.** A dependency cannot be
  made optional by a feature today, and a record field (`TestContext.db`)
  cannot be gated.

## Consequences

- An out-of-tree backend adds `"Lyric.Conformance"` to its dependencies (and
  its workspace overrides) when it moves to a compiler with this change. A
  backend that also uses the mocks keeps `"Lyric.Testing"` for them, on
  `dotnet`.
- `lyric publish` order: `lyric-conformance` is published before
  `lyric-testing` (tier 4, tier 5).
- `Testing.Conformance.Search` is in the package but has not been run on
  native: `lyric-search`'s own client still wraps its send in `try`.
- Library aspects cannot be instantiated from a native project build (`A0045`,
  #3498), so the aspect packages of these libraries are managed-only for now.
