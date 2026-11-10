# lyric-db: a real JDBC backend on `--target jvm` (#8932)

`Db.Kernel.Jvm` (`lyric-db/src/_kernel/jvm/db_kernel.l`) was a set of
`NOT_SUPPORTED_ON_TARGET` stubs, was not registered in `[project.packages]`,
and `Db` imported the ADO.NET kernel and `System.Convert` unconditionally, so
the package did not even build on the JVM (which in turn kept `lyric-testing`,
which depends on `Lyric.Db`, from building there). Now:

- **Kernel.** `Db.Kernel.Jvm` is pure Lyric over `extern type` + auto-FFI
  against `java.sql` (`Connection`, `PreparedStatement`, `ResultSet`,
  `ResultSetMetaData`), with the same contract as `Db.Kernel.Net`: the same
  row wire format (`$bytes`, `$decimal`, `$datetime`), the same error strings
  surfaced as `Err`, no driver exception escaping as a `Bug`, transactions
  (auto-commit off/on, a failed commit rolled back), and DSN dispatch. SQLite
  is `org.xerial:sqlite-jdbc` 3.53.4.0 and PostgreSQL is
  `org.postgresql:postgresql` 42.7.14, both in `[maven]`.
- **Placeholders.** The public `@p0, @p1, ...` contract is unchanged.
  `translatePlaceholders` rewrites each `@pN` that is code (not in a `'...'`
  literal, `"..."` identifier, `--` or nested `/* */` comment, or `$tag$`
  body) to `?` and binds by index with `setString`, so a placeholder may
  repeat or appear out of order. Values are never interpolated. The
  PostgreSQL connection sets `stringtype=unspecified` so bound strings are
  typed by the server, as SQLite's affinity does implicitly.
- **Credentials.** User and password go to the driver as `Properties`, never
  into the JDBC URL.
- **Target selection.** `lyric.toml` gains the exclusive `dotnet` / `jvm`
  features (`default = ["dotnet", "postgres", "sqlite"]`; a `--target jvm`
  build swaps `dotnet` for `jvm`, docs/24 section 2.2). `Db.Kernel.Net` is
  gated on `dotnet`, `Db.Kernel.Jvm` on `jvm`; `db.l` reaches them through
  `@cfg`-gated wrappers and handle records. The `System.Convert` extern is
  gone (`v.toLong()`).
- **Tests.** `db_tests.l`, `db_sqlite_tests.l` and `db_postgres_connect_tests.l`
  run unchanged on both targets. `db_kernel_net_tests.l` is erased on the JVM;
  the new `db_kernel_jvm_tests.l` (erased on dotnet) covers placeholder
  translation, URL construction and the wire encodings on a live SQLite
  connection. `db` joined the Maven-using suites of
  `scripts/ci/jvm-ecosystem-suites.sh`.

Verified: dotnet 51 tests (23 + 12 + 6 + 10) and JVM 56 (23 + 12 + 6 + 15)
pass; `lyric-testing` now builds on `--target jvm` and on dotnet. The JVM
kernel was also driven by hand against a local PostgreSQL 16 server (typed
columns, bound parameters, commit, rollback after a failed statement, an
authentication failure); that run is not part of CI, which has no Postgres.

Differences from .NET, all documented in `lyric-db/README.md`: Npgsql keyword
strings and `Data Source=...` strings are .NET-only; `poolSize` is validated
but one connection is opened; `timestamptz` renders as a UTC instant and
`timestamp`/`date` as wall-clock values. A `@cfg`-gated wrapper returning
`Result[KernelNet.DbConn, String]` failed MSIL codegen ("match not
exhaustive") on compiler 0.7.12, so the wrappers return the finished `Db`
types instead.
