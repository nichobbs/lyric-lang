//! assembly_resources_tests.l — exercises `Std.AssemblyResources`
//! against the running test PE itself (which the bootstrap emitter
//! always embeds a `Lyric.Contract` resource into).  Auto-discovered
//! by `bootstrap/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs`.
//! Exit 0 + "ok" in stdout means every assertion held.
package Std.AssemblyResources.Tests

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Std.File as File
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
    if s[i] == needle {
      return true
    }
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
  val ar = openAssembly(selfDllPath())
  val names = resourceNames(ar)
  assertTrue(sliceContains(names, "Lyric.Contract"), "lyric_contract_resource_present: `Lyric.Contract` in name list")
}

// `tryReadResource` returns Some(bytes) for a present resource; the
// payload must be non-empty (a real JSON document).
func testTryReadLyricContract(): Unit {
  val ar = openAssembly(selfDllPath())
  match tryReadResource(ar, "Lyric.Contract") {
    case None -> panic("try_read_lyric_contract: expected Some(bytes)")
    case Some(bytes) -> {
      assertTrue(bytes.length > 0, "try_read_lyric_contract: bytes non-empty")
      // First byte should be '{' (0x7B) — cheap shape check catching
      // obvious garbage like an HTML 404 page or a misencoded resource.
      assertTrue(bytes[0] == 0x7Bu8, "try_read_lyric_contract: starts with '{'")
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
    case None -> ()
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
    assertEqual(a[i], b[i], "resource_names_is_stable: entry " + Str.fromInt(i) + " matches")
    i = i + 1
  }
}

// ASCII bytes of "formatVersion" — a JSON key that appears only inside
// the embedded `Lyric.Contract` resource of a Lyric-emitted assembly
// (never in this test's own code or metadata), so a hit pins a byte we
// know lives in the contract blob.
func formatVersionNeedle(): slice[Byte] {
  val n: List[Byte] = newList()
  n.add(0x66u8) // f
  n.add(0x6Fu8) // o
  n.add(0x72u8) // r
  n.add(0x6Du8) // m
  n.add(0x61u8) // a
  n.add(0x74u8) // t
  n.add(0x56u8) // V
  n.add(0x65u8) // e
  n.add(0x72u8) // r
  n.add(0x73u8) // s
  n.add(0x69u8) // i
  n.add(0x6Fu8) // o
  n.add(0x6Eu8) // n
  n.toArray()
}

// First index in `hay` where `needle` occurs verbatim, or -1.
func findSubseq(hay: in slice[Byte], needle: in slice[Byte]): Int {
  val nlen = needle.length
  if nlen == 0 {
    return -1
  }
  var i = 0
  while i + nlen <= hay.length {
    var j = 0
    var matched = true
    while matched and j < nlen {
      if hay[i + j] != needle[j] {
        matched = false
      } else {
        j = j + 1
      }
    }
    if matched {
      return i
    }
    i = i + 1
  }
  -1
}

func bytesEqual(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
}

// Regression for the per-package emit const-drop bug.  The per-package
// emitter runs *inside* the self-hosted compiler process, where many
// compiler/stdlib assemblies are already loaded.  The previous
// implementation used `Assembly.LoadFrom`, which keys the runtime's
// loaded-assembly cache by *assembly identity* — so loading a freshly
// emitted DLL whose identity matched an already-loaded assembly silently
// returned the in-process copy, reading the wrong resource bytes
// (dropping `const` decls from large contracts).  The fix loads from
// image bytes via `Assembly.Load(byte[])`, which has no identity dedup.
//
// To exercise this we mint two DLLs that share THIS test's assembly
// identity (already loaded — it is the running entry assembly) but whose
// `Lyric.Contract` resources differ by one byte: copy the self image
// verbatim into `ar_ident_a.dll`, and into `ar_ident_b.dll` with the
// 'f' of "formatVersion" inside the contract blob flipped to 'g'.  Read
// the contract from each.  Under the fixed byte-load path the two reads
// reflect each file's own (different) bytes; under the old `LoadFrom`
// path both would resolve to the already-loaded entry assembly and
// compare EQUAL — so the inequality assertion is what fails on a
// regression.
func testReadSameIdentityDistinctContent(): Unit {
  val selfBytes = File.readBytesOrPanic(selfDllPath())
  val at = findSubseq(selfBytes, formatVersionNeedle())
  assertTrue(at >= 0, "same_identity_distinct: located 'formatVersion' in contract resource")

  val base = Environment.appBaseDirectory()
  val pA = Path.join(base, "ar_ident_a.dll")
  val pB = Path.join(base, "ar_ident_b.dll")

  val a: List[Byte] = newList()
  val b: List[Byte] = newList()
  var i = 0
  while i < selfBytes.length {
    val bv = selfBytes[i]
    a.add(bv)
    if i == at {
      // selfBytes[at] is 'f' (0x66) by construction — flip to 'g' (0x67)
      // so copy B's contract blob differs while the PE stays loadable
      // and its assembly identity is unchanged.
      b.add(0x67u8)
    } else {
      b.add(bv)
    }
    i = i + 1
  }

  match File.writeBytes(pA, a) {
    case Err(_) -> panic("same_identity_distinct: failed to write copy A")
    case Ok(_) -> ()
  }
  match File.writeBytes(pB, b) {
    case Err(_) -> panic("same_identity_distinct: failed to write copy B")
    case Ok(_) -> ()
  }

  val arA = openAssembly(pA)
  val arB = openAssembly(pB)
  val cA = match tryReadResource(arA, "Lyric.Contract") {
    case None -> panic("same_identity_distinct: expected Some(bytes) from A")
    case Some(x) -> x
  }
  val cB = match tryReadResource(arB, "Lyric.Contract") {
    case None -> panic("same_identity_distinct: expected Some(bytes) from B")
    case Some(x) -> x
  }
  assertTrue(cA.length > 0, "same_identity_distinct: A contract non-empty")
  assertTrue(not bytesEqual(cA, cB), "same_identity_distinct: distinct files yield distinct contract bytes")
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
  testReadSameIdentityDistinctContent()
  println("assembly-resources self-test: ok")
  return 0
}
