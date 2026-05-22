// tests/db_tests.l — tests for the pure-Lyric surface of the Db package.
//
// Covers DbError, DbValue, DbRow construction, and the `col` extractor
// function.  Connection and query functions require a live database driver
// and are not exercised here.

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
  val v = DbValue.DbNull
  match v {
    case DbValue.DbNull -> ()
    case _              -> assertTrue(false, "expected DbNull")
  }
}

test "DbValue.DbInt: carries the integer value" {
  val v = DbValue.DbInt(value = 42)
  match v {
    case DbValue.DbInt(value = n) -> assertEqualInt(n, 42, "DbInt value")
    case _                        -> assertTrue(false, "expected DbInt")
  }
}

test "DbValue.DbLong: carries the long value" {
  val v = DbValue.DbLong(value = 9000000000L)
  match v {
    case DbValue.DbLong(value = n) -> assertTrue(n == 9000000000L, "DbLong value")
    case _                         -> assertTrue(false, "expected DbLong")
  }
}

test "DbValue.DbBool: true variant" {
  val v = DbValue.DbBool(value = true)
  match v {
    case DbValue.DbBool(value = b) -> assertTrue(b, "DbBool must be true")
    case _                         -> assertTrue(false, "expected DbBool")
  }
}

test "DbValue.DbBool: false variant" {
  val v = DbValue.DbBool(value = false)
  match v {
    case DbValue.DbBool(value = b) -> assertTrue(not b, "DbBool must be false")
    case _                         -> assertTrue(false, "expected DbBool")
  }
}

test "DbValue.DbText: carries the string value" {
  val v = DbValue.DbText(value = "hello")
  match v {
    case DbValue.DbText(value = s) -> assertEqual(s, "hello", "DbText value")
    case _                         -> assertTrue(false, "expected DbText")
  }
}

test "DbValue.DbDecimal: carries exact decimal text" {
  val v = DbValue.DbDecimal(value = "123.456")
  match v {
    case DbValue.DbDecimal(value = s) -> assertEqual(s, "123.456", "DbDecimal value")
    case _                            -> assertTrue(false, "expected DbDecimal")
  }
}

test "DbValue.DbDateTime: carries ISO 8601 timestamp" {
  val v = DbValue.DbDateTime(value = "2024-01-15T10:30:00Z")
  match v {
    case DbValue.DbDateTime(value = s) -> assertEqual(s, "2024-01-15T10:30:00Z", "DbDateTime value")
    case _                             -> assertTrue(false, "expected DbDateTime")
  }
}

// ─── DbRow and col() ─────────────────────────────────────────────────────────

test "col: returns DbNull for missing column" {
  val row = DbRow(columns = [("id", DbValue.DbInt(value = 1))])
  val v = Db.col(row, "nonexistent")
  match v {
    case DbValue.DbNull -> ()
    case _              -> assertTrue(false, "missing column must return DbNull")
  }
}

test "col: returns correct value for existing column" {
  val row = DbRow(columns = [
    ("id",   DbValue.DbInt(value = 42)),
    ("name", DbValue.DbText(value = "Alice")),
  ])
  match Db.col(row, "name") {
    case DbValue.DbText(value = s) -> assertEqual(s, "Alice", "name column value")
    case _                         -> assertTrue(false, "expected DbText for name")
  }
}

test "col: returns first match when multiple columns have same name" {
  val row = DbRow(columns = [
    ("x", DbValue.DbInt(value = 1)),
    ("x", DbValue.DbInt(value = 2)),
  ])
  match Db.col(row, "x") {
    case DbValue.DbInt(value = n) -> assertEqualInt(n, 1, "first column wins")
    case _                        -> assertTrue(false, "expected DbInt")
  }
}

test "col: empty row returns DbNull for any column" {
  val row = DbRow(columns = [])
  val v = Db.col(row, "id")
  match v {
    case DbValue.DbNull -> ()
    case _              -> assertTrue(false, "empty row must return DbNull")
  }
}

test "col: int and text columns coexist in the same row" {
  val row = DbRow(columns = [
    ("count", DbValue.DbInt(value = 5)),
    ("label", DbValue.DbText(value = "ok")),
  ])
  match Db.col(row, "count") {
    case DbValue.DbInt(value = n) -> assertEqualInt(n, 5, "count column")
    case _                        -> assertTrue(false, "expected DbInt for count")
  }
  match Db.col(row, "label") {
    case DbValue.DbText(value = s) -> assertEqual(s, "ok", "label column")
    case _                         -> assertTrue(false, "expected DbText for label")
  }
}

test "col: boolean column is accessible" {
  val row = DbRow(columns = [("active", DbValue.DbBool(value = true))])
  match Db.col(row, "active") {
    case DbValue.DbBool(value = b) -> assertTrue(b, "active must be true")
    case _                         -> assertTrue(false, "expected DbBool")
  }
}
