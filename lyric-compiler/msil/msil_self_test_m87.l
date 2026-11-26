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
//! Run in CI via native `lyric test` (#3045): the test blocks are synthesised
//! into a runnable program and compiled IN-PROCESS through the self-hosted
//! `Msil.Bridge`, whose codegen performs the @projectable lowering under
//! test.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed
//! (the bitwise_self_test.l pattern):
//!
//!   lyric test --target dotnet lyric-compiler/msil/msil_self_test_m87.l
//!
//! The JVM equivalent (same ten checks through the self-hosted `Jvm.Bridge`)
//! is `lyric-compiler/jvm/projectable_jvm_self_test.l` (#3044).
@test_module
package Msil.SelfTestM87

import Std.Core
import Std.Testing

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

// ── Test 11: @projectable with an invariant — tryInto checks it (#9315, D511) ──
opaque type Quota @projectable {
  used: Int
  limit: Int
  invariant: used >= 0 and used <= limit
}

test "toView exposes all fields of a basic projectable" {
  val u = User(id = 7, name = "alice")
  val uv = u.toView()
  assertEqualInt(uv.id, 7, "user_id")
  assertEqual(uv.name, "alice", "user_name")
}

test "tryInto round-trips the opaque value" {
  val u = User(id = 7, name = "alice")
  val uv = u.toView()
  val ok = match uv.tryInto() { case Ok(u2) -> u2.id == 7 and u2.name == "alice"; case Err(_) -> false }
  assertTrue(ok, "tryInto_ok")
}

test "@hidden field is omitted from the view" {
  val a = Account(accountId = 5, passwordHash = "secret")
  val av = a.toView()
  assertEqualInt(av.accountId, 5, "account_id")
}

test "@projectionBoundary keeps the source opaque type" {
  val c = Country(iso = "US")
  val addr = Address(city = "NYC", country = c)
  val addrv = addr.toView()
  assertEqual(addrv.city, "NYC", "addr_city")
  // addrv.country is Country (not CountryView): read the opaque field directly.
  assertEqual(addrv.country.iso, "US", "addr_country_iso")
}

test "nested projectable projects recursively" {
  val inner = Inner(value = 42)
  val outer = Outer(label = "test", inner = inner)
  val outerv = outer.toView()
  assertEqual(outerv.label, "test", "outer_label")
  // outerv.inner is InnerView (recursive projection).
  assertEqualInt(outerv.inner.value, 42, "outer_inner_value")
}

test "two-level nesting projects transitively" {
  val city = City(name = "Paris")
  val region = Region(city = city)
  val company = Company(companyName = "Acme", region = region)
  val cv = company.toView()
  assertEqual(cv.companyName, "Acme", "company_name")
  assertEqual(cv.region.city.name, "Paris", "company_city_name")
}

test "tryInto returns Err naming the violated invariant clause instead of panicking" {
  val bad = QuotaView(used = 5, limit = 3)
  val msg = match bad.tryInto() { case Ok(_) -> "ok"; case Err(m) -> m }
  assertTrue(msg.startsWith("InvariantViolated: "), "tryInto_err_prefix: " + msg)
  assertTrue(msg.contains(".Quota invariant used >= 0 and used <= limit"), "tryInto_err_clause: " + msg)
}

test "tryInto returns Ok for a view whose values satisfy the invariant" {
  val good = QuotaView(used = 2, limit = 3)
  val ok = match good.tryInto() { case Ok(q) -> q.toView().used == 2; case Err(_) -> false }
  assertTrue(ok, "tryInto_invariant_ok")
}
