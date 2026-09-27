//! benchmarks/bench_json.l — `@generate(Json)` decode benchmarks (#7347).
//!
//! Measures the synthesised `fromJson` on request-sized bodies:
//!
//!   benchFromJsonWide20      — a flat 20-field record, 200 decodes.
//!   benchFromJsonNested      — a 20-field order whose fields include nested
//!                              records and a 20-element slice of records,
//!                              200 decodes.
//!   benchStringReadersWide20 — the same 20 fields read one at a time through
//!                              the string-based `lyricJsonGet*` readers, which
//!                              parse the whole body once per field; the
//!                              reference point for a per-field re-parse.
//!
//! A synthesised `fromJson` parses its body once and decodes every field,
//! nested record and slice element from that one document.
//!
//! Run with: lyric bench benchmarks/bench_json.l
@bench_module
package Bench.Json

import Std.Core
import Std.Json
import Std.Time

@generate(Json)
record Wide20 {
  id: Int
  name: String
  active: Bool
  score: Double
  created: Long
  f06: Int
  f07: String
  f08: Bool
  f09: Double
  f10: Long
  f11: Int
  f12: String
  f13: Bool
  f14: Double
  f15: Long
  f16: Int
  f17: String
  f18: Bool
  f19: Double
  f20: Long
}

@generate(Json)
record Address {
  street: String
  city: String
  postcode: String
  country: String
}

@generate(Json)
record Customer {
  id: Long
  name: String
  email: String
  address: Address
}

@generate(Json)
record Line {
  sku: String
  quantity: Int
  unitPrice: Double
  taxable: Bool
}

@generate(Json)
record Order {
  id: Long
  status: String
  currency: String
  total: Double
  paid: Bool
  customer: Customer
  billing: Address
  shipping: Address
  lines: slice[Line]
  tags: slice[String]
  f11: Int
  f12: String
  f13: Bool
  f14: Double
  f15: Long
  f16: Int
  f17: String
  f18: Bool
  f19: Double
  f20: Long
}

val iterations = 200

func wideBody(): String {
  "{\"id\": 1, \"name\": \"widget\", \"active\": true, \"score\": 4.5, \"created\": 1700000000000," +
    " \"f06\": 6, \"f07\": \"seven\", \"f08\": false, \"f09\": 9.5, \"f10\": 10," +
    " \"f11\": 11, \"f12\": \"twelve\", \"f13\": true, \"f14\": 14.5, \"f15\": 15," +
    " \"f16\": 16, \"f17\": \"seventeen\", \"f18\": false, \"f19\": 19.5, \"f20\": 20}"
}

func addressBody(): String {
  "{\"street\": \"1 Main St\", \"city\": \"Springfield\", \"postcode\": \"12345\", \"country\": \"AU\"}"
}

func orderBody(): String {
  var lines = "["
  var i = 0
  while i < 20 {
    if i > 0 {
      lines = lines + ", "
    }
    lines = lines + "{\"sku\": \"SKU-" + toString(i) + "\", \"quantity\": " + toString(i + 1) +
      ", \"unitPrice\": 9.99, \"taxable\": true}"
    i = i + 1
  }
  lines = lines + "]"
  "{\"id\": 42, \"status\": \"open\", \"currency\": \"AUD\", \"total\": 199.8, \"paid\": false," +
    " \"customer\": {\"id\": 7, \"name\": \"Ada\", \"email\": \"ada@example.com\", \"address\": " +
    addressBody() +
    "}, \"billing\": " +
    addressBody() +
    ", \"shipping\": " +
    addressBody() +
    ", \"lines\": " +
    lines +
    ", \"tags\": [\"priority\", \"gift\"]," +
    " \"f11\": 11, \"f12\": \"twelve\", \"f13\": true, \"f14\": 14.5, \"f15\": 15," +
    " \"f16\": 16, \"f17\": \"seventeen\", \"f18\": false, \"f19\": 19.5, \"f20\": 20}"
}

@bench
pub func benchFromJsonWide20(): Unit {
  val body = wideBody()
  var acc = 0
  var i = 0
  while i < iterations {
    match Wide20.fromJson(body) {
      case Ok(w) -> {
        acc = acc + w.id + w.f20.toInt()
      }
      case Err(e) -> panic("Wide20 decode failed: " + e)
    }
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}

@bench
pub func benchFromJsonNested(): Unit {
  val body = orderBody()
  var acc = 0
  var i = 0
  while i < iterations {
    match Order.fromJson(body) {
      case Ok(o) -> {
        acc = acc + o.lines.length + o.customer.address.city.length
      }
      case Err(e) -> panic("Order decode failed: " + e)
    }
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}

@bench
pub func benchStringReadersWide20(): Unit {
  val body = wideBody()
  val intNames = ["id", "f06", "f11", "f16"]
  val strNames = ["name", "f07", "f12", "f17"]
  val boolNames = ["active", "f08", "f13", "f18"]
  val doubleNames = ["score", "f09", "f14", "f19"]
  val longNames = ["created", "f10", "f15", "f20"]
  var acc = 0
  var i = 0
  while i < iterations {
    var k = 0
    while k < 4 {
      var iv = 0
      var sv = ""
      var bv = false
      var dv = 0.0
      var lv = 0i64
      if lyricJsonGetInt(body, intNames[k], iv) and lyricJsonGetString(body, strNames[k], sv) and lyricJsonGetBool(body, boolNames[k], bv) and lyricJsonGetDouble(body, doubleNames[k], dv) and lyricJsonGetLong(body, longNames[k], lv) {
        acc = acc + iv + sv.length
      } else {
        panic("string reader failed")
      }
      k = k + 1
    }
    i = i + 1
  }
  if acc < 0 {
    println(toString(acc))
  }
}
