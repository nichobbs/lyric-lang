# lyric-db: `SqlText` replaces raw SQL `String` (#7241, D220)

Breaking change to the lyric-db public API: `query`/`execute` (connection and
transaction), `queryOne`, `dbQuery` and `dbExecute` take `Db.SqlText`. Added
`sql`, `trySql`, `unsafeRawSql`, `sqlIsWellFormed`, `sqlToString`. Updated
`Lyric.Testing` mocks, the ledger/rbac/jobqueue/product-catalog examples, lyric-db
tests, README and book chapter 26. Tests: structural-check and constructor
cases in `lyric-db/tests/db_tests.l`, plus a negative-compile script proving a
concatenated `String` is rejected (`scripts/ci/db-sqltext-negative-test.sh`).
