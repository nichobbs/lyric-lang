//! layers_self_test.l — `Lyric.Layers`: the `[layers]` checker (docs/65 §5,
//! D149).  Builds layer configurations from manifest text and checks parsed
//! packages against them, asserting on the diagnostic codes.
//!
//! Run via `make self-test NAME=layers`.
@test_module
package Lyric.Layers.SelfTest

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.Manifest
import Lyric.Layers
import Lyric.TypeChecker as TC
import Lyric.Pipeline as Pipe

func src(path: in String, text: in String): LayerPackage {
  val pr = parse(text)
  if pr.diagnostics.count > 0 {
    panic("test source " + path + " does not parse: " + pr.diagnostics[0].message)
  }
  LayerPackage(name = modulePathJoin(pr.file.packageDecl.path.segments), path = path, file = pr.file)
}

func section(toml: in String): LayersSection {
  match parseManifest("[package]\nname = \"app\"\nversion = \"1.0.0\"\n" + toml, "<test>") {
    case Ok(m) -> match m.layers { case Some(l) -> l; case None -> panic("no [layers] in test manifest") }
    case Err(_) -> panic("test manifest does not parse")
  }
}

func config(toml: in String): LayerConfig {
  match resolveLayerConfig(section(toml)) {
    case Ok(c) -> c
    case Err(ds) -> panic("layer config rejected: " + ds[0].diag.message)
  }
}

func configErrors(toml: in String): List[String] {
  match resolveLayerConfig(section(toml)) {
    case Ok(_) -> newList()
    case Err(ds) -> codesOf(ds)
  }
}

func codesOf(ds: in List[LayerDiagnostic]): List[String] {
  val codes: List[String] = newList()
  for d in ds {
    codes.add(d.diag.code)
  }
  codes
}

func codesText(ds: in List[LayerDiagnostic]): String {
  var s = ""
  for d in ds {
    s = s + d.diag.code + " " + d.path + ": " + d.diag.message + "\n"
  }
  s
}

func stdClasses(): Map[String, String] {
  val m: Map[String, String] = newMap()
  m["Std.Core"] = "pure"
  m["Std.Collections"] = "pure"
  m["Std.String"] = "pure"
  m["Std.Time"] = "pure"
  m["Std.File"] = "io"
  m["Std.Http"] = "io"
  m["Ui.Core"] = "pure"
  m["Ui.Widgets"] = "pure"
  m["Ui.Host"] = "io"
  m
}

val uiToml = "[layers]\npreset = \"ui\"\n[layers.packages]\n\"Shop.Domain\" = \"domain\"\n\"Shop.Ports\" = \"ports\"\n\"Shop.Screens.*.Logic\" = \"logic\"\n\"Shop.Screens.*.Effects\" = \"effects\"\n\"Shop.Screens.*.View\" = \"view\"\n"

func domain(): LayerPackage {
  src("domain.l", "package Shop.Domain\nimport Std.Core\npub record Item {\n  name: String\n}\n")
}

// Checks against the ui manifest.  Most tests supply only the packages
// they need, so the manifest's other entries match nothing; that
// diagnostic has its own test and is dropped here.
func check(pkgs: in List[LayerPackage]): List[LayerDiagnostic] {
  val kept: List[LayerDiagnostic] = newList()
  for d in checkLayers(config(uiToml), pkgs, stdClasses()) {
    if not (d.path == "" and Str.contains(d.diag.message, "matches no package")) {
      kept.add(d)
    }
  }
  kept
}

func onlyCode(ds: in List[LayerDiagnostic], code: in String, what: in String): Unit {
  assertEqualInt(ds.count, 1, what + ": one diagnostic, got:\n" + codesText(ds))
  if ds.count == 1 {
    assertEqual(ds[0].diag.code, code, what + ": " + ds[0].diag.message)
  }
}

// ─── patterns ────────────────────────────────────────────────────────────────
test "package patterns: * is one segment, a final ** is one or more" {
  assertTrue(packageMatches("Shop.Screens.*.Logic", "Shop.Screens.Edit.Logic"), "* matches one segment")
  assertFalse(packageMatches("Shop.Screens.*.Logic", "Shop.Screens.A.B.Logic"), "* is only one segment")
  assertFalse(packageMatches("Shop.*", "Shop"), "* needs a segment")
  assertTrue(packageMatches("Ui.**", "Ui.Host.Web"), "** spans segments")
  assertTrue(packageMatches("Ui.**", "Ui.Core"), "** matches one segment")
  assertFalse(packageMatches("Ui.**", "Ui"), "** needs at least one segment")
  assertTrue(packageMatches("Ui", "Ui"), "exact")
  assertFalse(packageMatches("Ui", "Ui.Core"), "exact does not match a child")
}

// ─── the ui preset ──────────────────────────────────────────────────────────
test "a well-layered screen passes" {
  val pkgs: List[LayerPackage] = [
    domain(),
    src(
      "ports.l",
      "package Shop.Ports\nimport Std.Core\nimport Shop.Domain\npub interface Repo {\n  async func load(): Item\n}\n"
    ),
    src(
      "logic.l",
      "package Shop.Screens.Edit.Logic\nimport Std.Collections\nimport Std.Time\nimport Shop.Domain\nimport Ui.Core.{Step}\npub func update(n: in Int): Int = n\n"
    ),
    src(
      "effects.l",
      "package Shop.Screens.Edit.Effects\nimport Std.Http\nimport Shop.Ports\nimport Shop.Screens.Edit.Logic\npub async func run(n: in Int): Int = n\n"
    ),
    src(
      "view.l",
      "package Shop.Screens.Edit.View\nimport Ui.Core\nimport Ui.Widgets\nimport Shop.Screens.Edit.Logic\nimport Shop.Screens.Pick.View\npub func view(n: in Int): Int = n\n"
    ),
    src(
      "pick.l",
      "package Shop.Screens.Pick.View\nimport Ui.Widgets\npub func view(n: in Int): Int = n\n"
    ),
    src(
      "main.l",
      "package Shop.Main\nimport Ui.Host\nimport Std.File\nimport Shop.Screens.Edit.View\nfunc main(): Unit {\n}\n"
    )
  ]
  val ds = check(pkgs)
  assertEqualInt(ds.count, 0, "no diagnostics, got:\n" + codesText(ds))
}

test "logic may not import an io package (Y0001)" {
  val ds = check([domain(), src("logic.l", "package Shop.Screens.Edit.Logic\nimport Std.File\n")])
  onlyCode(ds, "Y0001", "logic imports Std.File")
  assertEqual(ds[0].path, "logic.l", "reported against the importing file")
  assertTrue(Str.contains(ds[0].diag.message, "@io"), ds[0].diag.message)
}

test "logic may not build widgets (Y0001)" {
  onlyCode(
    check([src("logic.l", "package Shop.Screens.Edit.Logic\nimport Ui.Widgets\n")]),
    "Y0001",
    "logic imports Ui.Widgets"
  )
}

test "logic may not import ports or effects (Y0001)" {
  val ds = check(
    [
      src("ports.l", "package Shop.Ports\n"),
      src("effects.l", "package Shop.Screens.Edit.Effects\n"),
      src("logic.l", "package Shop.Screens.Edit.Logic\nimport Shop.Ports\nimport Shop.Screens.Edit.Effects\n")
    ]
  )
  assertEqualInt(ds.count, 2, "two diagnostics, got:\n" + codesText(ds))
  for d in ds {
    assertEqual(d.diag.code, "Y0001", d.diag.message)
  }
}

test "the domain may not see Ui.Core even though it is pure (Y0001)" {
  onlyCode(check([src("domain.l", "package Shop.Domain\nimport Ui.Core\n")]), "Y0001", "domain imports Ui.Core")
}

test "a view may not import ports (Y0001)" {
  onlyCode(
    check(
      [src("ports.l", "package Shop.Ports\n"), src("view.l", "package Shop.Screens.Edit.View\nimport Shop.Ports\n")]
    ),
    "Y0001",
    "view imports ports"
  )
}

test "an extern import is an io import (Y0001)" {
  onlyCode(
    check([src("logic.l", "package Shop.Screens.Edit.Logic\nimport extern System.IO.File as HostFile\n")]),
    "Y0001",
    "logic imports extern"
  )
}

test "an unclassified package is refused from a layer (Y0002)" {
  val ds = check([src("logic.l", "package Shop.Screens.Edit.Logic\nimport Acme.Util\n")])
  onlyCode(ds, "Y0002", "logic imports Acme.Util")
  assertTrue(Str.contains(ds[0].diag.message, "Acme.Util"), ds[0].diag.message)
}

test "an unlayered project package counts by its own class" {
  val ds = check(
    [
      src("util.l", "@pure\npackage Shop.Util\n"),
      src("net.l", "@io\npackage Shop.Net\n"),
      src("raw.l", "package Shop.Raw\n"),
      src("logic.l", "package Shop.Screens.Edit.Logic\nimport Shop.Util\nimport Shop.Net\nimport Shop.Raw\n")
    ]
  )
  assertEqualInt(ds.count, 2, "Net and Raw refused, got:\n" + codesText(ds))
  val codes = codesOf(ds)
  assertEqual(codes[0], "Y0001", "Shop.Net is io")
  assertEqual(codes[1], "Y0002", "Shop.Raw is unclassified")
}

test "unlayered packages may import anything" {
  val ds = check(
    [
      src(
        "main.l",
        "package Shop.Main\nimport Std.File\nimport Acme.Util\nimport extern System.IO.File as F\n"
      )
    ]
  )
  assertEqualInt(ds.count, 0, "app is unrestricted, got:\n" + codesText(ds))
}

test "async func is refused in logic and view, allowed in effects (Y0004)" {
  val ds = check(
    [
      src("logic.l", "package Shop.Screens.Edit.Logic\npub async func load(): Int = 1\n"),
      src(
        "view.l",
        "package Shop.Screens.Edit.View\nrecord R {\n  n: Int\n  async func m(self: in R): Int = 1\n}\n"
      ),
      src("effects.l", "package Shop.Screens.Edit.Effects\npub async func run(): Int = 1\n")
    ]
  )
  assertEqualInt(ds.count, 2, "logic and view, got:\n" + codesText(ds))
  for d in ds {
    assertEqual(d.diag.code, "Y0004", d.diag.message)
  }
}

// ─── annotations ────────────────────────────────────────────────────────────
test "@layer places a package the manifest does not name" {
  val ds = check([src("x.l", "@layer(\"logic\")\npackage Shop.Extra\nimport Std.File\n")])
  onlyCode(ds, "Y0001", "@layer(logic) package imports io")
}

test "@layer that disagrees with the manifest (Y0005)" {
  onlyCode(check([src("d.l", "@layer(\"view\")\npackage Shop.Domain\n")]), "Y0005", "domain declared as view")
}

test "@layer naming an unknown layer (Y0006)" {
  onlyCode(check([src("x.l", "@layer(\"presentation\")\npackage Shop.Extra\n")]), "Y0006", "unknown layer")
}

test "malformed classification annotations (Y0009)" {
  onlyCode(check([src("x.l", "@pure\n@io\npackage Shop.Extra\n")]), "Y0009", "both @pure and @io")
  onlyCode(check([src("x.l", "@layer\npackage Shop.Extra\n")]), "Y0009", "@layer without a name")
  onlyCode(check([src("x.l", "@pure(true)\npackage Shop.Extra\n")]), "Y0009", "@pure with an argument")
}

test "files of one package that disagree on its class (Y0009)" {
  val ds = check([src("a.l", "@pure\npackage Shop.Extra\n"), src("b.l", "@io\npackage Shop.Extra\n")])
  onlyCode(ds, "Y0009", "pure in one file, io in another")
  assertEqual(ds[0].path, "b.l", "reported at the second file")
}

// ─── configuration ──────────────────────────────────────────────────────────
test "an unknown preset or layer name is refused (Y0006)" {
  assertEqual(configErrors("[layers]\npreset = \"mvc\"\n")[0], "Y0006", "unknown preset")
  assertEqual(configErrors("[layers.packages]\n\"A\" = \"core\"\n")[0], "Y0006", "no such layer")
  assertEqual(
    configErrors("[layers.rules]\ncore = { may_import = [\"shell\"] }\n")[0],
    "Y0006",
    "rule names an unknown layer"
  )
  assertEqual(configErrors("[layers.rules]\npure = { may_import = [] }\n")[0], "Y0006", "a class as a layer name")
  assertEqual(
    configErrors("[layers.rules]\ncore = { may_import = [], may_not_import = [\"shell\"] }\n")[0],
    "Y0006",
    "a layer name in may_not_import"
  )
}

test "a manifest entry that matches no package (Y0009)" {
  val ds = checkLayers(config(uiToml + "\"Shop.Admin.*\" = \"view\"\n"), [domain()], stdClasses())
  var found = false
  for d in ds {
    if d.diag.code == "Y0009" and Str.contains(d.diag.message, "Shop.Admin.*") {
      found = true
    }
  }
  assertTrue(found, "unmatched entry reported, got:\n" + codesText(ds))
}

test "equally specific entries naming different layers (Y0009)" {
  val cfg = config(
    "[layers]\npreset = \"ui\"\n[layers.packages]\n\"Shop.*.Logic\" = \"logic\"\n\"Shop.Edit.*\" = \"view\"\n"
  )
  val ds = checkLayers(cfg, [src("l.l", "package Shop.Edit.Logic\n")], stdClasses())
  onlyCode(ds, "Y0009", "ambiguous assignment")
}

test "a more specific entry wins over a glob" {
  val cfg = config(
    "[layers]\npreset = \"ui\"\n[layers.packages]\n\"Shop.*\" = \"domain\"\n\"Shop.Main\" = \"effects\"\n"
  )
  val ds = checkLayers(cfg, [src("m.l", "package Shop.Main\nimport Std.File\n")], stdClasses())
  assertEqualInt(ds.count, 0, "Shop.Main is effects, may import io, got:\n" + codesText(ds))
}

test "custom rules replace a preset layer and add new ones" {
  val cfg = config(
    "[layers]\npreset = \"ui\"\n[layers.packages]\n\"Shop.Core\" = \"core\"\n\"Shop.Screens.*.Logic\" = \"logic\"\n[layers.rules]\ncore = { may_import = [\"pure\"], async = false }\nlogic = { may_import = [\"core\", \"pure\", \"Ui.Core\"], may_not_import = [\"Std.Time\"] }\n"
  )
  val ds = checkLayers(
    cfg,
    [
      src("core.l", "package Shop.Core\n"),
      src(
        "logic.l",
        "package Shop.Screens.Edit.Logic\nimport Shop.Core\nimport Ui.Core\nimport Std.Time\npub async func ok(): Int = 1\n"
      )
    ],
    stdClasses()
  )
  onlyCode(ds, "Y0001", "Std.Time denied by pattern; async now allowed in logic")
}

test "a specific allow beats a broader deny" {
  val cfg = config(
    "[layers.packages]\n\"Shop.Core\" = \"core\"\n[layers.rules]\ncore = { may_import = [\"Acme.Util\"], may_not_import = [\"Acme.**\"] }\n"
  )
  val ds = checkLayers(cfg, [src("c.l", "package Shop.Core\nimport Acme.Util\nimport Acme.Net\n")], stdClasses())
  onlyCode(ds, "Y0001", "Acme.Net denied, Acme.Util allowed")
  assertTrue(Str.contains(ds[0].diag.message, "Acme.Net"), ds[0].diag.message)
}

// ─── type-level rules (Lyric.Pipeline.effectDiagnostics) ─────────────────────
func effectCodes(source: in String, layerReason: in String): List[String] {
  val pr = parse(source)
  if pr.diagnostics.count > 0 {
    panic("test source does not parse: " + pr.diagnostics[0].message)
  }
  val res = TC.check(pr.file)
  val codes: List[String] = newList()
  for d in Pipe.effectDiagnostics(pr.file, res.symbols, layerReason) {
    codes.add(d.code)
  }
  codes
}

func countCode(codes: in List[String], code: in String): Int {
  var n = 0
  for c in codes {
    if c == code {
      n = n + 1
    }
  }
  n
}

val ioSource = "package P\n@io\nfunc now(): Int = 1\nfunc tick(): Int = now() + 1\n@io\nfunc wrapped(): Int = now()\n"

test "an unclassified package with no layer may call @io functions" {
  assertEqualInt(effectCodes(ioSource, "").count, 0, "no rule applies")
}

test "a @pure package calls @io only from its own @io functions (Y0003)" {
  val codes = effectCodes("@pure\n" + ioSource, "")
  assertEqualInt(codes.count, 1, "only tick's call")
  assertEqual(codes[0], "Y0003", "Y0003")
}

test "a package in an io-free layer may not call @io at all (Y0003)" {
  val codes = effectCodes(ioSource, "layer 'logic'")
  assertEqualInt(countCode(codes, "Y0003"), 2, "tick's and wrapped's calls")
}

val protectedSource = "package P\nprotected type Counter {\n  var n: Int = 0\n  entry bump(): Unit {\n    n = n + 1\n  }\n  func get(): Int = n\n}\nval shared = Counter()\nfunc touch(c: in Counter): Int {\n  c.bump()\n  c.get()\n}\n"

test "protected state in an io-free layer: entries (Y0008) and module values (Y0007)" {
  val codes = effectCodes(protectedSource, "layer 'view'")
  assertEqualInt(countCode(codes, "Y0008"), 1, "the entry call, not the func")
  assertEqualInt(countCode(codes, "Y0007"), 1, "the module-level instance")
}

test "protected state in a @pure package is refused too" {
  val codes = effectCodes("@pure\n" + protectedSource, "")
  assertEqualInt(countCode(codes, "Y0008"), 1, "entry call")
  assertEqualInt(countCode(codes, "Y0007"), 1, "module instance")
}

test "protected state is fine where I/O is allowed" {
  assertEqualInt(effectCodes(protectedSource, "").count, 0, "no rule applies")
}
