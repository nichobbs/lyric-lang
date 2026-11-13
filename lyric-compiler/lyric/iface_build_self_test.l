//! iface_build_self_test.l - the interface producer (docs/70 §9.2, §9.3, D327).
//!
//! Builds the interface of small checked packages and compares the dump: every
//! declaration kind, generics with bounds, `Self`, ranges, constants, visibility
//! filtering, the round trip through the codec, and agreement of the recorded
//! DefPaths with the resolver's table.
@test_module
package Lyric.IfaceBuildSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Resolve.{renumberNodeIds}
import Lyric.Symbols
import Lyric.Iface
import Lyric.IfaceBuild
import Lyric.TypeChecker

func joinLines(xs: in List[String]): String {
  var s = ""
  for x in xs {
    s = s + x + "\n"
  }
  s
}

func targets(): List[String] {
  val ts: List[String] = newList()
  ts.add("dotnet")
  ts
}

func checked(src: in String): CheckResult {
  val pr = parse(src)
  val res = check(renumberNodeIds(pr.file).file)
  var errs = ""
  for d in res.diagnostics {
    errs = errs + d.code + " " + d.message + "; "
  }
  assertEqual(errs, "", "the source checks")
  res
}

func dumpOf(src: in String): String {
  val res = checked(src)
  match buildIface(res, newList(), targets()) {
    case Ok(iface) -> dumpIface(iface, res.symbols.interner)
    case Err(errs) -> "ERR: " + joinLines(errs)
  }
}

func has(text: in String, line: in String, label: in String) {
  assertTrue(text.contains(line + "\n"), label + ": missing '" + line + "' in\n" + text)
}

test "functions record their signature, modes, async and purity" {
  val text = dumpOf(
    "package P\n\n@pure\npub func add(a: Int, b: Int): Int {\n  a + b\n}\n\npub func fill(buf: inout String, n: Int = 3) {\n}\n\nfunc hidden(): Int {\n  1\n}\n"
  )
  has(text, "  pub func P::add(Int,Int)(a: in Int, b: in Int): Int @pure", "add")
  assertTrue(text.contains("(buf: inout String, n: in Int = {3 : Int}): Unit"), "fill:\n" + text)
  assertFalse(text.contains("hidden"), "a private function is not recorded:\n" + text)
}

test "records, unions, enums and constants" {
  val text = dumpOf(
    "package P\n\npub ref record Point {\n  x: Int\n  var label: String = \"p\"\n}\n\npub union Shape {\n  case Circle(radius: Int)\n  case Empty\n}\n\npub enum Color {\n  case Red\n  case Green\n}\n\npub val Max: Int = 100\n"
  )
  has(text, "  pub record P::Point(x: Int, var label: String = <default>)", "record")
  has(text, "  pub union P::Shape", "union")
  has(text, "  pub union case P::Shape::Circle(radius: Int)", "case")
  has(text, "  pub enum P::Color", "enum")
  has(text, "  pub enum case P::Color::Red()", "enum case")
  has(text, "  pub val P::Max: Int = 100", "val")
}

test "generics, bounds and Self" {
  val text = dumpOf(
    "package P\n\npub interface Show {\n  func show(self: in Self): String\n}\n\npub func render[T](x: in T): String\n  where T: Show\n{\n  \"\"\n}\n"
  )
  has(text, "  pub interface P::Show", "interface")
  assertTrue(text.contains("render(T)[T: P::Show](x: in param P::render(T)#0): String"), text)
}

test "distinct types carry their range and aliases their target" {
  val text = dumpOf("package P\n\npub type Age = Int range 0 ..= 150\npub alias Name = String\n")
  has(text, "  pub distinct P::Age = Int range 0 ..= 150", "distinct")
  has(text, "  pub alias P::Name = String", "alias")
}

test "the interface round trips and agrees with the resolver" {
  val res = checked(
    "package P\n\npub record Box[T] {\n  value: T\n}\n\npub func make[T](v: in T): Box[T] {\n  Box(value = v)\n}\n\nfunc private1(): Int {\n  1\n}\n"
  )
  match buildIface(res, newList(), targets()) {
    case Err(errs) -> assertTrue(false, joinLines(errs))
    case Ok(iface) -> {
      val it = res.symbols.interner
      match encodeIface(iface, it) {
        case Err(e) -> assertTrue(false, e)
        case Ok(bytes) -> {
          val other = newDefPathInterner()
          match decodeIface(bytes, other) {
            case Err(e) -> assertTrue(false, e)
            case Ok(back) -> assertEqual(dumpIface(back, other), dumpIface(iface, it), "round trip")
          }
        }
      }
      val tbl = res.symbols.resolveCtx[0].tbl
      for d in iface.decls {
        val key = defPathKey(d.path)
        match symbolIdOfKey(it, key) {
          case Some(id) -> assertTrue(mapGet(tbl.byId, toString(id.id)) != None, "the resolver declares " + key)
          case None -> assertTrue(false, "the interner knows " + key)
        }
      }
    }
  }
}

test "methods nest under their type" {
  val text = dumpOf(
    "package P\n\npub record Point {\n  x: Int\n\n  func norm(self: in Point): Int {\n    self.x\n  }\n}\n"
  )
  assertTrue(text.contains("pub method P::Point::norm(Point)(self: in P::Point): Int"), text)
}

test "axioms and the package level" {
  val text = dumpOf(
    "package P\n\n@axiom\npub func trusted(x: Int): Int\n\n@proof_required\npub func proven(x: Int): Int {\n  x\n}\n"
  )
  assertTrue(text.contains("pub func P::trusted(Int)(x: in Int): Int @axiom\n"), text)
  assertTrue(text.contains("pub func P::proven(Int)(x: in Int): Int\n"), text)
}

test "extern types are recorded without a modifier" {
  val text = dumpOf("package P\n\nextern type Sb = \"System.Text.StringBuilder\"\n")
  assertTrue(text.contains("pub extern type extern::System.Text.StringBuilder = System.Text.StringBuilder\n"), text)
}

test "an unannotated pub val takes the type the checker found (#7777)" {
  val text = dumpOf(
    "package P\n\nfunc helper(): Int {\n  41\n}\n\npub val Limit = 5\npub val Name = \"p\"\npub val Ratio = -2.5\npub val Answer = helper() + 1\n"
  )
  assertTrue(text.contains("pub val P::Limit: Int = 5\n"), text)
  assertTrue(text.contains("pub val P::Name: String = \"p\"\n"), text)
  assertTrue(text.contains("pub val P::Ratio: Double = bits:-4610560118520545280\n"), text)
  assertTrue(text.contains("pub val P::Answer: Int\n"), text)
}

test "an unrecordable declaration is T0223 and a failed round trip is I0005" {
  val reasons: List[String] = newList()
  reasons.add("P::f: the type did not resolve")
  val lib = checked("package P\n\npub func f(x: Int): Int {\n  x\n}\n")
  val diags = outcomeDiagnostics(IOUnrecordable(reasons = reasons), lib.file)
  assertEqualInt(diags.count, 1, "one diagnostic per reason")
  assertEqual(diags[0].code, "T0223", "the code")
  assertTrue(diags[0].message.contains("P::f"), "it names the declaration")
  val broken = IORoundTrip(message = "the interface read back differs from the one built")
  assertEqual(outcomeDiagnostics(broken, lib.file)[0].code, "I0005", "the round trip")
}

test "a package with main is an executable" {
  val exe = checked("package P\n\nfunc main(): Int {\n  0\n}\n")
  val lib = checked("package P\n\npub func f(x: Int): Int {\n  x\n}\n")
  assertTrue(isExecutable(exe.file), "main makes an executable")
  assertFalse(isExecutable(lib.file), "no main is a library")
}

test "the outcome carries the bytes and their hash" {
  val res = checked("package P\n\npub func f(x: Int): Int {\n  x\n}\n")
  val outs: List[IfaceOutcome] = newList()
  outs.add(buildIfaceOutcome(res, newList(), targets()))
  match outs[0] {
    case IOBuilt(b) -> assertEqual(b.hash, ifaceHash(b.bytes), "the hash is the hash of the bytes")
    case _ -> assertTrue(false, "the library should build")
  }
  assertTrue(builtBytesOf(outs) != None, "the bytes are reachable")
}

test "Self in a type's methods is the type applied to its own parameters" {
  val text = dumpOf(
    "package P\n\npub record Counter {\n  n: Int\n\n  func bump(self: in Self): Self {\n    self\n  }\n}\n\npub record Acc[T] {\n  value: T\n\n  func withValue(self: in Self, v: in T): Self {\n    self\n  }\n}\n"
  )
  assertTrue(text.contains("pub method P::Counter::bump(Self)(self: in P::Counter): P::Counter\n"), text)
  assertTrue(text.contains("(self: in P::Acc[param P::Acc#0], v: in param P::Acc#0): P::Acc[param P::Acc#0]\n"), text)
}

test "a parameter default is recorded as a typed expression and reads back (D460)" {
  val text = dumpOf(
    "package P\n\npub record Pt {\n  x: Int\n  y: Int\n}\n\npub func zero(): Int {\n  0\n}\n\npub func scale(a: Int = zero(), b: Long = 4, c: Pt = Pt(x = 1, y = 2), d: String = \"s\"): Int {\n  a\n}\n"
  )
  assertTrue(text.contains("a: in Int = {call P::zero()[]() : Int}"), "a call default:\n" + text)
  assertTrue(
    text.contains("b: in Long = {4 : Int}"),
    "a literal default keeps its own type; the call widens it:\n" + text
  )
  assertTrue(
    text.contains("c: in P::Pt = {new P::Pt({1 : Int}, {2 : Int}) : P::Pt}"),
    "a construction default:\n" + text
  )
  assertTrue(text.contains("d: in String = {\"s\" : String}"), "a string default:\n" + text)
}

test "a method default is recorded under the method's key" {
  val text = dumpOf(
    "package P\n\npub record Acc {\n  n: Int\n  func add(self: in Acc, k: Int = 1): Int { self.n + k }\n}\n"
  )
  assertTrue(text.contains("k: in Int = {1 : Int}"), "a method default:\n" + text)
}
