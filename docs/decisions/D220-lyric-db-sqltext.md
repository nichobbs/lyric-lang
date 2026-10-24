# D220 - lyric-db takes `SqlText`, not `String` (breaking, #7241)

**Status:** shipped.

## Context

`Db`'s "injection-safe" claim covered only bound parameters: nothing stopped
`"... WHERE x = '${name}'"` reaching the driver through `query`/`execute`. The
plan on #7241 was a non-breaking overload family; the owner chose a breaking
change now, while the library has few consumers.

## Decision

1. `DbConnection.query/execute`, `DbTransaction.query/execute`, `Db.queryOne`,
   `Db.dbQuery` and `Db.dbExecute` take `Db.SqlText` in place of the SQL
   `String`. This is a breaking change to the `@stable(since = "0.1")`
   surface; the new items are `@stable(since = "0.2")`.
2. `SqlText` is an opaque type with a non-blank invariant. Constructors:
   `sql(text)` (contract `sqlIsWellFormed`), `trySql(text)` (the same check as
   `Result`, code `SQL_REJECTED`) and `unsafeRawSql(text)` (non-blank only,
   greppable). `sqlToString` exposes the text to driver implementations.
3. `sqlIsWellFormed` is structural defence in depth: single statement, no
   comments outside literals, terminated literals, only `@p<N>` placeholders.
   It does not prove text safe.
4. Lyric has no way to require a compile-time literal argument, so `sql(dynamic)`
   still compiles (and is checked at run time). Closing that needs a
   `lyric lint` rule; tracked as a follow-up issue rather than shipped as a
   partial lint.
5. Every in-repo implementor and caller moved: `Lyric.Testing`'s mocks, the
   examples, tests, README and book. Dynamic fragments in
   `examples/product-catalog` use `unsafeRawSql` with a comment.

## Not done

Placeholder-count versus `params.length` checking and the `sql(...)` lint rule
are tracked in #8520. JVM kernel reachability (#5324) remains open on #7241.
`sqlIsWellFormed` is dialect-agnostic: it does not understand backslash string
escapes, dollar quoting or `@` operators such as Postgres `@>`; such text uses
`unsafeRawSql`.
