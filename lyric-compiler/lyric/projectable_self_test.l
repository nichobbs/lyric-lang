//! projectable_self_test.l — unit tests for `Lyric.Projectable`, the declaration
//! expansion of `@projectable` opaque types (docs/01 2.9, docs/70 7.1).  The
//! runtime behaviour of the generated `toView`/`tryInto` is covered end to end by
//! `msil/msil_self_test_m87.l` and `jvm/projectable_jvm_self_test.l`.
@test_module
package Lyric.Projectable.SelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Projectable

func expand(src: in String): ProjectableResult {
  val pr = parse(src)
  projectableRewriteFile(pr.file)
}

func hasFunc(file: in SourceFile, name: in String): Bool {
  for it in file.items {
    match it.kind {
      case IFunc(d) -> if d.name == name { return true }
      case _ -> ()
    }
  }
  false
}

func viewFieldCount(file: in SourceFile, name: in String): Int {
  for it in file.items {
    match it.kind {
      case IExposedRec(d) -> if d.name == name {
        var n = 0
        for m in d.members {
          match m {
            case RMField(_) -> {
              n = n + 1
            }
            case _ -> ()
          }
        }
        return n
      }
      case _ -> ()
    }
  }
  -1
}

test "a flat projectable gets a view, toView and tryInto" {
  val r = expand("package P\nopaque type User @projectable {\n  id: Int\n  name: String\n}\n")
  assertEqualInt(r.diagnostics.count, 0, "no diagnostics")
  assertEqualInt(viewFieldCount(r.file, "UserView"), 2, "view fields")
  assertTrue(hasFunc(r.file, "User.toView"), "toView")
  assertTrue(hasFunc(r.file, "UserView.tryInto"), "tryInto")
}

test "a hidden field leaves the view and suppresses tryInto" {
  val r = expand("package P\nopaque type Account @projectable {\n  accountId: Int\n  passwordHash: String @hidden\n}\n")
  assertEqualInt(viewFieldCount(r.file, "AccountView"), 1, "hidden field omitted")
  assertTrue(hasFunc(r.file, "Account.toView"), "toView")
  assertFalse(hasFunc(r.file, "AccountView.tryInto"), "no tryInto with a hidden field")
}

test "a nested projectable is projected and suppresses tryInto" {
  val r = expand(
    "package P\nopaque type Inner @projectable {\n  value: Int\n}\nopaque type Outer @projectable {\n  label: String\n  inner: Inner\n}\n"
  )
  assertEqualInt(viewFieldCount(r.file, "OuterView"), 2, "outer view fields")
  assertFalse(hasFunc(r.file, "Inner.tryInto"), "tryInto lives on the view")
  assertTrue(hasFunc(r.file, "InnerView.tryInto"), "inner tryInto")
  assertFalse(hasFunc(r.file, "OuterView.tryInto"), "no tryInto with a nested projectable")
}

test "a projectionBoundary field keeps its type and tryInto" {
  val r = expand(
    "package P\nopaque type Country @projectable {\n  iso: String\n}\nopaque type Address @projectable {\n  city: String\n  country: Country @projectionBoundary\n}\n"
  )
  assertTrue(hasFunc(r.file, "AddressView.tryInto"), "boundary field does not suppress tryInto")
}

test "a type that is not projectable is left alone" {
  val r = expand("package P\nopaque type Plain {\n  id: Int\n}\n")
  assertEqualInt(r.diagnostics.count, 0, "no diagnostics")
  assertEqualInt(viewFieldCount(r.file, "PlainView"), -1, "no view")
  assertFalse(hasFunc(r.file, "Plain.toView"), "no toView")
}

test "a generic projectable is not projected" {
  val r = expand("package P\nopaque type Box[T] @projectable {\n  v: T\n}\n")
  assertEqualInt(viewFieldCount(r.file, "BoxView"), -1, "no view")
}
