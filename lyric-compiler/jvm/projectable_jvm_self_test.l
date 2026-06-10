//! projectable_jvm_self_test.l — JVM parity test for `@projectable`
//! opaque-twin synthesis (#3044), the JVM equivalent of
//! `lyric-compiler/msil/msil_self_test_m87.l` (#1500 / PR #3015).
//!
//! Exercises the self-hosted JVM lowering path for `@projectable` opaque
//! types: the codegen emits a `<Name>View` class with public fields plus
//! `toView()` and (when eligible) `tryInto()` methods via
//! `Jvm.Lowering.lowerProjectableType`.
//!
//! Checks (same ten as the MSIL twin):
//!   * Basic projectable — toView() exposes all fields.
//!   * Basic projectable — tryInto() round-trips the opaque value.
//!   * @hidden field — toView() exposes only non-hidden fields.
//!   * @projectionBoundary — view field keeps the source opaque type (no recursive toView()).
//!   * Nested projectable — view field becomes <FieldType>View (recursive projection).
//!   * Two-level nesting — recursive projection applies transitively.
//!
//! Run in CI via native `lyric test --target jvm`: the test blocks are
//! synthesised into a runnable program, compiled in-process through the
//! self-hosted `Jvm.Bridge` (`compileToJarBundled`), and executed under
//! `java`.  Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed:
//!
//!   lyric test --target jvm lyric-compiler/jvm/projectable_jvm_self_test.l
@test_module
package Lyric.ProjectableJvmSelfTest

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

test "toView exposes all fields of a basic projectable" {
  val u = User(id = 7, name = "alice")
  val uv = u.toView()
  assertEqualInt(uv.id, 7, "user_id")
  assertEqual(uv.name, "alice", "user_name")
}

test "tryInto round-trips the opaque value" {
  val u = User(id = 7, name = "alice")
  val uv = u.toView()
  val ok = match uv.tryInto() {
    case Ok(u2) -> u2.id == 7 and u2.name == "alice"
    case Err(_) -> false
  }
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
