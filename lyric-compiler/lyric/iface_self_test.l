//! iface_self_test.l - Lyric.Iface codec and model (docs/70 §9.2, §9.6).
//!
//! Covers the LEB128 and string-table primitives, the encode/decode round trip
//! for every declaration kind, determinism (the bytes do not depend on the
//! order a producer collected declarations in), the hash, a golden dump, and
//! the rejection of every kind of malformed file.
@test_module
package Lyric.IfaceSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.Hash as Hash
import Std.Encoding as Enc
import Lyric.Symbols
import Lyric.Iface

func path(pkg: in String, a: in String): DefPath {
  topDefPath(pkg, a)
}

func decl(pkg: in String, name: in String, kind: in IfKind, vis: in IfVis): IfDecl {
  IfDecl(path = path(pkg, name), kind = kind, vis = vis)
}

func header(pkg: in String): IfHeader {
  val against: List[IfBuiltAgainst] = newList()
  against.add(IfBuiltAgainst(pkg = "Std.Core", version = "0.1.0", hash = "aa11"))
  against.add(IfBuiltAgainst(pkg = "Std.Collections", version = "0.1.0", hash = "bb22"))
  val anns: List[String] = newList()
  anns.add("pure")
  val targets: List[String] = newList()
  targets.add("jvm")
  targets.add("dotnet")
  IfHeader(
    formatVersion = ifaceFormatVersion,
    pkg = pkg,
    builtAgainst = against,
    verification = IfProofRequired,
    consumerAnnotations = anns,
    targets = targets
  )
}

func sample(): Iface {
  val decls: List[IfDecl] = newList()
  decls.add(decl("Shapes", "area", IfKFunc, IfPublic))
  decls.add(decl("Shapes", "Shape", IfKUnion, IfPublic))
  decls.add(IfDecl(path = memberDefPath(path("Shapes", "Shape"), "Circle"), kind = IfKUnionCase, vis = IfPublic))
  decls.add(decl("Shapes", "helper", IfKFunc, IfPrivate))
  decls.add(decl("Shapes", "Id", IfKDistinct, IfInternal))
  val re: List[String] = newList()
  re.add("Std.Json")
  re.add("Std.Collections")
  Iface(header = header("Shapes"), decls = decls, reexports = re)
}

func bytesOf(xs: in List[Int]): slice[Byte] {
  val buf: List[Byte] = newList()
  for x in xs {
    buf.add(x.toByte())
  }
  buf.toArray()
}

func decodeErr(bytes: in slice[Byte]): String {
  match decodeIface(bytes) {
    case Ok(_) -> ""
    case Err(e) -> e
  }
}

func readUOf(xs: in List[Int]): Int {
  val r = newIfaceReader(bytesOf(xs))
  readU(r)
}

func encU(n: in Int): List[Int] {
  val w = newIfaceWriter()
  putU(w, n)
  val buf: List[Int] = newList()
  for b in w.buf {
    buf.add(b.toInt().and(255))
  }
  buf
}

test "LEB128 integers use the fewest bytes and round trip" {
  assertEqualInt(encU(0).count, 1, "0")
  assertEqualInt(encU(127).count, 1, "127")
  assertEqualInt(encU(128).count, 2, "128")
  assertEqualInt(encU(16383).count, 2, "16383")
  assertEqualInt(encU(16384).count, 3, "16384")
  assertEqualInt(encU(2147483647).count, 5, "Int max")
  val cases: List[Int] = newList()
  cases.add(0)
  cases.add(1)
  cases.add(127)
  cases.add(128)
  cases.add(300)
  cases.add(16384)
  cases.add(2097152)
  cases.add(2147483647)
  for n in cases {
    assertEqualInt(readUOf(encU(n)), n, "round trip " + toString(n))
  }
}

test "a longer integer encoding than needed is not canonical" {
  val bad: List[Int] = newList()
  bad.add(128)
  bad.add(0)
  val r = newIfaceReader(bytesOf(bad))
  readU(r)
  assertTrue(r.failed, "0x80 0x00 is a padded zero")
}

test "an integer past Int range fails" {
  val big: List[Int] = newList()
  big.add(255)
  big.add(255)
  big.add(255)
  big.add(255)
  big.add(127)
  val r = newIfaceReader(bytesOf(big))
  readU(r)
  assertTrue(r.failed, "needs more than 31 bits")
}

test "strings are interned in order of first use" {
  val w = newIfaceWriter()
  putStr(w, "b")
  putStr(w, "a")
  putStr(w, "b")
  assertEqualInt(w.table.count, 2, "two distinct strings")
  assertEqual(w.table[0], "b", "first use first")
  assertEqual(w.table[1], "a", "second")
  assertEqualInt(w.buf.count, 3, "three references")
}

test "an interface round trips" {
  val bytes = encodeIface(sample())
  match decodeIface(bytes) {
    case Err(e) -> assertTrue(false, "decode: " + e)
    case Ok(back) -> {
      assertEqual(dumpIface(back), dumpIface(sample()), "the dump is unchanged")
      assertEqualInt(encodeIface(back).length, bytes.length, "the bytes are unchanged")
      assertEqual(ifaceHash(encodeIface(back)), ifaceHash(bytes), "the hash is unchanged")
    }
  }
}

func allKinds(): List[IfKind] {
  val ks: List[IfKind] = newList()
  ks.add(IfKFunc)
  ks.add(IfKMethod)
  ks.add(IfKVal)
  ks.add(IfKConst)
  ks.add(IfKRecord)
  ks.add(IfKExposedRecord)
  ks.add(IfKUnion)
  ks.add(IfKEnum)
  ks.add(IfKOpaque)
  ks.add(IfKProtected)
  ks.add(IfKDistinct)
  ks.add(IfKAlias)
  ks.add(IfKInterface)
  ks.add(IfKExternType)
  ks.add(IfKWire)
  ks.add(IfKScope)
  ks.add(IfKConfig)
  ks.add(IfKAspect)
  ks.add(IfKUnionCase)
  ks.add(IfKEnumCase)
  ks
}

test "every declaration kind and visibility round trips" {
  val decls: List[IfDecl] = newList()
  var n = 0
  for k in allKinds() {
    val vis = if n % 3 == 0 then IfPublic else if n % 3 == 1 then IfInternal else IfPrivate
    decls.add(decl("Kinds", "D" + toString(n), k, vis))
    n = n + 1
  }
  val iface = Iface(header = header("Kinds"), decls = decls, reexports = newList())
  match decodeIface(encodeIface(iface)) {
    case Err(e) -> assertTrue(false, "decode: " + e)
    case Ok(back) -> {
      assertEqualInt(back.decls.count, 20, "all twenty kinds")
      assertEqual(dumpIface(back), dumpIface(iface), "same dump")
    }
  }
  var c = 0
  for k in allKinds() {
    match ifKindOfCode(ifKindCode(k)) {
      case Some(back) -> assertEqual(ifKindName(back), ifKindName(k), "kind code " + toString(c))
      case None -> assertTrue(false, "kind code " + toString(c))
    }
    c = c + 1
  }
}

test "the bytes do not depend on collection order" {
  val a = sample()
  val rev: List[IfDecl] = newList()
  var i = a.decls.count - 1
  while i >= 0 {
    rev.add(a.decls[i])
    i = i - 1
  }
  val re: List[String] = newList()
  re.add("Std.Collections")
  re.add("Std.Json")
  val b = Iface(header = a.header, decls = rev, reexports = re)
  assertEqual(ifaceHash(encodeIface(a)), ifaceHash(encodeIface(b)), "same hash")
  assertEqual(dumpIface(a), dumpIface(b), "same dump")
}

test "encoding twice gives identical bytes" {
  val x = encodeIface(sample())
  val y = encodeIface(sample())
  assertEqual(Enc.encodeHex(x), Enc.encodeHex(y), "identical")
}

test "the hash is the SHA-256 of the canonical bytes" {
  val bytes = encodeIface(sample())
  assertEqual(ifaceHash(bytes), Hash.sha256OfBytes(bytes).toLower(), "hash")
  assertEqualInt(ifaceHash(bytes).length, 64, "64 hex digits")
}

test "a different declaration changes the hash" {
  val a = sample()
  val decls: List[IfDecl] = newList()
  for d in a.decls {
    decls.add(d)
  }
  decls.add(decl("Shapes", "extra", IfKVal, IfPublic))
  val b = Iface(header = a.header, decls = decls, reexports = a.reexports)
  assertFalse(ifaceHash(encodeIface(a)) == ifaceHash(encodeIface(b)), "hash differs")
}

test "the dump is canonical text" {
  val expected = "interface Shapes (format 1)\n" + "verification: @proof_required\n" + "targets: dotnet, jvm\n" +
    "annotations: pure\n" +
    "reexports: Std.Collections, Std.Json\n" +
    "built against (2):\n" +
    "  Std.Collections 0.1.0 bb22\n" +
    "  Std.Core 0.1.0 aa11\n" +
    "declarations (5):\n" +
    "  internal distinct Shapes::Id\n" +
    "  pub union Shapes::Shape\n" +
    "  pub union case Shapes::Shape::Circle\n" +
    "  pub func Shapes::area\n" +
    "  private func Shapes::helper\n"
  assertEqual(dumpIface(sample()), expected, "golden dump")
}

test "malformed files are rejected" {
  val good = encodeIface(sample())
  assertTrue(decodeErr(bytesOf(newList())).length > 0, "empty")
  val badMagic: List[Int] = newList()
  badMagic.add(88)
  badMagic.add(89)
  badMagic.add(82)
  badMagic.add(73)
  badMagic.add(1)
  badMagic.add(0)
  assertTrue(decodeErr(bytesOf(badMagic)).length > 0, "bad magic")
  val badVersion: List[Int] = newList()
  badVersion.add(76)
  badVersion.add(89)
  badVersion.add(82)
  badVersion.add(73)
  badVersion.add(99)
  badVersion.add(0)
  assertTrue(decodeErr(bytesOf(badVersion)).length > 0, "version 99")
  val cut: List[Byte] = newList()
  var i = 0
  while i < good.length - 3 {
    cut.add(good[i])
    i = i + 1
  }
  assertTrue(decodeErr(cut.toArray()).length > 0, "truncated")
  val extra: List[Byte] = newList()
  var j = 0
  while j < good.length {
    extra.add(good[j])
    j = j + 1
  }
  extra.add(0.toByte())
  assertTrue(decodeErr(extra.toArray()).length > 0, "trailing byte")
}

test "a corrupt count cannot make the reader loop" {
  val huge: List[Int] = newList()
  huge.add(76)
  huge.add(89)
  huge.add(82)
  huge.add(73)
  huge.add(1)
  huge.add(255)
  huge.add(255)
  huge.add(255)
  huge.add(255)
  huge.add(7)
  assertTrue(decodeErr(bytesOf(huge)).length > 0, "a table count past the data")
}

test "decoding rejects declarations out of canonical order" {
  val a = sample()
  val w = newIfaceWriter()
  putStr(w, "Shapes")
  putU(w, 0)
  putU(w, ifVerifCode(IfRuntimeChecked))
  putU(w, 0)
  putU(w, 0)
  putU(w, 0)
  putU(w, 2)
  putStr(w, "Shapes")
  putU(w, 1)
  putStr(w, "b")
  putU(w, ifKindCode(IfKFunc))
  putU(w, ifVisCode(IfPublic))
  putStr(w, "Shapes")
  putU(w, 1)
  putStr(w, "a")
  putU(w, ifKindCode(IfKFunc))
  putU(w, ifVisCode(IfPublic))
  assertTrue(decodeErr(finishIface(w)).length > 0, "b before a")
}
