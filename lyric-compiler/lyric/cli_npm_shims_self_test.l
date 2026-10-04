//! cli_npm_shims_self_test.l — `lyric restore --generate-npm-shims` (docs/35
//! section 9.3, D-progress-1042): the TypeScript declaration scanner, the shim
//! renderer, and the whole flow against a real `npm install` of a local package
//! that ships a `.d.ts`.
//!
//! Needs `npm` and `node` on PATH.  Run via native `lyric test` with
//! LYRIC_LOAD_COMPILER=1 (this file imports the compiler package `Lyric.Cli`):
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/cli_npm_shims_self_test.l
@test_module
package Lyric.CliNpmShimsSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Lyric.Cli as Cli
import Lyric.Manifest as Mf
import Lyric.Parser as Parser

func find(funcs: in List[Cli.DtsFunc], exportName: in String): Option[Cli.DtsFunc] {
  for f in funcs {
    if f.exportName == exportName {
      return Some(value = f)
    }
  }
  None
}

func skipOf(funcs: in List[Cli.DtsFunc], exportName: in String): String {
  match find(funcs, exportName) {
    case Some(f) -> f.skip
    case None -> "<absent>"
  }
}

val sampleDts: String = "// a comment with a ; and a { inside\n/** doc ; */\nexport function greet(name: string, times: number): string;\nexport declare function flag(on: boolean): boolean;\nexport declare function big(x: bigint): bigint;\nexport function log(msg: string): void;\ndeclare function hidden(s: string): string;\ndeclare function renamed(s: string): string;\nexport { renamed as shown };\nexport function over(a: string): string;\nexport function over(a: number): number;\nexport function gen<T>(x: T): T;\nexport function rest(...xs: string[]): string;\nexport function opt(a?: string): string;\nexport function later(a: string): Promise<string>;\nexport function obj(a: { x: number }): string;\nexport interface Thing { a: string; b(x: number): void }\nexport declare namespace NS { function inner(x: string): string }\nexport const value: string;\nexport default function (n: number): number;\n"

test "stripTsComments and tsStatements: comments go, a semicolon inside one does not split" {
  val stripped = Cli.stripTsComments("a // x; y\nb /* c; d */ e \"// not a comment\";")
  assertFalse(Str.contains(stripped, "x; y"), "line comment removed: " + stripped)
  assertFalse(Str.contains(stripped, "c; d"), "block comment removed: " + stripped)
  assertTrue(Str.contains(stripped, "\"// not a comment\""), "a string literal is kept: " + stripped)
  val stmts = Cli.tsStatements(
    "export function f(a: string): void; export interface I { x: number; y: string } export const c: number;"
  )
  assertEqualInt(
    stmts.count,
    3,
    "three statements, the braces not split on their inner semicolons: " + stmts.count.toString()
  )
}

test "parseDtsFunctions: the plain functions are importable, the rest carry their reason" {
  val fs = Cli.parseDtsFunctions(sampleDts)
  assertEqual(skipOf(fs, "greet"), "", "greet is plain")
  assertEqual(skipOf(fs, "flag"), "", "flag is plain")
  assertEqual(skipOf(fs, "big"), "", "big is plain")
  assertEqual(skipOf(fs, "log"), "", "log is plain")
  assertEqual(skipOf(fs, "shown"), "", "an export { a as b } uses the exported name")
  assertEqual(skipOf(fs, "hidden"), "<absent>", "a declared but unexported function is not a shim")
  assertEqual(skipOf(fs, "renamed"), "<absent>", "the declared name of an aliased export is not exported")
  assertEqual(skipOf(fs, "over"), "overloaded", "overloads are skipped")
  assertEqual(skipOf(fs, "gen"), "generic", "generics are skipped")
  assertEqual(skipOf(fs, "rest"), "a rest parameter", "rest parameters are skipped")
  assertEqual(skipOf(fs, "default"), "", "an anonymous default export is the default export")
  assertEqual(skipOf(fs, "inner"), "<absent>", "a namespace member is not a top-level export")
  match find(fs, "greet") {
    case Some(f) -> {
      assertEqualInt(f.params.count, 2, "greet's parameters")
      assertEqual(f.params[1].tsType, "number", "the second parameter's type")
      assertEqual(f.ret, "string", "greet's result")
    }
    case None -> assertTrue(false, "greet not found")
  }
}

test "parseDtsFunctions: export = names the callable module as its default export" {
  val fs = Cli.parseDtsFunctions("declare function leftPad(s: string, n: number): string;\nexport = leftPad;\n")
  assertEqualInt(fs.count, 1, "one export")
  assertEqual(fs[0].exportName, "default", "an `export =` function is the default export")
  assertEqual(fs[0].declName, "leftPad", "declared name kept")
}

test "renderGeneratedShim: importable functions become host imports, the rest are listed as skipped, and it parses" {
  val e = Mf.NpmEntry(name = "fake-pkg", version = "^1", ident = Mf.npmPackageIdent("fake-pkg"))
  val text = Cli.renderGeneratedShim(e, "index.d.ts", Cli.parseDtsFunctions(sampleDts))
  assertTrue(
    Str.startsWith(text, "@axiom(\"from npm fake-pkg ^1\")\npackage FakePkg\n"),
    "the scaffold header: " + text
  )
  assertTrue(Str.contains(text, Cli.npmShimGeneratedMarker()), "the generated marker")
  assertTrue(
    Str.contains(
      text,
      "@wasmImport(\"npm:fake-pkg\")\npub extern func greet(name: String, times: Double): String = \"greet\""
    ),
    "greet: " + text
  )
  assertTrue(Str.contains(text, "pub extern func flag(on: Bool): Bool = \"flag\""), "flag")
  assertTrue(Str.contains(text, "pub extern func big(x: Long): Long = \"big\""), "big")
  assertTrue(Str.contains(text, "pub extern func log(msg: String) = \"log\""), "a void result is no result")
  assertTrue(
    Str.contains(text, "pub extern func fakePkg(n: Double): Double = \"default\""),
    "the default export is named for the package"
  )
  assertTrue(Str.contains(text, "// skipped over: overloaded"), "overloads are listed")
  assertTrue(Str.contains(text, "// skipped later: returns Promise<string>"), "a Promise result is listed")
  assertTrue(Str.contains(text, "// skipped obj: parameter a: { x: number }"), "an object parameter is listed")
  assertEqualInt(Parser.parse(text).diagnostics.count, 0, "the generated shim is valid Lyric")
}

test "lyricIdent: keywords and odd characters become valid identifiers" {
  assertEqual(Cli.lyricIdent("greet"), "greet", "plain")
  assertEqual(Cli.lyricIdent("then"), "then_", "a keyword")
  assertEqual(Cli.lyricIdent("out"), "out_", "another keyword")
  assertEqual(Cli.lyricIdent("a$b"), "a_b", "a character Lyric identifiers lack")
  assertEqual(Cli.lyricIdent("1st"), "_1st", "a leading digit")
}

func npmTempDir(): String {
  val base = Environment.getVarOrDefault(
    "TMPDIR",
    Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp"))
  )
  val root = Path.join(base, "lyric-npmshims-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func putFile(path: in String, text: in String): Unit {
  match File.writeText(path, text) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

func readOrEmpty(path: in String): String {
  match File.readText(path) {
    case Ok(t) -> t
    case Err(_) -> ""
  }
}

test "generateNpmShims: writes a shim from the package's .d.ts that the build checks accept; hand edits are kept without --force" {
  val dir = npmTempDir()
  val pkgDir = Path.join(dir, "typedpkg")
  match File.createDir(pkgDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create " + pkgDir + ": " + IOError.message(e))
  }
  putFile(
    Path.join(pkgDir, "package.json"),
    "{ \"name\": \"typedpkg\", \"version\": \"1.0.0\", \"type\": \"module\", \"main\": \"index.js\", \"types\": \"index.d.ts\" }\n"
  )
  putFile(
    Path.join(pkgDir, "index.js"),
    "export function add(a, b) { return a + b; }\nexport function shout(s) { return s.toUpperCase(); }\n"
  )
  putFile(
    Path.join(pkgDir, "index.d.ts"),
    "export function add(a: number, b: number): number;\nexport function shout(s: string): string;\nexport function later(s: string): Promise<string>;\n"
  )
  val manifestText = "[package]\nname = \"app\"\nversion = \"0.1.0\"\n\n[npm]\n\"typedpkg\" = \"file:" + pkgDir + "\"\n"
  val m = match Mf.parseManifest(manifestText, Path.join(dir, "lyric.toml")) {
    case Ok(m) -> m
    case Err(e) -> panic("manifest: " + Mf.ManifestError.message(e))
  }
  assertEqualInt(Cli.restoreNpmPackages(m, dir), 0, "restore installs the package and scaffolds the shim")
  val shim = Path.join(Path.join(dir, "_extern_npm"), "typedpkg.l")
  assertTrue(Str.contains(readOrEmpty(shim), "package Typedpkg"), "the scaffold exists first")

  assertEqualInt(Cli.generateNpmShims(m, dir, false), 0, "generation replaces the scaffold")
  val generated = readOrEmpty(shim)
  assertTrue(
    Str.contains(generated, "pub extern func add(a: Double, b: Double): Double = \"add\""),
    "add: " + generated
  )
  assertTrue(Str.contains(generated, "pub extern func shout(s: String): String = \"shout\""), "shout: " + generated)
  assertTrue(Str.contains(generated, "// skipped later: returns Promise<string>"), "later is listed: " + generated)
  assertEqualInt(Cli.checkNpmShims(m, dir).count, 0, "every generated import is a real export of the package")

  assertEqualInt(Cli.generateNpmShims(m, dir, false), 0, "an earlier generated file is replaceable")
  putFile(shim, "@axiom(\"from npm typedpkg file:" + pkgDir + "\")\npackage Typedpkg\n// hand-authored\n")
  assertEqualInt(Cli.generateNpmShims(m, dir, false), 0, "a hand-edited shim is left alone")
  assertTrue(Str.contains(readOrEmpty(shim), "// hand-authored"), "the hand edit survived")
  assertEqualInt(Cli.generateNpmShims(m, dir, true), 0, "--force regenerates it")
  assertTrue(Str.contains(readOrEmpty(shim), "pub extern func add("), "forced regeneration wrote the declarations")
  assertTrue(Cli.npmShimIsPristine(readOrEmpty(shim)), "a fresh generated file is pristine")
  putFile(shim, readOrEmpty(shim) + "\n// declared by hand\n")
  assertEqualInt(Cli.generateNpmShims(m, dir, false), 0, "an addition below the header is a hand edit")
  assertTrue(Str.contains(readOrEmpty(shim), "// declared by hand"), "the hand-added declaration survived a rerun")

  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}
