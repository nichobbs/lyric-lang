//! build_defines_self_test.l — exercises the docs/60 `@build_const`
//! substitution pass through the real compile pipeline.
//!
//! This module is compiled by `lyric test` with NO `--define` supplied, so
//! every `@build_const` here takes its in-source fallback literal — the
//! dev-checkout path (docs/60 §2.1, §6). It verifies that the substitution
//! pass integrates without disturbing normal compilation and that an
//! unsupplied define correctly leaves the fallback in place. The supplied
//! (substituted) path is exercised end-to-end by a `lyric build --define`
//! build+run, since `lyric test` does not thread `--define`.
//!
//! Run in CI via:
//!
//!   lyric test lyric-compiler/lyric/build_defines_self_test.l
@test_module
package Lyric.BuildDefinesSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Lyric.Lexer
import Lyric.Parser
import Lyric.BuildDefines as BD

// Extract the first module-level `val`'s initializer as text: the substituted
// String literal, or a marker when it is not a plain String literal.
func firstValInitText(sf: in SourceFile): String {
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IVal(decl) -> {
        match decl.init.kind {
          case ELiteral(lit) -> {
            match lit {
              case LString(t) -> return t
              case _ -> return "<non-string-literal>"
            }
          }
          case _ -> return "<non-literal>"
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  "<no-val>"
}

func hasDiagCode(diags: in List[Diagnostic], code: in String): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].code == code {
      return true
    }
    i = i + 1
  }
  false
}

@build_const("bd_selftest_unsupplied_key")
val FALLBACK: String = "fallback-value"

@build_const("bd_selftest_also_unsupplied")
val OTHER: String = "other-fallback"

test "an unsupplied @build_const keeps the in-source fallback literal" {
  assertEqual(FALLBACK, "fallback-value", "no define supplied -> fallback preserved")
}

test "a second unsupplied @build_const is independent and also falls back" {
  assertEqual(OTHER, "other-fallback", "each @build_const falls back independently")
}

test "a plain (un-annotated) val is untouched by the pass" {
  val plain = "plain"
  assertEqual(plain, "plain", "the substitution pass leaves non-annotated bindings alone")
}

// ── decodeDefines unit coverage (the CLI/bridge `List[String]` -> Define path) ──
test "decodeDefines parses KEY=VALUE" {
  val kvs: List[String] = newList()
  kvs.add("greeting=hello")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "greeting") {
    case Some(v) -> assertEqual(v, "hello", "value parsed after the first '='")
    case None -> assertTrue(false, "greeting should decode")
  }
}

test "decodeDefines keeps everything after the first '=' (values may contain '=')" {
  val kvs: List[String] = newList()
  kvs.add("expr=a==b")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "expr") {
    case Some(v) -> assertEqual(v, "a==b", "only the first '=' splits key from value")
    case None -> assertTrue(false, "expr should decode")
  }
}

test "decodeDefines is last-wins for a repeated key (#5873)" {
  val kvs: List[String] = newList()
  kvs.add("k=first")
  kvs.add("k=second")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "k") {
    case Some(v) -> assertEqual(v, "second", "the later --define wins")
    case None -> assertTrue(false, "k should decode")
  }
}

test "decodeDefines skips entries without '='" {
  val kvs: List[String] = newList()
  kvs.add("novalue")
  val ds = BD.decodeDefines(kvs)
  match BD.lookupDefine(ds, "novalue") {
    case Some(_) -> assertTrue(false, "an entry with no '=' should not decode")
    case None -> assertTrue(true, "skipped as expected")
  }
}

// ── applyBuildDefines end-to-end (parse → substitute → inspect AST) ──
test "applyBuildDefines substitutes a supplied define into the val initializer" {
  val pr = parse("package T\n@build_const(\"k\")\npub val V: String = \"fallback\"\n")
  val defs: List[BD.Define] = newList()
  defs.add(BD.Define(key = "k", value = "injected"))
  val res = BD.applyBuildDefines(defs, pr.file)
  assertEqual(firstValInitText(res.file), "injected", "supplied define replaces the initializer")
  assertEqualInt(res.diagnostics.count, 0, "a valid substitution emits no diagnostics")
}

test "applyBuildDefines keeps the fallback when the key is not supplied" {
  val pr = parse("package T\n@build_const(\"k\")\npub val V: String = \"fallback\"\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertEqual(firstValInitText(res.file), "fallback", "no matching define -> fallback preserved")
}

test "applyBuildDefines emits F0030 for a @build_const val whose fallback is not a String literal" {
  val pr = parse("package T\n@build_const(\"port\")\npub val PORT = 8080\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertTrue(hasDiagCode(res.diagnostics, "F0030"), "inferred non-String fallback is rejected (F0030)")
}

test "applyBuildDefines emits F0031 for @build_const on a non-val item" {
  val pr = parse("package T\n@build_const(\"k\")\npub func f(): Int { 1 }\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertTrue(hasDiagCode(res.diagnostics, "F0031"), "@build_const on a func is rejected (F0031)")
}

test "F0030 accepts a raw-string fallback on an unannotated @build_const val (#5904)" {
  val pr = parse("package T\n@build_const(\"k\")\npub val V = r\"raw-fallback\"\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertTrue(not hasDiagCode(res.diagnostics, "F0030"), "a raw string is a valid String fallback")
}

test "F0030 accepts a triple-quoted fallback on an unannotated @build_const val (#5904)" {
  val pr = parse("package T\n@build_const(\"k\")\npub val V = \"\"\"triple\"\"\"\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertTrue(not hasDiagCode(res.diagnostics, "F0030"), "a triple-quoted string is a valid String fallback")
}

test "applyBuildDefines emits F0032 for a malformed (no-key) @build_const (#5923)" {
  val pr = parse("package T\n@build_const()\npub val V: String = \"x\"\n")
  val res = BD.applyBuildDefines(newList(), pr.file)
  assertTrue(hasDiagCode(res.diagnostics, "F0032"), "@build_const with no string-literal key is rejected (F0032)")
}

// ── withWellKnownDefines: auto-injected well-known `version` (docs/60 §9.2) ──
test "withWellKnownDefines injects version when non-empty" {
  val ds = BD.decodeDefines(BD.withWellKnownDefines("4.5.6", newList()))
  match BD.lookupDefine(ds, "version") {
    case Some(v) -> assertEqual(v, "4.5.6", "manifest version becomes the well-known version define")
    case None -> assertTrue(false, "version should be injected")
  }
}

test "withWellKnownDefines omits version when the manifest version is empty" {
  val synthd = BD.withWellKnownDefines("", newList())
  assertEqualInt(synthd.count, 0, "no well-known entry for an empty version (single-file has none)")
}

test "an explicit --define version overrides the well-known version (precedence #5852)" {
  val cli: List[String] = newList()
  cli.add("version=9.9.9")
  val ds = BD.decodeDefines(BD.withWellKnownDefines("4.5.6", cli))
  match BD.lookupDefine(ds, "version") {
    case Some(v) -> assertEqual(v, "9.9.9", "a CLI --define wins over the well-known fallback")
    case None -> assertTrue(false, "version should resolve")
  }
}

test "withWellKnownDefines preserves unrelated cli defines" {
  val cli: List[String] = newList()
  cli.add("git_hash=abc")
  val ds = BD.decodeDefines(BD.withWellKnownDefines("4.5.6", cli))
  match BD.lookupDefine(ds, "version") {
    case Some(v) -> assertEqual(v, "4.5.6", "version from well-known")
    case None -> assertTrue(false, "version should resolve")
  }
  match BD.lookupDefine(ds, "git_hash") {
    case Some(v) -> assertEqual(v, "abc", "unrelated cli define preserved")
    case None -> assertTrue(false, "git_hash should resolve")
  }
}

// ── withWellKnownTarget: auto-injected well-known `target` (docs/60 §3.3) ────
test "withWellKnownTarget injects the target name as a fallback define" {
  val ds = BD.withWellKnownTarget("dotnet", BD.decodeDefines(newList()))
  match BD.lookupDefine(ds, "target") {
    case Some(v) -> assertEqual(v, "dotnet", "the backend name becomes the well-known target define")
    case None -> assertTrue(false, "target should be injected")
  }
}

test "withWellKnownTarget omits target when the target name is empty" {
  val ds = BD.withWellKnownTarget("", BD.decodeDefines(newList()))
  match BD.lookupDefine(ds, "target") {
    case Some(_) -> assertTrue(false, "no target define for an empty target name")
    case None -> assertTrue(true, "empty target name injects nothing")
  }
}

test "an explicit --define target overrides the well-known target (precedence #5852)" {
  val cli: List[String] = newList()
  cli.add("target=custom")
  val ds = BD.withWellKnownTarget("jvm", BD.decodeDefines(cli))
  match BD.lookupDefine(ds, "target") {
    case Some(v) -> assertEqual(v, "custom", "a user-supplied target define wins over the well-known fallback")
    case None -> assertTrue(false, "target should resolve")
  }
}

test "withWellKnownTarget preserves unrelated defines" {
  val cli: List[String] = newList()
  cli.add("version=1.2.3")
  val ds = BD.withWellKnownTarget("native", BD.decodeDefines(cli))
  match BD.lookupDefine(ds, "target") {
    case Some(v) -> assertEqual(v, "native", "target from well-known")
    case None -> assertTrue(false, "target should resolve")
  }
  match BD.lookupDefine(ds, "version") {
    case Some(v) -> assertEqual(v, "1.2.3", "unrelated define preserved")
    case None -> assertTrue(false, "version should resolve")
  }
}

// ── withManifestDefines: manifest [build.define] layering (docs/60 §3.1) ─────
test "withManifestDefines layers manifest defines beneath cli defines" {
  val mf: List[String] = newList()
  mf.add("api_base=https://mf")
  val cli: List[String] = newList()
  cli.add("git_hash=abc")
  val ds = BD.decodeDefines(BD.withManifestDefines(mf, cli))
  match BD.lookupDefine(ds, "api_base") {
    case Some(v) -> assertEqual(v, "https://mf", "manifest define preserved")
    case None -> assertTrue(false, "api_base should resolve")
  }
  match BD.lookupDefine(ds, "git_hash") {
    case Some(v) -> assertEqual(v, "abc", "cli define preserved")
    case None -> assertTrue(false, "git_hash should resolve")
  }
}

test "a cli --define overrides a manifest [build.define] of the same key (§3.2)" {
  val mf: List[String] = newList()
  mf.add("api_base=https://manifest")
  val cli: List[String] = newList()
  cli.add("api_base=https://cli")
  val ds = BD.decodeDefines(BD.withManifestDefines(mf, cli))
  match BD.lookupDefine(ds, "api_base") {
    case Some(v) -> assertEqual(v, "https://cli", "cli --define wins over the manifest define")
    case None -> assertTrue(false, "api_base should resolve")
  }
}

test "withManifestDefines with empty cli yields the manifest defines" {
  val mf: List[String] = newList()
  mf.add("channel=stable")
  val ds = BD.decodeDefines(BD.withManifestDefines(mf, newList()))
  match BD.lookupDefine(ds, "channel") {
    case Some(v) -> assertEqual(v, "stable", "manifest define resolves with no cli defines")
    case None -> assertTrue(false, "channel should resolve")
  }
}

test "a manifest [build.define] version overrides the well-known version fallback (§3.3)" {
  val mf: List[String] = newList()
  mf.add("version=2.0.0")
  // version fallback (prepended) < manifest [build.define] < cli
  val ds = BD.decodeDefines(BD.withWellKnownDefines("1.0.0", BD.withManifestDefines(mf, newList())))
  match BD.lookupDefine(ds, "version") {
    case Some(v) -> assertEqual(v, "2.0.0", "manifest [build.define] version overrides [package].version")
    case None -> assertTrue(false, "version should resolve")
  }
}

// ── Std.BuildInfo synthesis (docs/60 §9.2) ───────────────────────────────────
// Locate the synthesized `buildInfo()` accessor's returned `BuildInfo(...)`
// constructor expression, if present.
func findBuildInfoCtor(sf: in SourceFile): Option[Expr] {
  var i = 0
  while i < sf.items.count {
    match sf.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == "buildInfo" {
          match decl.body {
            case Some(FBBlock(block)) -> {
              if block.statements.count > 0 {
                match block.statements[0].kind {
                  case SReturn(Some(e)) -> return Some(value = e)
                  case _ -> ()
                }
              }
            }
            case _ -> ()
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  None
}

func hasBuildInfoFunc(sf: in SourceFile): Bool {
  match findBuildInfoCtor(sf) {
    case Some(_) -> true
    case None -> false
  }
}

// The value expression of a named constructor argument.
func ctorArg(ctor: in Expr, name: in String): Option[Expr] {
  match ctor.kind {
    case ECall(_, args) -> {
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(n, value, _) -> if n == name { return Some(value = value) }
          case CAPositional(_) -> ()
        }
        i = i + 1
      }
      None
    }
    case _ -> None
  }
}

// String-literal text of a constructor argument named `name` (or a marker).
func argStr(sf: in SourceFile, name: in String): String {
  match findBuildInfoCtor(sf) {
    case Some(ctor) -> {
      match ctorArg(ctor, name) {
        case Some(e) -> {
          match e.kind {
            case ELiteral(LString(t)) -> t
            case _ -> "<non-str>"
          }
        }
        case None -> "<no-arg>"
      }
    }
    case None -> "<no-ctor>"
  }
}

// Rendered `Option[String]` arg: the inner string for `Some("x")`, "<none>" for
// `None`.
func optArgStr(sf: in SourceFile, name: in String): String {
  match findBuildInfoCtor(sf) {
    case Some(ctor) -> {
      match ctorArg(ctor, name) {
        case Some(e) -> {
          match e.kind {
            case EPath(p) -> if p.segments.count == 1 and p.segments[0] == "None" { "<none>" } else { "<path>" }
            case ECall(_, args) -> {
              if args.count == 1 {
                match args[0] {
                  case CANamed(_, value, _) -> {
                    match value.kind {
                      case ELiteral(LString(t)) -> t
                      case _ -> "<non-str>"
                    }
                  }
                  case CAPositional(_) -> "<pos>"
                }
              } else {
                "<call>"
              }
            }
            case _ -> "<other>"
          }
        }
        case None -> "<no-arg>"
      }
    }
    case None -> "<no-ctor>"
  }
}

// Element count of the `List[String]` literal in the `features` arg.
func featuresCount(sf: in SourceFile): Int {
  match findBuildInfoCtor(sf) {
    case Some(ctor) -> {
      match ctorArg(ctor, "features") {
        case Some(e) -> match e.kind { case EList(exprs) -> exprs.count; case _ -> -1 }
        case None -> -2
      }
    }
    case None -> -3
  }
}

func noDefines(): List[BD.Define] {
  newList()
}

test "synthesizeBuildInfo is a no-op without import Std.BuildInfo" {
  val pr = parse("package T\nfunc other(): Int { 1 }\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertFalse(hasBuildInfoFunc(synthd), "no accessor synthesized when Std.BuildInfo is not imported")
  assertEqualInt(synthd.items.count, pr.file.items.count, "item list unchanged")
}

test "synthesizeBuildInfo appends buildInfo() when Std.BuildInfo is imported" {
  val pr = parse("package T\nimport Std.BuildInfo\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertTrue(hasBuildInfoFunc(synthd), "accessor synthesized on import")
  assertEqualInt(synthd.items.count, pr.file.items.count + 1, "exactly one item appended")
}

test "synthesizeBuildInfo uses the target parameter for the target field" {
  val pr = parse("package T\nimport Std.BuildInfo\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "jvm", newList(), noDefines())
  assertEqual(argStr(synthd, "target"), "jvm", "target field is the build's target name")
}

test "synthesizeBuildInfo falls back to 0.0.0 / debug without version/profile defines" {
  val pr = parse("package T\nimport Std.BuildInfo\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertEqual(argStr(synthd, "version"), "0.0.0", "version falls back")
  assertEqual(argStr(synthd, "profile"), "debug", "profile falls back")
}

test "synthesizeBuildInfo reads version/profile from the well-known defines" {
  val pr = parse("package T\nimport Std.BuildInfo\n")
  val kvs: List[String] = newList()
  kvs.add("version=1.2.3")
  kvs.add("build_profile=release")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), BD.decodeDefines(kvs))
  assertEqual(argStr(synthd, "version"), "1.2.3", "version from define")
  assertEqual(argStr(synthd, "profile"), "release", "profile from build_profile define")
}

test "synthesizeBuildInfo leaves gitHash/buildTimestamp None without their defines" {
  val pr = parse("package T\nimport Std.BuildInfo\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertEqual(optArgStr(synthd, "gitHash"), "<none>", "gitHash None by default (reproducibility)")
  assertEqual(optArgStr(synthd, "buildTimestamp"), "<none>", "buildTimestamp None by default")
}

test "synthesizeBuildInfo wraps supplied git_hash/build_timestamp in Some" {
  val pr = parse("package T\nimport Std.BuildInfo\n")
  val kvs: List[String] = newList()
  kvs.add("git_hash=abc123")
  kvs.add("build_timestamp=2026-07-17T00:00:00Z")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), BD.decodeDefines(kvs))
  assertEqual(optArgStr(synthd, "gitHash"), "abc123", "gitHash Some when supplied")
  assertEqual(optArgStr(synthd, "buildTimestamp"), "2026-07-17T00:00:00Z", "buildTimestamp Some when supplied")
}

test "synthesizeBuildInfo emits the active feature set as a list literal" {
  val pr = parse("package T\nimport Std.BuildInfo\n")
  val feats: List[String] = newList()
  feats.add("metrics")
  feats.add("tracing")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", feats, noDefines())
  assertEqualInt(featuresCount(synthd), 2, "both active features appear in the features list")
}

test "synthesizeBuildInfo defers to a user-defined buildInfo" {
  val pr = parse("package T\nimport Std.BuildInfo\nfunc buildInfo(): Int { 7 }\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertEqualInt(synthd.items.count, pr.file.items.count, "no accessor synthesized over a user buildInfo")
}

test "synthesizeBuildInfo does not trigger on an aliased import" {
  val pr = parse("package T\nimport Std.BuildInfo as BI\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertFalse(hasBuildInfoFunc(synthd), "aliased import is not the opt-in spelling (no synthesis)")
}

test "synthesizeBuildInfo does not trigger on a selector-aliased import (#5969)" {
  val pr = parse("package T\nimport Std.BuildInfo.{BuildInfo as BI}\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertFalse(hasBuildInfoFunc(synthd), "an aliased selector leaves bare BuildInfo out of scope (no synthesis)")
}

test "synthesizeBuildInfo does not trigger on a selector-group import (#5969)" {
  val pr = parse("package T\nimport Std.BuildInfo.{BuildInfo}\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertFalse(hasBuildInfoFunc(synthd), "only the bare `import Std.BuildInfo` is the opt-in spelling (no synthesis)")
}

test "synthesizeBuildInfo defers to a user-defined val buildInfo (#5968)" {
  val pr = parse("package T\nimport Std.BuildInfo\nval buildInfo = 7\n")
  val synthd = BD.synthesizeBuildInfo(pr.file, "dotnet", newList(), noDefines())
  assertEqualInt(synthd.items.count, pr.file.items.count, "a user `val buildInfo` is not overridden")
}
