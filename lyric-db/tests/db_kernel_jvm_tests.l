//! tests/db_kernel_jvm_tests.l — direct tests for `Db.Kernel.Jvm`: the
//! `@pN` -> `?` placeholder translation and the JDBC URL construction, plus
//! the value encodings a live SQLite connection produces. No server needed.
//! Erased on `--target dotnet` (`Db.Kernel.Jvm` is the `jvm` kernel);
//! `db_kernel_net_tests.l` is its ADO.NET counterpart.
@cfg(feature = "jvm")
@test_module
package Db.KernelJvmTests

import Std.Core
import Std.Testing
import Db
import Db.Kernel.Jvm as DbKernel

func translated(sql: in String, count: in Int): String {
  match DbKernel.translatePlaceholders(sql, count) {
    case Ok(t) -> t.sql
    case Err(e) -> "ERR: " + e
  }
}

func orderOf(sql: in String, count: in Int): String {
  match DbKernel.translatePlaceholders(sql, count) {
    case Ok(t) -> {
      var acc = ""
      for i in t.order {
        acc = acc + i.toString() + ","
      }
      acc
    }
    case Err(e) -> "ERR: " + e
  }
}

test "translatePlaceholders: @pN becomes ? in order of appearance" {
  assertEqual(
    translated("SELECT * FROM t WHERE a = @p0 AND b = @p1", 2),
    "SELECT * FROM t WHERE a = ? AND b = ?",
    "rewritten"
  )
  assertEqual(orderOf("SELECT * FROM t WHERE a = @p0 AND b = @p1", 2), "0,1,", "order")
}

test "translatePlaceholders: out-of-order and repeated placeholders bind by index" {
  assertEqual(orderOf("SELECT @p1, @p0, @p1", 2), "1,0,1,", "each ? records its own parameter")
  assertEqual(translated("SELECT @p1, @p0, @p1", 2), "SELECT ?, ?, ?", "rewritten")
}

test "translatePlaceholders: a multi-digit index is read whole" {
  assertEqual(orderOf("SELECT @p10", 11), "10,", "@p10 is index ten")
}

test "translatePlaceholders: a quoted string literal is not rewritten" {
  assertEqual(
    translated("SELECT '@p0', @p0, 'it''s @p0'", 1),
    "SELECT '@p0', ?, 'it''s @p0'",
    "literal untouched, escape handled"
  )
  assertEqual(orderOf("SELECT '@p0', @p0, 'it''s @p0'", 1), "0,", "only the code placeholder binds")
}

test "translatePlaceholders: quoted identifiers, comments and dollar-quoted bodies are not rewritten" {
  assertEqual(translated("SELECT \"@p0\", @p0", 1), "SELECT \"@p0\", ?", "double-quoted identifier")
  assertEqual(translated("SELECT 1 -- @p0\n, @p0", 1), "SELECT 1 -- @p0\n, ?", "line comment")
  assertEqual(
    translated("SELECT /* @p0 /* nested @p0 */ @p0 */ @p0", 1),
    "SELECT /* @p0 /* nested @p0 */ @p0 */ ?",
    "nested block comment"
  )
  assertEqual(
    translated("SELECT $$ @p0 $$, $tag$ @p0 $tag$, @p0", 1),
    "SELECT $$ @p0 $$, $tag$ @p0 $tag$, ?",
    "dollar quoting"
  )
}

test "translatePlaceholders: a ? already in the text is left alone and an identifier-glued @p is not a placeholder" {
  assertEqual(
    translated("SELECT a@p0, x_@p0, @p0x, @p0", 1),
    "SELECT a@p0, x_@p0, @p0x, ?",
    "only the bare placeholder"
  )
}

test "translatePlaceholders: a placeholder with no supplied value is an Err" {
  match DbKernel.translatePlaceholders("SELECT @p0, @p2", 2) {
    case Ok(_) -> assertTrue(false, "@p2 needs a third parameter")
    case Err(e) -> assertTrue(e.length > 0, "names the missing placeholder")
  }
}

test "translatePlaceholders: an unterminated literal swallows the rest instead of rewriting inside it" {
  assertEqual(translated("SELECT 'oops @p0", 1), "SELECT 'oops @p0", "unterminated literal untouched")
}

test "buildSqliteUrl: memory, path and jdbc forms" {
  match DbKernel.buildSqliteUrl("sqlite::memory:") {
    case Ok(u) -> assertEqual(u, "jdbc:sqlite::memory:", "shorthand")
    case Err(e) -> assertTrue(false, e)
  }
  match DbKernel.buildSqliteUrl("sqlite://") {
    case Ok(u) -> assertEqual(u, "jdbc:sqlite::memory:", "empty path is memory")
    case Err(e) -> assertTrue(false, e)
  }
  match DbKernel.buildSqliteUrl("sqlite:///tmp/a.db") {
    case Ok(u) -> assertEqual(u, "jdbc:sqlite:/tmp/a.db", "absolute path")
    case Err(e) -> assertTrue(false, e)
  }
  match DbKernel.buildSqliteUrl("jdbc:sqlite:rel.db") {
    case Ok(u) -> assertEqual(u, "jdbc:sqlite:rel.db", "jdbc URL passes through")
    case Err(e) -> assertTrue(false, e)
  }
  match DbKernel.buildSqliteUrl("Data Source=x.db") {
    case Ok(_) -> assertTrue(false, "a .NET keyword string is not a JDBC target")
    case Err(e) -> assertTrue(e.length > 0, "explains what is accepted")
  }
}

test "buildPgTarget: credentials leave the URL and travel separately" {
  match DbKernel.buildPgTarget("postgres://app:s3cret;x=y@db.example:6543/shop?sslmode=require", "") {
    case Err(e) -> assertTrue(false, e)
    case Ok(t) -> {
      assertEqual(t.jdbcUrl, "jdbc:postgresql://db.example:6543/shop?sslmode=require", "no credentials in the URL")
      assertEqual(t.user, "app", "user")
      assertEqual(t.password, "s3cret;x=y", "password with ; and = intact")
    }
  }
}

test "buildPgTarget: defaults, password override, and bad ports" {
  match DbKernel.buildPgTarget("postgresql://db/shop", "override") {
    case Err(e) -> assertTrue(false, e)
    case Ok(t) -> {
      assertEqual(t.jdbcUrl, "jdbc:postgresql://db:5432/shop", "default port")
      assertEqual(t.password, "override", "explicit password wins")
    }
  }
  match DbKernel.buildPgTarget("postgres://u@h:notaport/d", "") {
    case Ok(_) -> assertTrue(false, "non-numeric port")
    case Err(e) -> assertTrue(e.length > 0, "non-numeric port is an Err")
  }
  match DbKernel.buildPgTarget("postgres://u@h:70000/d", "") {
    case Ok(_) -> assertTrue(false, "out-of-range port")
    case Err(e) -> assertTrue(e.length > 0, "out-of-range port is an Err")
  }
  match DbKernel.buildPgTarget("Host=h;Database=d", "") {
    case Ok(_) -> assertTrue(false, "keyword string")
    case Err(e) -> assertTrue(e.length > 0, "keyword string is an Err")
  }
}

test "SQLite: every wire encoding decodes to its typed DbValue" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      match conn.query(Db.sql("SELECT 7 AS i, 5000000000 AS l, 1.5 AS d, 'a\"b\\c' AS s, NULL AS n, CAST('abc' AS BLOB) AS b, @p0 AS p"), ["bound"]) {
        case Err(e) -> assertTrue(false, "query failed: " + e.message)
        case Ok(rows) -> {
          assertEqualInt(rows.length, 1, "one row")
          val row = rows[0]
          assertEqualInt(Db.getInt(row, "i"), 7, "small integer")
          assertEqualLong(Db.getLong(row, "l"), 5000000000i64, "big integer")
          match Db.col(row, "d") {
            case DbValue.DbDouble(v) -> assertTrue(v > 1.49 and v < 1.51, "double")
            case _ -> assertTrue(false, "expected DbDouble")
          }
          assertEqual(Db.dbGetString(row, "s"), "a\"b\\c", "quote and backslash survive the JSON round trip")
          match Db.col(row, "n") {
            case DbValue.DbNull -> ()
            case _ -> assertTrue(false, "expected DbNull")
          }
          match Db.col(row, "b") {
            case DbValue.DbBytes(bytes) -> assertEqualInt(bytes.length, 3, "blob length")
            case _ -> assertTrue(false, "expected DbBytes")
          }
          assertEqual(Db.dbGetString(row, "p"), "bound", "bound parameter")
        }
      }
      conn.close()
    }
  }
}

test "SQLite: a repeated and an out-of-order placeholder bind the right values" {
  match Db.connectSqlite("sqlite::memory:", 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      match conn.query(Db.sql("SELECT @p1 AS a, @p0 AS b, @p1 AS c"), ["x", "y"]) {
        case Err(e) -> assertTrue(false, "query failed: " + e.message)
        case Ok(rows) -> {
          assertEqual(Db.dbGetString(rows[0], "a"), "y", "first @p1")
          assertEqual(Db.dbGetString(rows[0], "b"), "x", "@p0")
          assertEqual(Db.dbGetString(rows[0], "c"), "y", "second @p1")
        }
      }
      conn.close()
    }
  }
}

test "SQLite: a file database persists across connections and a transaction survives close" {
  val path = "/tmp/lyric-db-jvm-kernel-test.db"
  match Db.connectSqlite("sqlite://" + path, 5000) {
    case Err(e) -> assertTrue(false, "connect failed: " + e.message)
    case Ok(conn) -> {
      val _ = conn.execute(Db.sql("DROP TABLE IF EXISTS kept"), [])
      val _ = conn.execute(Db.sql("CREATE TABLE kept (n INTEGER)"), [])
      match conn.transaction() {
        case Err(e) -> assertTrue(false, "begin failed: " + e.message)
        case Ok(tx) -> {
          val _ = tx.execute(Db.sql("INSERT INTO kept (n) VALUES (@p0)"), ["41"])
          val _ = tx.commit()
        }
      }
      // After the commit, auto-commit is back on: this write needs no transaction.
      val _ = conn.execute(Db.sql("INSERT INTO kept (n) VALUES (@p0)"), ["42"])
      conn.close()
    }
  }
  match Db.connectSqlite("sqlite://" + path, 5000) {
    case Err(e) -> assertTrue(false, "reconnect failed: " + e.message)
    case Ok(conn) -> {
      match conn.query(Db.sql("SELECT COUNT(*) AS c FROM kept"), []) {
        case Err(e) -> assertTrue(false, "query failed: " + e.message)
        case Ok(rows) -> assertEqualInt(Db.getInt(rows[0], "c"), 2, "both rows persisted")
      }
      val _ = conn.execute(Db.sql("DROP TABLE kept"), [])
      conn.close()
    }
  }
}

test "connectSqlite: an unopenable path is a CONNECT_ERROR, not a panic" {
  match Db.connectSqlite("sqlite:///nonexistent-dir-for-lyric-db/none.db", 5000) {
    case Ok(conn) -> {
      assertTrue(false, "the directory does not exist")
      conn.close()
    }
    case Err(e) -> assertEqual(e.code, "CONNECT_ERROR", "mapped error code")
  }
}
