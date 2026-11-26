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
import Lyric.PluginExpand as PluginExpand

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

test "a projectable with an invariant gets a tryInto that checks it and returns Err" {
  val r = expand(
    "package P\nopaque type Quota @projectable {\n  used: Int\n  limit: Int\n  invariant: used >= 0 and used <= limit\n}\n"
  )
  assertEqualInt(r.diagnostics.count, 0, "no diagnostics")
  assertTrue(hasFunc(r.file, "QuotaView.tryInto"), "tryInto")
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

test "a field of a generic or qualified type keeps its written type in the view" {
  val r = expand(
    "package P\nimport Std.Core\nopaque type Bag @projectable {\n  names: List[String]\n  tag: Option[Int]\n}\n"
  )
  assertEqualInt(r.diagnostics.count, 0, "the generated source parses")
  assertEqualInt(viewFieldCount(r.file, "BagView"), 2, "both fields")
  assertTrue(hasFunc(r.file, "BagView.tryInto"), "tryInto")
}

test "a file that imports Std.Core through a selector gets the whole import once" {
  val r = expand("package P\nimport Std.Core.{Option}\nopaque type U @projectable {\n  id: Int\n}\n")
  var whole = 0
  for im in r.file.imports {
    if im.path.segments.count == 2 and im.path.segments[1] == "Core" {
      match im.selector {
        case Some(_) -> ()
        case None -> {
          whole = whole + 1
        }
      }
    }
  }
  assertEqualInt(whole, 1, "one whole Std.Core import")
}

func packagesOf(srcs: in List[String]): Map[String, PluginExpand.PluginPackage] {
  val m: Map[String, PluginExpand.PluginPackage] = newMap()
  for src in srcs {
    PluginExpand.collectPluginPackage(parse(src).file, m)
  }
  m
}

func importPaths(file: in SourceFile): List[String] {
  val acc: List[String] = newList()
  for im in file.imports {
    var joined = ""
    for seg in im.path.segments {
      joined = joined + (if joined == "" { "" } else { "." }) + seg
    }
    match im.selector {
      case Some(sel) -> {
        val items: List[ImportItem] = match sel { case ISSingle(item) -> [item]; case ISGroup(xs) -> xs }
        for item in items {
          acc.add(joined + "." + item.name)
        }
      }
      case None -> acc.add(joined)
    }
  }
  acc
}

val otherPkg: String = "package Other\npub opaque type Inner @projectable {\n  v: Int\n}\n"

test "a field typed as another package's projectable, imported by name, projects to its view" {
  val src = "package P\nimport Other.Inner\nopaque type Outer @projectable {\n  label: String\n  inner: Inner\n}\n"
  val r = projectableRewriteFileIn(parse(src).file, packagesOf([otherPkg, src]))
  assertEqualInt(r.diagnostics.count, 0, "no diagnostics")
  assertEqualInt(viewFieldCount(r.file, "OuterView"), 2, "outer view fields")
  assertTrue(hasFunc(r.file, "Outer.toView"), "toView")
  assertFalse(hasFunc(r.file, "OuterView.tryInto"), "a nested projectable suppresses tryInto")
  assertTrue(importPaths(r.file).contains("Other.InnerView"), "the other package's view is imported")
}

test "a field typed as another package's projectable, qualified, projects to the qualified view" {
  val src = "package P\nimport Other\nopaque type Outer @projectable {\n  inner: Other.Inner\n}\n"
  val r = projectableRewriteFileIn(parse(src).file, packagesOf([otherPkg, src]))
  assertEqualInt(r.diagnostics.count, 0, "no diagnostics")
  assertTrue(hasFunc(r.file, "Outer.toView"), "toView")
  assertFalse(hasFunc(r.file, "OuterView.tryInto"), "a nested projectable suppresses tryInto")
  assertFalse(importPaths(r.file).contains("Other.InnerView"), "a qualified use needs no extra import")
}

test "a type of another package that is not projectable keeps its written type" {
  val plain = "package Other\npub opaque type Inner {\n  v: Int\n}\n"
  val src = "package P\nimport Other.Inner\nopaque type Outer @projectable {\n  inner: Inner\n}\n"
  val r = projectableRewriteFileIn(parse(src).file, packagesOf([plain, src]))
  assertTrue(hasFunc(r.file, "OuterView.tryInto"), "no nested projection, tryInto stays")
}
