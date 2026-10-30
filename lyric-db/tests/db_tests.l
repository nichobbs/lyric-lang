//! tests/db_tests.l — tests for the pure-Lyric surface of the Db package.
//!
//! Covers DbError, DbValue, DbRow construction, and the `col` extractor
//! function.  Connection and query functions require a live database driver
//! and are not exercised here.
@test_module
package Db.DbTests

import Std.Core
import Std.Testing
import Db

// ─── DbError ─────────────────────────────────────────────────────────────────
test "DbError: fields are accessible" {
  val e = DbError(message = "syntax error", code = "42601")
  assertEqual(e.message, "syntax error", "message field")
  assertEqual(e.code, "42601", "code field")
}

test "DbError: empty code is allowed" {
  val e = DbError(message = "generic error", code = "")
  assertEqual(e.code, "", "empty code is valid")
}

// ─── DbValue ─────────────────────────────────────────────────────────────────
test "DbValue.DbNull: can be matched" {
  val v = DbNull
  match v {
    case DbNull -> ()
    case _ -> assertTrue(false, "expected DbNull")
  }
}

test "DbValue.DbInt: carries the integer value" {
  val v = DbInt(value = 42)
  match v {
    case DbInt(n) -> assertEqualInt(n, 42, "DbInt value")
    case _ -> assertTrue(false, "expected DbInt")
  }
}

test "DbValue.DbLong: carries the long value" {
  val v = DbLong(value = 9000000000i64)
  match v {
    case DbLong(n) -> assertTrue(n == 9000000000i64, "DbLong value")
    case _ -> assertTrue(false, "expected DbLong")
  }
}

test "DbValue.DbBool: true variant" {
  val v = DbBool(value = true)
  match v {
    case DbBool(b) -> assertTrue(b, "DbBool must be true")
    case _ -> assertTrue(false, "expected DbBool")
  }
}

test "DbValue.DbBool: false variant" {
  val v = DbBool(value = false)
  match v {
    case DbBool(b) -> assertTrue(not b, "DbBool must be false")
    case _ -> assertTrue(false, "expected DbBool")
  }
}

test "DbValue.DbText: carries the string value" {
  val v = DbText(value = "hello")
  match v {
    case DbText(s) -> assertEqual(s, "hello", "DbText value")
    case _ -> assertTrue(false, "expected DbText")
  }
}

test "DbValue.DbDecimal: carries exact decimal text" {
  val v = DbDecimal(value = "123.456")
  match v {
    case DbDecimal(s) -> assertEqual(s, "123.456", "DbDecimal value")
    case _ -> assertTrue(false, "expected DbDecimal")
  }
}

test "DbValue.DbDateTime: carries ISO 8601 timestamp" {
  val v = DbDateTime(value = "2024-01-15T10:30:00Z")
  match v {
    case DbDateTime(s) -> assertEqual(s, "2024-01-15T10:30:00Z", "DbDateTime value")
    case _ -> assertTrue(false, "expected DbDateTime")
  }
}

// ─── DbRow and col() ─────────────────────────────────────────────────────────
test "col: returns DbNull for missing column" {
  val row = DbRow(columns = [DbColumn(name = "id", value = DbInt(value = 1))])
  val v = Db.col(row, "nonexistent")
  match v {
    case DbNull -> ()
    case _ -> assertTrue(false, "missing column must return DbNull")
  }
}

test "col: returns correct value for existing column" {
  val row = DbRow(
    columns = [
      DbColumn(name = "id", value = DbInt(value = 42)),
      DbColumn(name = "name", value = DbText(value = "Alice"))
    ]
  )
  match Db.col(row, "name") {
    case DbText(s) -> assertEqual(s, "Alice", "name column value")
    case _ -> assertTrue(false, "expected DbText for name")
  }
}

test "col: returns first match when multiple columns have same name" {
  val row = DbRow(
    columns = [DbColumn(name = "x", value = DbInt(value = 1)), DbColumn(name = "x", value = DbInt(value = 2))]
  )
  match Db.col(row, "x") {
    case DbInt(n) -> assertEqualInt(n, 1, "first column wins")
    case _ -> assertTrue(false, "expected DbInt")
  }
}

test "col: empty row returns DbNull for any column" {
  val row = DbRow(columns = [])
  val v = Db.col(row, "id")
  match v {
    case DbNull -> ()
    case _ -> assertTrue(false, "empty row must return DbNull")
  }
}

test "col: int and text columns coexist in the same row" {
  val row = DbRow(
    columns = [
      DbColumn(name = "count", value = DbInt(value = 5)),
      DbColumn(name = "label", value = DbText(value = "ok"))
    ]
  )
  match Db.col(row, "count") {
    case DbInt(n) -> assertEqualInt(n, 5, "count column")
    case _ -> assertTrue(false, "expected DbInt for count")
  }
  match Db.col(row, "label") {
    case DbText(s) -> assertEqual(s, "ok", "label column")
    case _ -> assertTrue(false, "expected DbText for label")
  }
}

test "col: boolean column is accessible" {
  val row = DbRow(columns = [DbColumn(name = "active", value = DbBool(value = true))])
  match Db.col(row, "active") {
    case DbBool(b) -> assertTrue(b, "active must be true")
    case _ -> assertTrue(false, "expected DbBool")
  }
}

// ─── SqlText (#7241) ─────────────────────────────────────────────────────────
test "sql: a literal statement with positional placeholders round-trips" {
  val stmt = Db.sql("SELECT id, name FROM users WHERE id = @p0 AND name = @p1")
  assertEqual(Db.sqlToString(stmt), "SELECT id, name FROM users WHERE id = @p0 AND name = @p1", "text is preserved")
}

test "sql: a trailing semicolon, quoted literals and doubled quotes are accepted" {
  assertTrue(Db.sqlIsWellFormed("SELECT 1;"), "trailing semicolon")
  assertTrue(Db.sqlIsWellFormed("SELECT 1;  \n"), "trailing semicolon then whitespace")
  assertTrue(Db.sqlIsWellFormed("UPDATE jobs SET status = 'pending' WHERE id = @p0"), "terminated literal")
  assertTrue(Db.sqlIsWellFormed("SELECT 'it''s' AS s"), "doubled quote inside a literal")
  assertTrue(Db.sqlIsWellFormed("SELECT '--' AS dashes, '@x' AS at, ';' AS semi"), "markers inside a literal are data")
  assertTrue(Db.sqlIsWellFormed("SELECT @p0, @p10, @p2"), "multi-digit placeholder")
}

test "sqlIsWellFormed: rejects the shapes an interpolated value produces" {
  val name = "x'; DROP TABLE users; --"
  assertFalse(Db.sqlIsWellFormed("SELECT * FROM users WHERE name = '" + name + "'"), "classic quote-breakout payload")
  assertFalse(Db.sqlIsWellFormed("SELECT * FROM users WHERE name = 'x"), "unterminated literal")
  assertFalse(Db.sqlIsWellFormed("SELECT 1; DROP TABLE users"), "second statement")
  assertFalse(Db.sqlIsWellFormed("SELECT 1 -- trailing comment"), "line comment")
  assertFalse(Db.sqlIsWellFormed("SELECT 1 /* block */"), "block comment")
  assertFalse(Db.sqlIsWellFormed("SELECT * FROM t WHERE a = @name"), "named placeholder")
  assertFalse(Db.sqlIsWellFormed("SELECT * FROM t WHERE a = @p"), "placeholder without an index")
  assertFalse(Db.sqlIsWellFormed("SELECT * FROM t WHERE a = @p0x"), "placeholder run into an identifier")
  assertFalse(Db.sqlIsWellFormed("SELECT @@version"), "system variable")
  assertFalse(Db.sqlIsWellFormed(""), "empty text")
  assertFalse(Db.sqlIsWellFormed("  \n\t "), "blank text")
}

test "trySql: a rejected text is an Err with code SQL_REJECTED, an accepted one an Ok" {
  match Db.trySql("SELECT 1; DROP TABLE users") {
    case Ok(_) -> assertTrue(false, "a two-statement text must be rejected")
    case Err(e) -> assertEqual(e.code, "SQL_REJECTED", "rejection code")
  }
  match Db.trySql("SELECT 1") {
    case Ok(stmt) -> assertEqual(Db.sqlToString(stmt), "SELECT 1", "accepted text")
    case Err(e) -> assertTrue(false, "SELECT 1 must be accepted: " + e.message)
  }
}

test "unsafeRawSql: builds a SqlText from a run-time string without the structural check" {
  val table = "users"
  val stmt = Db.unsafeRawSql("SELECT count(*) FROM " + table + " -- audited fixed fragment")
  assertEqual(Db.sqlToString(stmt), "SELECT count(*) FROM users -- audited fixed fragment", "text is preserved")
}

test "sqlPlaceholderCount: highest @p index plus one, ignoring string literals" {
  assertEqualInt(Db.sqlPlaceholderCount("SELECT 1"), 0, "no placeholders")
  assertEqualInt(Db.sqlPlaceholderCount("SELECT * FROM t WHERE a = @p0 AND b = @p1"), 2, "two placeholders")
  assertEqualInt(Db.sqlPlaceholderCount("SELECT * FROM t WHERE a = @p0 AND b = @p2"), 3, "a gap still needs three values")
  assertEqualInt(Db.sqlPlaceholderCount("SELECT * FROM t WHERE a = @p1 AND b = @p1"), 2, "a repeated placeholder counts once")
  assertEqualInt(Db.sqlPlaceholderCount("SELECT '@p5' FROM t WHERE a = @p0"), 1, "a placeholder inside a literal is text")
  assertEqualInt(Db.sqlPlaceholderCount("SELECT * FROM t WHERE a = @p10"), 11, "multi-digit index")
}

test "sqlParamsError: None only when the parameter count matches the highest placeholder" {
  val stmt = Db.sql("SELECT * FROM t WHERE a = @p0 AND b = @p1")
  assertTrue(Db.sqlParamsError(stmt, ["1", "2"]).isNone(), "exact count is accepted")
  match Db.sqlParamsError(stmt, ["1"]) {
    case Some(e) -> assertEqual(e.code, "PARAM_COUNT_MISMATCH", "too few values")
    case None -> assertTrue(false, "too few values must be rejected")
  }
  match Db.sqlParamsError(stmt, ["1", "2", "3"]) {
    case Some(e) -> assertEqual(e.code, "PARAM_COUNT_MISMATCH", "too many values")
    case None -> assertTrue(false, "too many values must be rejected")
  }
  assertTrue(Db.sqlParamsError(Db.sql("SELECT 1"), []).isNone(), "no placeholders and no values")
  assertTrue(Db.sqlParamsError(Db.unsafeRawSql("SELECT 1"), ["x"]).isSome(), "values for a statement with no placeholders")
}
