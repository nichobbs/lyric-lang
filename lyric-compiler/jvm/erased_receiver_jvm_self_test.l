//! erased_receiver_jvm_self_test.l — CI gate for member access on a receiver
//! the JVM backend sees as erased `Object`, and for the bare-name
//! resolutions that went wrong alongside it (#7378).
//!
//! 1. Erased receivers.  A field read or method call whose receiver is an
//!    element of a generic container, a generic call's result, or a chain of
//!    generic record fields (`o.session.model.name` with `o: Out[Model]`)
//!    lowered to `java/lang/Object` and failed J007 ("member cannot be
//!    resolved on an erased receiver").  The type checker now records each
//!    member-access receiver's record/union/opaque/protected class
//!    (`SymbolTable.memberRecvClasses`), the pipeline hands it to the JVM
//!    bridge, and `Jvm.Codegen.narrowErasedReceiverJvm` checkcasts to it.
//! 2. Match-bound list fields.  A union case field declared `List[Prop]`,
//!    bound by a match, lost its element type, so `for p in props { p.name }`
//!    failed J007; `bindCaseField` now records the field's declared
//!    (pre-resolved) instantiation for the bound name.
//! 3. Enum cases sharing a name with another type.  `case Info ->` over an
//!    enum, in a package that also declares a record `Info`, compiled as a
//!    catch-all binding (the bare name resolved to the record, which is not a
//!    union case, and the enum test was skipped), hijacking every later arm.
//!    A scrutinee known to be the enum now decides first.
//!
//! 4. Distinct types.  `b.item.value` with `b: Box[Tagged]`, `type Tagged =
//!    Entry`, resolved `.value` against an unrelated opaque type's `value`
//!    field through the bundle-wide by-name fallback; distinct types are now
//!    recorded receiver classes too (#7439).
//!
//! Cross-package forms of the same bugs (a constructor resolved through a
//! selective import, a dependency's own `@cfg` features) are covered by
//! `emitter_project_self_test.l`.
//!
//!   lyric test --target dotnet lyric-compiler/jvm/erased_receiver_jvm_self_test.l
//!   lyric test --target jvm    lyric-compiler/jvm/erased_receiver_jvm_self_test.l
//!
//! Imports only `Std.*`, so no `LYRIC_LOAD_COMPILER=1` is needed.
@test_module
package Lyric.ErasedReceiverJvmSelfTest

import Std.Core
import Std.Collections
import Std.Testing

record Prop {
  name: String
  value: String
}

union Node {
  case El(kind: String, props: List[Prop])
  case Txt(text: String)
}

record Model {
  name: String
}

record Sess[M] {
  model: M
  version: Int
}

record Out[M] {
  session: Sess[M]
  dropped: Bool
}

record Box[T] {
  item: T
}

record Entry {
  owner: String
  hits: Int
}

record Info {
  text: String
}

type Tagged = Entry

enum Level {
  case Info
  case Warn
  case Fail
}

func levelName(l: in Level): String {
  return match l { case Info -> "info"; case Warn -> "warn"; case Fail -> "fail" }
}

func propText(n: in Node): String {
  return match n {
    case El(_, props) -> {
      var s = ""
      for p in props {
        s = s + p.name + "=" + p.value + ";"
      }
      s
    }
    case Txt(t) -> t
  }
}

func mkOut(m: in Model): Out[Model] {
  return Out(session = Sess(model = m, version = 1), dropped = false)
}

func firstBox[T](xs: in List[T]): Option[Box[T]] {
  for x in xs {
    return Some(value = Box(item = x))
  }
  return None
}

test "a for loop over a match-bound List[Record] field reads each element's fields" {
  val ps: List[Prop] = newList()
  ps.add(Prop(name = "a", value = "1"))
  ps.add(Prop(name = "b", value = "2"))
  assertEqual(propText(El(kind = "row", props = ps)), "a=1;b=2;", "element fields")
}

test "a field chain through generic records narrows at each step" {
  val o: Out[Model] = mkOut(Model(name = "Acme"))
  assertEqual(o.session.model.name, "Acme", "model name through Out[Model].session.model")
  assertEqualInt(o.session.version, 1, "a concrete field of the generic record")
}

test "a generic call's Option result answers isSome and isNone" {
  val xs: List[Int] = newList()
  xs.add(3)
  assertTrue(firstBox(xs).isSome, "some")
  val none: List[Int] = newList()
  assertTrue(firstBox(none).isNone, "none")
}

test "a match binding of a Map lookup reads the record's fields" {
  val m: Map[String, Entry] = newMap()
  m.add("k", Entry(owner = "ada", hits = 4))
  val got = match mapGet(m, "k") { case Some(e) -> e.owner + ":" + e.hits.toString(); case None -> "missing" }
  assertEqual(got, "ada:4", "payload fields")
}

test "an enum case sharing its name with a record is still a case test" {
  assertEqual(levelName(Level.Info), "info", "Info")
  assertEqual(levelName(Level.Warn), "warn", "Warn is not swallowed by the Info arm")
  assertEqual(levelName(Level.Fail), "fail", "Fail")
  assertEqual(Info(text = "t").text, "t", "the record Info still constructs")
}

test "value of a distinct type held in a generic record reads the underlying record" {
  val b: Box[Tagged] = Box(item = Tagged.from(Entry(owner = "lin", hits = 7)))
  assertEqual(b.item.value.owner, "lin", "b.item.value.owner")
  assertEqualInt(b.item.value.hits, 7, "b.item.value.hits")
}
