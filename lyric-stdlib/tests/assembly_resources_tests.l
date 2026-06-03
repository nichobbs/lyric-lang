// assembly_resources_tests.l — exercises `Std.AssemblyResources`
// against the running test PE itself (which the bootstrap emitter
// always embeds a `Lyric.Contract` resource into).  Auto-discovered
// by `bootstrap/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs`.
// Exit 0 + "ok" in stdout means every assertion held.

package Std.AssemblyResources.Tests

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Std.AssemblyResources

// ─────────────────────────────────────────────────────────────────────────────
// §1. Locate the running test DLL
// ─────────────────────────────────────────────────────────────────────────────
//
// The auto-discovery runner (`StdlibLyricTests.fs::assemblyNameOf`) emits
// this program as `<stem>.dll` where stem = filename minus extension,
// hyphens and dots replaced with underscores.  For
// `assembly_resources_tests.l` that's `assembly_resources_tests.dll`.
// `Std.Environment.appBaseDirectory()` reports the directory the PE
// was loaded from, so we can locate the DLL deterministically.

func selfDllPath(): String {
  Path.join(Environment.appBaseDirectory(), "assembly_resources_tests.dll")
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Helpers
// ─────────────────────────────────────────────────────────────────────────────

func sliceContains(s: in slice[String], needle: in String): Bool {
  var i = 0
  while i < s.length {
    if s[i] == needle { return true }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Tests
// ─────────────────────────────────────────────────────────────────────────────

// `openAssembly` against a valid PE succeeds and snapshots a non-empty
// name list (every Lyric-emitted assembly carries at least the
// `Lyric.Contract` resource).
func testOpenSelf(): Unit {
  val ar = openAssembly(selfDllPath())
  val names = resourceNames(ar)
  assertTrue(names.length > 0, "open_self: at least one embedded resource")
}

// Every emitted Lyric assembly has an embedded `Lyric.Contract`
// resource (the contract-meta carrier).  This pins the bridge consumer's
// happy path.
func testLyricContractResourcePresent(): Unit {
  val ar    = openAssembly(selfDllPath())
  val names = resourceNames(ar)
  assertTrue(sliceContains(names, "Lyric.Contract"),
    "lyric_contract_resource_present: `Lyric.Contract` in name list")
}

// `tryReadResource` returns Some(bytes) for a present resource; the
// payload must be non-empty (a real JSON document).
func testTryReadLyricContract(): Unit {
  val ar = openAssembly(selfDllPath())
  match tryReadResource(ar, "Lyric.Contract") {
    case None -> panic("try_read_lyric_contract: expected Some(bytes)")
    case Some(bytes) -> {
      assertTrue(bytes.length > 0,
        "try_read_lyric_contract: bytes non-empty")
      // First byte should be '{' (0x7B) — cheap shape check catching
      // obvious garbage like an HTML 404 page or a misencoded resource.
      assertTrue(bytes[0] == 0x7Bu8,
        "try_read_lyric_contract: starts with '{'")
    }
  }
}

// `tryReadResource` returns None for an absent name — exercises the
// snapshot-membership guard in `containsName`.  Critical because the
// kernel `GetManifestResourceStream` would otherwise return null and
// the subsequent `CopyTo` would panic.
func testTryReadMissingReturnsNone(): Unit {
  val ar = openAssembly(selfDllPath())
  match tryReadResource(ar, "DefinitelyNotARealResourceNameXYZ") {
    case None    -> ()
    case Some(_) -> panic("try_read_missing: expected None")
  }
}

// `resourceNames` returns a stable snapshot — calling it twice yields
// the same set.  Pins that `openAssembly` does the enumeration once
// at open time rather than per call.
func testResourceNamesIsStable(): Unit {
  val ar = openAssembly(selfDllPath())
  val a = resourceNames(ar)
  val b = resourceNames(ar)
  assertEqualInt(a.length, b.length, "resource_names_is_stable: lengths match")
  var i = 0
  while i < a.length {
    assertEqual(a[i], b[i],
      "resource_names_is_stable: entry " + Str.fromInt(i) + " matches")
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Driver
// ─────────────────────────────────────────────────────────────────────────────

func main(): Int {
  testOpenSelf()
  testLyricContractResourcePresent()
  testTryReadLyricContract()
  testTryReadMissingReturnsNone()
  testResourceNamesIsStable()
  println("assembly-resources self-test: ok")
  return 0
}
