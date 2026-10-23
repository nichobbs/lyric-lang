//! Canonical Lyric examples. Pattern-match from these.
package Examples

import Std.Core
import Std.String
import Std.Parse
import Std.Sort
import Std.Collections

// ─── Domain types ──────────────────────────────────────────────────────────
pub type UserId = Long derives Compare, Hash, Equals

pub type OrderId = Long derives Compare, Hash, Equals

pub type Cents = Long range 0 ..= 100_000_000_000 derives Add, Sub, Compare

// ─── Records ────────────────────────────────────────────────────────────────
pub record User {
  pub id: UserId
  pub name: String
  pub email: String
}

pub record Order {
  pub id: OrderId
  pub userId: UserId
  pub totalCents: Cents
}

// ─── Unions ─────────────────────────────────────────────────────────────────
pub union AppError {
  case NotFound(message: String)
  case Unauthorised
  case ValidationError(field: String, message: String)
  case DbError(message: String)
}

// ─── Opaque type with invariant ─────────────────────────────────────────────
pub opaque type Email {
  raw: String
  invariant: raw.contains("@") and raw.length > 3
}

pub func parseEmail(s: in String): Result[Email, AppError] {
  if not s.contains("@") {
    return Err(error = ValidationError(field = "email", message = "must contain @"))
  }
  if s.length <= 3 {
    return Err(error = ValidationError(field = "email", message = "too short"))
  }
  return Ok(value = Email(raw = s))
}

pub func emailValue(self: in Email): String = self.raw

// ─── Function with contracts ─────────────────────────────────────────────────
pub func divide(a: in Int, b: in Int): Int
  requires: b != 0
  ensures: result * b == a
{
  return a / b
}

// ─── Error propagation pattern ───────────────────────────────────────────────
func invalidField(field: in String, message: in String): AppError {
  return ValidationError(field = field, message = message)
}

pub func parseOrder(rawId: in String, rawTotal: in String): Result[Order, AppError] {
  val id = match tryParseLong(rawId) {
    case Ok(value) -> value
    case Err(_) -> return Err(error = invalidField("id", "not a number"))
  }
  val total = match tryParseLong(rawTotal) {
    case Ok(value) -> value
    case Err(_) -> return Err(error = invalidField("total", "not a number"))
  }
  val cents = match Cents.tryFrom(total) {
    case Ok(value) -> value
    case Err(_) -> return Err(error = invalidField("total", "must be non-negative"))
  }
  return Ok(value = Order(id = OrderId.from(id), userId = UserId.from(1), totalCents = cents))
}

// ─── Pattern matching ────────────────────────────────────────────────────────
pub func describeError(err: in AppError): String {
  return match err {
    case NotFound(msg) -> "not found: ${msg}"
    case Unauthorised -> "access denied"
    case ValidationError(field, message) -> "invalid ${field}: ${message}"
    case DbError(msg) -> "database error: ${msg}"
  }
}

// ─── Collection idioms ───────────────────────────────────────────────────────
pub func activeUserNames(users: in slice[User], activeIds: in Set[UserId]): slice[String] {
  val names: List[String] = newList()
  for u in users {
    if activeIds.contains(u.id) {
      names.add(u.name)
    }
  }
  return sortStrings(names.toArray())
}

// ─── Multiple return values ──────────────────────────────────────────────────
pub func minMax(xs: in slice[Int]): (Int, Int)
  requires: xs.length > 0
{
  var lo = xs[0]
  var hi = xs[0]
  for x in xs {
    if x < lo {
      lo = x
    }
    if x > hi {
      hi = x
    }
  }
  return (lo, hi)
}

// ─── Closures ────────────────────────────────────────────────────────────────
pub func makeMultiplier(factor: in Int): (Int) -> Int {
  return { x -> x * factor }
}

// ─── Entry point ─────────────────────────────────────────────────────────────
func main(): Unit {
  val double = makeMultiplier(2)
  println("double 5 = ${toString(double(5))}")

  val result = parseOrder("42", "1500")
  match result {
    case Ok(order) -> println("order total: ${toString(order.totalCents.toLong())} cents")
    case Err(e) -> println("error: ${describeError(e)}")
  }

  val users = [
    User(id = UserId.from(1), name = "zoe", email = "zoe@example.com"),
    User(id = UserId.from(2), name = "bob", email = "bob@example.com"),
    User(id = UserId.from(3), name = "amy", email = "amy@example.com")
  ]
  val activeIds: Set[UserId] = newSet()
  activeIds.add(UserId.from(1))
  activeIds.add(UserId.from(3))
  val names = activeUserNames(users, activeIds)
  println("active: ${names[0]}, ${names[1]}")

  val nums = [5, 3, 8, 1, 9, 2]
  val (lo, hi) = minMax(nums)
  println("range: ${toString(lo)} to ${toString(hi)}")
}
