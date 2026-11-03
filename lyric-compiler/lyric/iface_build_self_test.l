//! iface_build_self_test.l - the interface producer (docs/70 §9.2, §9.3, D325).
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
  val res = check(pr.file)
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
  assertTrue(text.contains("(buf: inout String, n: in Int = <default>): Unit"), "fill:\n" + text)
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
