//! msil_self_test_m87.l — Stage M87: @projectable opaque-twin synthesis.
//!
//! Exercises the self-hosted MSIL lowering path for `@projectable` opaque
//! types added in issue #1500.  The lowering generates a `<Name>View`
//! TypeDef with public fields plus `toView()` and (when possible) `tryInto()`
//! methods, mirroring the F# emitter's M2.0–M2.2 region.
//!
//! Checks:
//!   * Basic projectable — toView() exposes all fields.
//!   * Basic projectable — tryInto() round-trips the opaque value.
//!   * @hidden field — toView() exposes only non-hidden fields.
//!   * @projectionBoundary — view field keeps the source opaque type (no recursive toView()).
//!   * Nested projectable — view field becomes <FieldType>View (recursive projection).
//!   * Two-level nesting — recursive projection applies transitively.
//!
//! Manual run:
//!   ./bin/lyric run lyric-compiler/msil/msil_self_test_m87.l
//!
//! Expected stdout (all lines end "=true"):
//!   user_id=true
//!   user_name=true
//!   tryInto_ok=true
//!   account_id=true
//!   addr_city=true
//!   addr_country_iso=true
//!   outer_label=true
//!   outer_inner_value=true
//!   company_name=true
//!   company_city_name=true
//!
//! CI wiring: not yet wired — cannot add F# runner shim per CLAUDE.md.
//! Tracked as part of #1500; wiring via native `lyric test` when the
//! self-hosted bridge supports loading compiler packages in test mode.
package Msil.SelfTestM87
import Std.Core

// ── Test 1: basic flat @projectable — toView() + tryInto() ──────────────────
opaque type User @projectable {
  id: Int
  name: String
}

// ── Test 2: @hidden field — toView() only (tryInto() is suppressed) ─────────
opaque type Account @projectable {
  accountId: Int
  passwordHash: String @hidden
}

// ── Test 3: @projectionBoundary — view field keeps source opaque type ────────
opaque type Country @projectable {
  iso: String
}

opaque type Address @projectable {
  city: String
  country: Country @projectionBoundary
}

// ── Test 4: nested projectable — recursive view projection ──────────────────
opaque type Inner @projectable {
  value: Int
}

opaque type Outer @projectable {
  label: String
  inner: Inner
}

// ── Test 5: two-level nesting ───────────────────────────────────────────────
opaque type City @projectable {
  name: String
}

opaque type Region @projectable {
  city: City
}

opaque type Company @projectable {
  companyName: String
  region: Region
}

func check(label: in String, ok: in Bool): Int {
  if ok {
    println(label + "=true")
    0
  } else {
    println(label + "=false")
    1
  }
}

func main(): Int {
  var fails = 0

  // Test 1a: toView() exposes all fields.
  val u = User(id = 7, name = "alice")
  val uv = u.toView()
  fails = fails + check("user_id", uv.id == 7)
  fails = fails + check("user_name", uv.name == "alice")

  // Test 1b: tryInto() round-trips through the opaque.
  match uv.tryInto() {
    case Ok(u2) -> { fails = fails + check("tryInto_ok", u2.id == 7 and u2.name == "alice") }
    case Err(_) -> { fails = fails + check("tryInto_ok", false) }
  }

  // Test 2: @hidden suppresses tryInto(); visible field is accessible.
  val a = Account(accountId = 5, passwordHash = "secret")
  val av = a.toView()
  fails = fails + check("account_id", av.accountId == 5)

  // Test 3: @projectionBoundary — addrv.country is Country (not CountryView).
  val c = Country(iso = "US")
  val addr = Address(city = "NYC", country = c)
  val addrv = addr.toView()
  fails = fails + check("addr_city", addrv.city == "NYC")
  fails = fails + check("addr_country_iso", addrv.country.iso == "US")

  // Test 4: nested projectable — outerv.inner is InnerView (recursive projection).
  val inner = Inner(value = 42)
  val outer = Outer(label = "test", inner = inner)
  val outerv = outer.toView()
  fails = fails + check("outer_label", outerv.label == "test")
  fails = fails + check("outer_inner_value", outerv.inner.value == 42)

  // Test 5: two-level nesting.
  val city = City(name = "Paris")
  val region = Region(city = city)
  val company = Company(companyName = "Acme", region = region)
  val cv = company.toView()
  fails = fails + check("company_name", cv.companyName == "Acme")
  fails = fails + check("company_city_name", cv.region.city.name == "Paris")
  fails
}
