//! static_type_recovery_jvm_self_test.l — CI gate for expressions whose
//! static type the JVM backend lost, so a following call resolved against
//! the wrong receiver (J008 at build time).
//!
//! 1. Package-qualified type-associated calls (#7478).  `Std.Http.Url.
//!    tryFrom(s)` lowered its `Std` prefix as a value ("reference 'Std'
//!    resolves to no local"); it now resolves through the declaring
//!    package's own dot-named registration.
//! 2. An interface value unwrapped from `Result[Iface, E]` returned by a
//!    method called on a record field (#7479) dispatches through the
//!    interface, not `java.lang.Object`.
//! 3. `.toArray()` on a `slice[T]` (a record field or a local) is the slice
//!    itself (#7480), as on dotnet.
//! 4. An un-annotated list-literal binding is a `slice[T]`, so `.append`,
//!    `.concat` and `.slice` apply to it (#7524).
//! 5. An un-annotated binding of `List[T].toArray()` keeps the element type,
//!    so `bs[0].toInt()` resolves on `Byte` (#7362).
//! 6. `s.split(sep)` splits on the literal separator, as `Std.String.split`
//!    does on dotnet.  The JVM passed `sep` to `java.lang.String.split` as a
//!    regular expression, so `"Std.Json".split(".")` yielded no parts and
//!    trailing empty parts were dropped (found through lyric-generator-sdk,
//!    #7511).
//!
//!   lyric test --target dotnet lyric-compiler/jvm/static_type_recovery_jvm_self_test.l
//!   lyric test --target jvm    lyric-compiler/jvm/static_type_recovery_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.StaticTypeRecoveryJvmSelfTest

import Std.Core
import Std.Collections
import Std.Http
import Std.Testing

record UrlError {
  message: String
}

func resolveUrl(urlStr: in String): Result[Std.Http.Url, UrlError] {
  match Std.Http.Url.tryFrom(urlStr) {
    case Err(_) -> Err(error = UrlError(message = "bad url"))
    case Ok(u) -> Ok(value = u)
  }
}

pub interface Transaction {
  func commit(): Result[Unit, String]
}

pub record TxImpl {
  var committed: Bool
}

impl Transaction for TxImpl {
  func commit(): Result[Unit, String] {
    self.committed = true
    return Ok(())
  }
}

pub interface ConnectionIface {
  func transaction(): Result[Transaction, String]
}

pub record Connection {
  var txCount: Int
}

impl ConnectionIface for Connection {
  func transaction(): Result[Transaction, String] {
    self.txCount = self.txCount + 1
    val tx: Transaction = TxImpl(committed = false)
    return Ok(tx)
  }
}

record Ctx {
  db: Connection
}

func newCtx(): Ctx {
  Ctx(db = Connection(txCount = 0))
}

pub record AnnotationDescriptor {
  name: String
  args: slice[String]
}

test "a package-qualified dot-named call resolves as a static call (#7478)" {
  match resolveUrl("http://example.com/a") {
    case Ok(u) -> assertEqual(Std.Http.Url.toString(u), "http://example.com/a", "url round-trips")
    case Err(e) -> assertTrue(false, "unexpected error: " + e.message)
  }
  match resolveUrl("not a url") {
    case Ok(_) -> assertTrue(false, "an invalid url must be rejected")
    case Err(e) -> assertEqual(e.message, "bad url", "error message")
  }
}

test "an interface unwrapped from a field receiver's Result dispatches (#7479)" {
  val ctx = newCtx()
  val result = match ctx.db.transaction() {
    case Ok(tx) -> match tx.commit() { case Ok(_) -> "committed"; case Err(e) -> "err: " + e }
    case Err(e) -> "begin err: " + e
  }
  assertEqual(result, "committed", "commit through the interface")
  assertEqualInt(ctx.db.txCount, 1, "one transaction begun")
}

test "toArray on a record's slice field is the slice (#7480)" {
  val empty = AnnotationDescriptor(name = "required", args = [])
  assertEqualInt(empty.args.toArray().length, 0, "empty slice field")
  val two = AnnotationDescriptor(name = "since", args = ["a", "b"])
  val arr = two.args.toArray()
  assertEqualInt(arr.length, 2, "two elements")
  assertEqual(arr[1], "b", "second element")
}

test "slice operations on an un-annotated list literal (#7524)" {
  val xs = [1, 2, 3]
  val ys = xs.append(4)
  assertEqualInt(ys.length, 4, "append length")
  assertEqualInt(ys[3] + ys[0], 5, "append elements")
  assertEqualInt(xs.length, 3, "append leaves the receiver unchanged")
  val zs = xs.concat([10, 20])
  assertEqualInt(zs.length, 5, "concat length")
  assertEqualInt(zs[4], 20, "concat element")
  val mid = zs.slice(1, 3)
  assertEqualInt(mid.length, 2, "slice length")
  assertEqualInt(mid[0] * mid[1], 6, "slice elements")
  var names = ["a", "b"]
  names = names.append("c")
  assertEqual(names[2], "c", "append on a var binding")
  var total = 0
  for x in xs {
    total = total + x
  }
  assertEqualInt(total, 6, "iterating the literal binding")
}

test "an un-annotated List.toArray() binding keeps its element type (#7362)" {
  val bl: List[Byte] = newList()
  bl.add(7u8)
  bl.add(9u8)
  val bs = bl.toArray()
  assertEqualInt(bs[0].toInt() + bs[1].toInt(), 16, "byte elements")
  val sl: List[String] = newList()
  sl.add("x")
  val ss = sl.toArray()
  assertEqualInt(ss[0].length, 1, "string elements")
}

test "String.split splits on the literal separator" {
  val segs = "Std.Json".split(".")
  assertEqualInt(segs.length, 2, "a regex metacharacter separator is literal")
  assertEqual(segs[1], "Json", "second segment")
  val parts = "a,,b,".split(",")
  assertEqualInt(parts.length, 4, "empty parts are kept, trailing included")
  assertEqual(parts[1] + "|" + parts[3], "|", "the empty parts")
  assertEqualInt("a|b".split("|").length, 2, "alternation metacharacter")
  val whole = "abc".split("")
  assertEqualInt(whole.length, 1, "an empty separator yields the input")
  assertEqual(whole[0], "abc", "the input itself")
  assertEqualInt("".split(",").length, 1, "an empty input yields one empty part")
  assertEqualInt("abc".split("x").length, 1, "an absent separator yields the input")
}
