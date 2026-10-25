//! cli_layers_self_test.l — exercises `Lyric.Cli.parseLayerFiles`
//! (cli/cli_layers.l), the parsing step of the project `[layers]` check.
//! A project file that does not parse must surface its own parse
//! diagnostics; before this, the file was silently left out of the layer
//! check, which then reported its package as matching no project package
//! (Y0009) and its importers as breaking rules (Y0002), and those errors
//! stopped the build before the parse error was ever shown.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/cli_layers_self_test.l
@test_module
package Lyric.CliLayersSelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing
import Lyric.Cli as Cli
import Lyric.Emitter as Emitter

val domainSrc = "package Review.Domain\nimport Std.Core\npub record Draft {\n  count: Int\n}\n"

// A match arm whose body is an assignment (P0201), as in the D230 review
// example's `src/logic.l`.
val brokenLogicSrc = "package Review.Logic\nimport Std.Core\nimport Review.Domain\npub func bump(d: in Draft, n: in Option[Int]): Draft {\n  var next = d\n  match n {\n    case Some(k) -> next = next.copy(count = k)\n    case None -> ()\n  }\n  next\n}\n"

val viewSrc = "package Review.View\nimport Std.Core\nimport Review.Logic\npub func label(): String {\n  \"review\"\n}\n"

func pkg(name: in String, path: in String, source: in String): Emitter.ProjectPackage {
  Emitter.ProjectPackage(
    name = name,
    sources = [source],
    paths = [path],
    ioForbiddenReason = "",
    nameFromManifest = true
  )
}

func noFeatures(): List[String] {
  val fs: List[String] = newList()
  fs
}

test "parseLayerFiles: every file parses, every file is returned" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(pkg("Review.Domain", "src/domain.l", domainSrc))
  pkgs.add(pkg("Review.View", "src/view.l", viewSrc))
  match Cli.parseLayerFiles(pkgs, noFeatures(), noFeatures()) {
    case Ok(files) -> {
      assertEqualInt(files.count, 2, "both files are returned")
      assertEqual(files[0].path, "src/domain.l", "first file keeps its path")
      assertEqual(files[1].name, "Review.View", "second file keeps its package")
    }
    case Err(ds) -> assertTrue(false, "unexpected parse error: " + ds[0].diag.code + " " + ds[0].diag.message)
  }
}

test "parseLayerFiles: a file that does not parse returns its parse diagnostics" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(pkg("Review.Domain", "src/domain.l", domainSrc))
  pkgs.add(pkg("Review.Logic", "src/logic.l", brokenLogicSrc))
  pkgs.add(pkg("Review.View", "src/view.l", viewSrc))
  match Cli.parseLayerFiles(pkgs, noFeatures(), noFeatures()) {
    case Ok(_) -> assertTrue(false, "a file with a parse error must not pass the layer parse")
    case Err(ds) -> {
      assertTrue(ds.count > 0, "the parse diagnostics are returned")
      var sawP0201 = false
      for d in ds {
        assertEqual(d.path, "src/logic.l", "only the broken file is reported, under its own path")
        assertTrue(not Str.startsWith(d.diag.code, "Y"), "no layer diagnostic is reported: " + d.diag.code)
        if d.diag.code == "P0201" {
          sawP0201 = true
        }
      }
      assertTrue(sawP0201, "the match-arm parse error P0201 is reported")
    }
  }
}

test "parseLayerFiles: a file with no path is reported under its package name" {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(pkg("Review.Logic", "", brokenLogicSrc))
  match Cli.parseLayerFiles(pkgs, noFeatures(), noFeatures()) {
    case Ok(_) -> assertTrue(false, "a file with a parse error must not pass the layer parse")
    case Err(ds) -> assertEqual(ds[0].path, "Review.Logic", "the package name stands in for a missing path")
  }
}
