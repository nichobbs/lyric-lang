//! Tests for `import extern` syntax (docs/47).
//! Verifies the parser correctly recognizes and parses external type imports.

@test_module
package Lyric.ImportExternTest

import Std.Core
import Lyric.Parser

test "parse simple import extern" {
  val src = "package Test\nimport extern System.Net.Http.{HttpClient}\nfunc main(): Int { 0 }"
  val result = parse(src)
  assertTrue(result.diagnostics.count == 0, "parse without errors")
  assertTrue(result.file.imports.count == 1, "have one import")
  val imp = result.file.imports[0]
  assertTrue(imp.isExtern, "import marked as extern")
}

test "parse import extern with alias" {
  val src = "package Test\nimport extern System.Net.Http.{HttpClient as Client}\nfunc main(): Int { 0 }"
  val result = parse(src)
  assertTrue(result.diagnostics.count == 0, "parse without errors")
  val imp = result.file.imports[0]
  assertTrue(imp.isExtern, "import marked as extern")
  match imp.selector {
    case Some(sel) -> {
      match sel {
        case ISGroup(items) -> {
          assertTrue(items.count > 0, "has items in group")
          val item = items[0]
          assertTrue(item.asAlias.isSome, "item has alias")
        }
        case ISSingle(_) -> {
          assertTrue(false, "expected ISGroup, got ISSingle")
        }
      }
    }
    case None -> {
      assertTrue(false, "selector should be some")
    }
  }
}

test "parse import extern with multiple types" {
  val src = "package Test\nimport extern System.Net.Http.{HttpClient, HttpRequestMessage as Req}\nfunc main(): Int { 0 }"
  val result = parse(src)
  assertTrue(result.diagnostics.count == 0, "parse without errors")
  val imp = result.file.imports[0]
  assertTrue(imp.isExtern, "import marked as extern")
  match imp.selector {
    case Some(sel) -> {
      match sel {
        case ISGroup(items) -> {
          assertTrue(items.count == 2, "have two items")
        }
        case ISSingle(_) -> {
          assertTrue(false, "expected ISGroup, got ISSingle")
        }
      }
    }
    case None -> {
      assertTrue(false, "selector should be some")
    }
  }
}

test "regular import should not be extern" {
  val src = "package Test\nimport Std.Core.{Option}\nfunc main(): Int { 0 }"
  val result = parse(src)
  assertTrue(result.diagnostics.count == 0, "parse without errors")
  val imp = result.file.imports[0]
  assertTrue(not imp.isExtern, "regular import not extern")
}
