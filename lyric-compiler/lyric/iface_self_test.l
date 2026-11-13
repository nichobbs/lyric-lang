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
import Lyric.Lexer
import Lyric.Symbols
import Lyric.Tir
import Lyric.Iface

func path(pkg: in String, a: in String): DefPath {
  topDefPath(pkg, a)
}

func decl(pkg: in String, name: in String, kind: in IfKind, vis: in IfVis): IfDecl {
  IfDecl(path = path(pkg, name), kind = kind, vis = vis, detail = IfDNone)
}

func declWith(pkg: in String, name: in String, kind: in IfKind, detail: in IfDetail): IfDecl {
  IfDecl(path = path(pkg, name), kind = kind, vis = IfPublic, detail = detail)
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
  decls.add(
    IfDecl(
      path = memberDefPath(path("Shapes", "Shape"), "Circle"),
      kind = IfKUnionCase,
      vis = IfPublic,
      detail = IfDNone
    )
  )
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

func enc(i: in Iface, it: in DefPathInterner): slice[Byte] {
  match encodeIface(i, it) {
    case Ok(b) -> b
    case Err(e) -> {
      assertTrue(false, "encode: " + e)
      bytesOf(newList())
    }
  }
}

func decodeErr(bytes: in slice[Byte]): String {
  match decodeIface(bytes, newDefPathInterner()) {
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
  val bytes = enc(sample(), newDefPathInterner())
  val it = newDefPathInterner()
  match decodeIface(bytes, it) {
    case Err(e) -> assertTrue(false, "decode: " + e)
    case Ok(back) -> {
      assertEqual(dumpIface(back, it), dumpIface(sample(), it), "the dump is unchanged")
      assertEqualInt(enc(back, it).length, bytes.length, "the bytes are unchanged")
      assertEqual(ifaceHash(enc(back, it)), ifaceHash(bytes), "the hash is unchanged")
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
  val it = newDefPathInterner()
  match decodeIface(enc(iface, it), it) {
    case Err(e) -> assertTrue(false, "decode: " + e)
    case Ok(back) -> {
      assertEqualInt(back.decls.count, 20, "all twenty kinds")
      assertEqual(dumpIface(back, it), dumpIface(iface, it), "same dump")
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
  val it = newDefPathInterner()
  assertEqual(ifaceHash(enc(a, it)), ifaceHash(enc(b, it)), "same hash")
  assertEqual(dumpIface(a, it), dumpIface(b, it), "same dump")
}

test "encoding twice gives identical bytes" {
  val x = enc(sample(), newDefPathInterner())
  val y = enc(sample(), newDefPathInterner())
  assertEqual(Enc.encodeHex(x), Enc.encodeHex(y), "identical")
}

test "the hash is the SHA-256 of the canonical bytes" {
  val bytes = enc(sample(), newDefPathInterner())
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
  val it = newDefPathInterner()
  assertFalse(ifaceHash(enc(a, it)) == ifaceHash(enc(b, it)), "hash differs")
}

test "the dump is canonical text" {
  val expected = "interface Shapes (format 3)\n" + "verification: @proof_required\n" + "targets: dotnet, jvm\n" +
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
  assertEqual(dumpIface(sample(), newDefPathInterner()), expected, "golden dump")
}

test "malformed files are rejected" {
  val good = enc(sample(), newDefPathInterner())
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

// ── Types and declaration detail (D324) ──────────────────────────────────────
func named(it: in DefPathInterner, pkg: in String, name: in String): Ty {
  TNamed(sym = internDefPath(it, typeDefPath(pkg, name)), args = newList())
}

func owner(it: in DefPathInterner, pkg: in String, name: in String): SymbolId {
  internDefPath(it, typeDefPath(pkg, name))
}

func oneDecl(detail: in IfDetail): Iface {
  val decls: List[IfDecl] = newList()
  decls.add(declWith("T", "X", IfKFunc, detail))
  Iface(header = header("T"), decls = decls, reexports = newList())
}

func roundTrip(iface: in Iface, it: in DefPathInterner): String {
  match encodeIface(iface, it) {
    case Err(e) -> "encode: " + e
    case Ok(bytes) -> {
      val other = newDefPathInterner()
      match decodeIface(bytes, other) {
        case Err(e) -> "decode: " + e
        case Ok(back) -> {
          val a = dumpIface(iface, it)
          val b = dumpIface(back, other)
          if a == b then "" else "dump differs:\n" + a + "\nvs\n" + b
        }
      }
    }
  }
}

func valueOf(ty: in Ty): IfDetail {
  IfDValue(ty = ty, mutable = false, value = None)
}

func tyCases(it: in DefPathInterner): List[Ty] {
  val ts: List[Ty] = newList()
  ts.add(TPrim(kind = TPInt))
  ts.add(TPrim(kind = TPUnit))
  val elems: List[Ty] = newList()
  elems.add(TPrim(kind = TPString))
  elems.add(named(it, "Shapes", "Shape"))
  ts.add(TTuple(elems = elems))
  ts.add(TNullable(inner = TPrim(kind = TPBool)))
  val ps: List[TParamTy] = newList()
  ps.add(TParamTy(mode = TMIn, ty = TPrim(kind = TPInt)))
  ps.add(TParamTy(mode = TMOut, ty = TPrim(kind = TPString)))
  ps.add(TParamTy(mode = TMInout, ty = TPrim(kind = TPDouble)))
  ts.add(TFunc(params = ps, ret = TNever, isAsync = true))
  ts.add(TArray(len = ALKnown(n = 3), element = TPrim(kind = TPByte)))
  ts.add(TArray(len = ALParam(owner = owner(it, "T", "Buf"), index = 1), element = TPrim(kind = TPChar)))
  ts.add(TArray(len = ALUnsized, element = TPrim(kind = TPLong)))
  ts.add(TSlice(element = TPrim(kind = TPFloat)))
  val args: List[Ty] = newList()
  args.add(TPrim(kind = TPInt))
  args.add(TLen(n = 4))
  ts.add(TNamed(sym = owner(it, "Std.Core", "Result"), args = args))
  ts.add(TNamed(sym = SymbolId(id = -2), args = newList()))
  ts.add(TParam(owner = owner(it, "T", "Box"), index = 0))
  ts.add(tySelfOf(owner(it, "T", "Show")))
  ts.add(
    TRefined(underlying = TPrim(kind = TPInt), lo = Some(value = -5i64), hi = Some(value = 150i64), hiInclusive = true)
  )
  ts.add(
    TRefined(
      underlying = TPrim(kind = TPLong),
      lo = None,
      hi = Some(value = -9223372036854775807i64),
      hiInclusive = false
    )
  )
  ts.add(TLen(n = 0))
  ts.add(TNever)
  ts.add(TException)
  ts.add(TExtern(host = HostTypeRef(name = "System.Math", args = newList())))
  ts.add(TExtern(host = HostTypeRef(name = "java.util.ArrayList", args = args)))
  ts.add(TPrim(kind = TPUInt))
  ts.add(TPrim(kind = TPULong))
  ts.add(TPrim(kind = TPNat))
  ts
}

test "every form of Ty round trips through another interner" {
  val it = newDefPathInterner()
  var n = 0
  for t in tyCases(it) {
    assertEqual(roundTrip(oneDecl(valueOf(t)), it), "", "type case " + toString(n))
    n = n + 1
  }
  assertEqualInt(n, 23, "all type cases ran")
}

test "types are written by DefPath, so ids need not match between compilations" {
  val a = newDefPathInterner()
  internDefPath(a, typeDefPath("Other", "Pad"))
  val ta = named(a, "Shapes", "Shape")
  val b = newDefPathInterner()
  val tb = named(b, "Shapes", "Shape")
  val ia = enc(oneDecl(valueOf(ta)), a)
  val ib = enc(oneDecl(valueOf(tb)), b)
  assertEqual(ifaceHash(ia), ifaceHash(ib), "same hash though the ids differ")
}

test "a function's signature, generic parameters and flags round trip" {
  val it = newDefPathInterner()
  val bounds: List[Ty] = newList()
  bounds.add(named(it, "Std.Core", "Ordered"))
  val tps: List[TTypeParam] = newList()
  tps.add(TTypeParam(name = "T", bounds = bounds, valueTy = None))
  tps.add(TTypeParam(name = "N", bounds = newList(), valueTy = Some(value = TPrim(kind = TPInt))))
  val ps: List[IfParam] = newList()
  ps.add(
    IfParam(
      name = "xs",
      mode = TMIn,
      ty = TSlice(element = TParam(owner = owner(it, "T", "X"), index = 0)),
      hasDefault = false
    )
  )
  ps.add(IfParam(name = "limit", mode = TMIn, ty = TPrim(kind = TPInt), hasDefault = true))
  ps.add(IfParam(name = "sink", mode = TMOut, ty = TPrim(kind = TPString), hasDefault = false))
  val d = IfDFunc(
    typeParams = tps,
    params = ps,
    ret = TNullable(inner = TPrim(kind = TPInt)),
    isAsync = true,
    isAxiom = true,
    isPure = true
  )
  assertEqual(roundTrip(oneDecl(d), it), "", "function")
  val line = dumpIface(oneDecl(d), it)
  assertTrue(
    line.contains(
      "[T: Std.Core::Ordered, N: value Int](xs: in slice[param T::X#0], limit: in Int = <default>, sink: out String): Int? async @axiom @pure"
    ),
    "dump line: " + line
  )
}

test "records, cases, aliases, values and extern types round trip" {
  val it = newDefPathInterner()
  val fs: List[IfField] = newList()
  fs.add(IfField(name = "x", ty = TPrim(kind = TPDouble), mutable = false, hasDefault = false))
  fs.add(IfField(name = "label", ty = TPrim(kind = TPString), mutable = true, hasDefault = true))
  assertEqual(roundTrip(oneDecl(IfDRecord(typeParams = newList(), fields = fs)), it), "", "record")
  assertEqual(roundTrip(oneDecl(IfDCase(fields = fs)), it), "", "case with payload")
  assertEqual(roundTrip(oneDecl(IfDCase(fields = newList())), it), "", "case without payload")
  val tps: List[TTypeParam] = newList()
  tps.add(TTypeParam(name = "T", bounds = newList(), valueTy = None))
  assertEqual(roundTrip(oneDecl(IfDType(typeParams = tps)), it), "", "union")
  assertEqual(
    roundTrip(
      oneDecl(
        IfDAlias(
          typeParams = newList(),
          underlying = TRefined(
            underlying = TPrim(kind = TPInt),
            lo = Some(value = 0i64),
            hi = Some(value = 150i64),
            hiInclusive = true
          )
        )
      ),
      it
    ),
    "",
    "range subtype"
  )
  assertEqual(roundTrip(oneDecl(IfDExtern(typeParams = newList(), host = "System.Math")), it), "", "extern")
  assertEqual(roundTrip(oneDecl(IfDNone), it), "", "none")
}

func litValue(l: in TLit): IfDetail {
  IfDValue(ty = TPrim(kind = TPInt), mutable = false, value = Some(value = l))
}

test "constant values of every literal form round trip exactly" {
  val it = newDefPathInterner()
  assertEqual(roundTrip(oneDecl(litValue(TLInt(value = -9223372036854775807i64))), it), "", "int")
  assertEqual(roundTrip(oneDecl(litValue(TLInt(value = 9223372036854775807i64))), it), "", "int max")
  assertEqual(roundTrip(oneDecl(litValue(TLFloat(value = 0.1))), it), "", "float")
  assertEqual(roundTrip(oneDecl(litValue(TLFloat(value = -2.5e300))), it), "", "float big")
  assertEqual(roundTrip(oneDecl(litValue(TLChar(codepoint = 128512))), it), "", "char")
  assertEqual(roundTrip(oneDecl(litValue(TLString(text = "héllo"))), it), "", "string")
  assertEqual(roundTrip(oneDecl(litValue(TLBool(value = true))), it), "", "bool")
  assertEqual(roundTrip(oneDecl(litValue(TLUnit)), it), "", "unit")
  assertEqual(roundTrip(oneDecl(IfDValue(ty = TPrim(kind = TPInt), mutable = true, value = None)), it), "", "var")
}

test "a type naming a declaration with no DefPath cannot be encoded" {
  val it = newDefPathInterner()
  val fresh = freshSymbolId(it)
  match encodeIface(oneDecl(valueOf(TNamed(sym = fresh, args = newList()))), it) {
    case Ok(_) -> assertTrue(false, "should not encode")
    case Err(e) -> assertTrue(e.contains("no DefPath"), "error: " + e)
  }
}

test "types nested past the limit are rejected" {
  val it = newDefPathInterner()
  var t: Ty = TPrim(kind = TPInt)
  var i = 0
  while i < 250 {
    t = TNullable(inner = t)
    i = i + 1
  }
  val bytes = enc(oneDecl(valueOf(t)), it)
  assertTrue(decodeErr(bytes).contains("nesting"), "deep type")
}

test "the golden dump shows types and detail" {
  val it = newDefPathInterner()
  val fs: List[IfField] = newList()
  fs.add(IfField(name = "radius", ty = TPrim(kind = TPDouble), mutable = false, hasDefault = false))
  val ps: List[IfParam] = newList()
  ps.add(IfParam(name = "s", mode = TMIn, ty = named(it, "Shapes", "Shape"), hasDefault = false))
  val decls: List[IfDecl] = newList()
  decls.add(
    IfDecl(
      path = memberDefPath(path("Shapes", "Shape"), "Circle"),
      kind = IfKUnionCase,
      vis = IfPublic,
      detail = IfDCase(fields = fs)
    )
  )
  decls.add(declWith("Shapes", "Shape", IfKUnion, IfDType(typeParams = newList())))
  decls.add(
    declWith(
      "Shapes",
      "area",
      IfKFunc,
      IfDFunc(
        typeParams = newList(),
        params = ps,
        ret = TPrim(kind = TPDouble),
        isAsync = false,
        isAxiom = false,
        isPure = true
      )
    )
  )
  decls.add(
    declWith(
      "Shapes",
      "Max",
      IfKConst,
      IfDValue(ty = TPrim(kind = TPInt), mutable = false, value = Some(value = TLInt(value = 100i64)))
    )
  )
  val iface = Iface(header = header("Shapes"), decls = decls, reexports = newList())
  val text = dumpIface(iface, it)
  assertTrue(text.contains("  pub const Shapes::Max: Int = 100\n"), text)
  assertTrue(text.contains("  pub union Shapes::Shape\n"), text)
  assertTrue(text.contains("  pub union case Shapes::Shape::Circle(radius: Double)\n"), text)
  assertTrue(text.contains("  pub func Shapes::area(s: in Shapes::Shape): Double @pure\n"), text)
}

func node(ty: in Ty, kind: in TExprKind): TExpr {
  TExpr(id = NodeId(id = 0), ty = ty, span = noSourceSpan(), kind = kind)
}

func intLit(n: in Long): TExpr {
  node(TPrim(kind = TPInt), XLit(lit = TLInt(value = n)))
}

func defaultsFn(it: in DefPathInterner, dflts: in List[Option[TExpr]]): IfDetail {
  val ps: List[IfParam] = newList()
  var i = 0
  for d in dflts {
    ps.add(IfParam(name = "p" + toString(i), mode = TMIn, ty = TPrim(kind = TPInt), hasDefault = isSome(d), dflt = d))
    i = i + 1
  }
  IfDFunc(
    typeParams = newList(),
    params = ps,
    ret = TPrim(kind = TPUnit),
    isAsync = false,
    isAxiom = false,
    isPure = false
  )
}

test "parameter defaults of every carried kind round trip through another interner" {
  val it = newDefPathInterner()
  val listTy = TNamed(sym = owner(it, "Std.Collections", "List"), args = newList())
  val callee = internDefPath(it, typeDefPath("T", "make"))
  val args: List[TArg] = newList()
  args.add(TArgIn(value = intLit(2i64)))
  val targs: List[Ty] = newList()
  targs.add(TPrim(kind = TPString))
  val fields: List[TExpr] = newList()
  fields.add(intLit(1i64))
  val elems: List[TExpr] = newList()
  elems.add(intLit(4i64))
  elems.add(node(TPrim(kind = TPString), XLit(lit = TLString(text = "a"))))
  val host = HostMemberRef(
    owner = HostTypeRef(name = "System.Math", args = newList()),
    name = "Max",
    kind = HMMethod,
    isStatic = true,
    params = newList(),
    ret = TPrim(kind = TPInt)
  )
  val dflts: List[Option[TExpr]] = newList()
  dflts.add(Some(value = intLit(3i64)))
  dflts.add(Some(value = node(listTy, XCall(callee = Direct(sym = callee, typeArgs = targs), args = args))))
  dflts.add(Some(value = node(TPrim(kind = TPInt), XConstruct(sym = callee, fields = fields))))
  dflts.add(Some(value = node(TTuple(elems = newList()), XTuple(elems = elems))))
  dflts.add(Some(value = node(TPrim(kind = TPLong), XConvert(kind = CvWiden(to = TPLong), inner = intLit(5i64)))))
  dflts.add(Some(value = node(TPrim(kind = TPInt), XCall(callee = Extern(member = host), args = newList()))))
  dflts.add(
    Some(
      value = node(TPrim(kind = TPString), XCall(callee = Intrinsic(op = IoBuiltin(name = "toString")), args = args))
    )
  )
  dflts.add(Some(value = node(listTy, XListLit(elems = newList()))))
  dflts.add(Some(value = node(TPrim(kind = TPInt), XGlobal(sym = callee, typeArgs = newList()))))
  dflts.add(None)
  assertEqual(roundTrip(oneDecl(defaultsFn(it, dflts)), it), "", "defaults")
  val line = dumpIface(oneDecl(defaultsFn(it, dflts)), it)
  assertTrue(line.contains("p0: in Int = {3 : Int}"), "a literal default: " + line)
  assertTrue(line.contains("call T::make[String]({2 : Int})"), "a call default: " + line)
  assertTrue(line.contains("p9: in Int = <default>"), "a default not recorded: " + line)
}

test "a default of a kind the interface cannot record fails the write rather than being dropped" {
  val it = newDefPathInterner()
  val x = intLit(1i64)
  val lam = node(TPrim(kind = TPInt), XIf(cond = x, thenBranch = x, elseBranch = Some(value = x)))
  assertFalse(defaultCarriable(lam), "an if is not carried")
  assertTrue(defaultCarriable(x), "a literal is")
  val dflts: List[Option[TExpr]] = newList()
  dflts.add(Some(value = lam))
  match encodeIface(oneDecl(defaultsFn(it, dflts)), it) {
    case Err(e) -> assertTrue(e.contains("cannot record"), e)
    case Ok(_) -> assertTrue(false, "the write must fail")
  }
}
