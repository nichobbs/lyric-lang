//! lyric/cfg.l — compile-time feature gating (#1183 codegen port).
//!
//! Self-hosted port of `bootstrap/src/Lyric.Emitter/Cfg.fs` per
//! `docs/24-build-features.md` (D045).  The v1 surface this module
//! implements:
//!
//!   * `@cfg(feature = "X")` annotations on top-level items.
//!   * Multiple `@cfg` annotations on one item AND together (every
//!     predicate must hold).
//!   * Any `@cfg(...)` whose form is not `feature = "X"` produces
//!     `F0012` (malformed predicate).
//!   * If `declaredFeatures` is non-empty and the named feature is
//!     not declared, emits `F0013` (unknown feature) — typo guard.
//!   * The item is *erased* if any `@cfg` evaluates to false.
//!
//!   * Boolean composition: `@cfg(any(feature = "a", target = "b"))`,
//!     `all(...)` and `not(...)`, nested to any depth.
//!
//! Statement-level gating remains v1.1 scope per the design note's scope cut.
//!
//! Wired into `Msil.Bridge.compileProjectToMsil` as the front-end pass
//! that runs before `checkWithImports`, so feature-bearing requests can
//! use the in-process bridge instead of falling back to the F#
//! `--internal-project-build` subprocess.
package Lyric.Cfg

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ── Public surface ──────────────────────────────────────────────────────────
/// Result of running `applyCfgErasure` over a parsed file: the filtered
/// `SourceFile` plus any diagnostics emitted during evaluation.
pub record CfgErasureResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
  // ── Private helpers ─────────────────────────────────────────────────────────
  // True iff the annotation's name path is exactly `cfg`.
}

func isCfgAnnotation(a: in Annotation): Bool {
  if a.name.segments.count != 1 {
    return false
  }
  a.name.segments[0] == "cfg"
}

// Linear lookup of `needle` in `haystack`.  Active / declared feature
// lists are typically tiny (~5 entries in practice), so a hash-set is
// overkill — and `Std.Collections.Map` keying on Object makes string
// keys awkward to round-trip through `containsKey`.
func listContains(haystack: in List[String], needle: in String): Bool {
  var i = 0
  while i < haystack.count {
    if haystack[i] == needle {
      return true
    }
    i = i + 1
  }
  false
}

// Evaluate one predicate argument of an `@cfg(...)`: `feature = "X"`,
// `target = "X"`, or the composites `any(p, ...)` (true if any operand is),
// `all(p, ...)` (true if every operand is) and `not(p)`.  A malformed
// predicate emits `F0012` and evaluates to true, so a typo keeps the item
// rather than silently erasing it.
func evalCfgPredicate(
  active: in List[String],
  declared: in List[String],
  assumeTargets: in Bool,
  arg: in AnnotationArg,
  diags: in List[Diagnostic],
): Bool {
  val malformedMsg = "@cfg accepts 'feature = \"X\"', 'target = \"X\"', or any(...) / all(...) / not(...) of those"
  match arg {
    case AAName(argName, value, span) -> {
      if argName != "feature" and argName != "target" {
        diags.add(errorDiagnostic("F0012", malformedMsg, span))
        return true
      }
      match value {
        case AVString(rawName, _) -> {
          // A caller that only wants the predicate's diagnostics
          // (`fileCfgDiagnostics`) treats every `target = "X"` as active.
          if argName == "target" and assumeTargets {
            return true
          }
          // `@cfg(target = "native")` resolves against the
          // pseudo-feature `target.native` the CLI injects into
          // the active set (D-N-013); targets are never declared
          // in [features], so the F0013 typo guard only applies
          // to real features.
          val featName = if argName == "target" { "target." + rawName } else { rawName }
          if argName == "feature" and declared.count > 0 and not listContains(declared, featName) {
            diags.add(
              warningDiagnostic("F0013", "feature '" + featName + "' is not declared in the manifest's [features] section", span)
            )
          }
          listContains(active, featName)
        }
        case _ -> {
          diags.add(errorDiagnostic("F0012", malformedMsg, span))
          true
        }
      }
    }
    case AACall(name, operands, span) -> {
      if name == "not" {
        if operands.count != 1 {
          diags.add(errorDiagnostic("F0012", "not(...) in @cfg takes exactly one predicate", span))
          return true
        }
        return not evalCfgPredicate(active, declared, assumeTargets, operands[0], diags)
      }
      if name != "any" and name != "all" {
        diags.add(errorDiagnostic("F0012", malformedMsg, span))
        return true
      }
      if operands.count == 0 {
        diags.add(errorDiagnostic("F0012", name + "(...) in @cfg needs at least one predicate", span))
        return true
      }
      var anyTrue = false
      var allTrue = true
      for op in operands {
        if evalCfgPredicate(active, declared, assumeTargets, op, diags) {
          anyTrue = true
        } else {
          allTrue = false
        }
      }
      if name == "any" {
        anyTrue
      } else {
        allTrue
      }
    }
    case ABare(_, span) -> {
      diags.add(errorDiagnostic("F0012", malformedMsg, span))
      true
    }
    case ALiteral(_, span) -> {
      diags.add(errorDiagnostic("F0012", malformedMsg, span))
      true
    }
  }
}

// Walk an item's annotations and decide whether it survives erasure.
// Returns (keep, diagnostics).
func classifyAnnotations(
  active: in List[String],
  declared: in List[String],
  assumeTargets: in Bool,
  anns: in List[Annotation],
): ClassifyOut {
  val diags: List[Diagnostic] = newList()
  var keep = true
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if isCfgAnnotation(a) {
      if a.args.count != 1 {
        diags.add(
          errorDiagnostic(
            "F0012",
            "@cfg takes a single predicate: 'feature = \"X\"', 'target = \"X\"', or any(...) / all(...) / not(...) of those",
            a.span
          )
        )
      } else {
        val before = diags.count
        val holds = evalCfgPredicate(active, declared, assumeTargets, a.args[0], diags)
        // A malformed predicate anywhere inside (even under `not`, which
        // would otherwise turn its placeholder `true` into an erasure) keeps
        // the item; the `F0012` it reported fails the build.
        var malformed = false
        var di = before
        while di < diags.count {
          if diags[di].code == "F0012" {
            malformed = true
          }
          di = di + 1
        }
        if not holds and not malformed {
          keep = false
        }
      }
    }
    i = i + 1
  }
  ClassifyOut(keep = keep, diagnostics = diags)
}

record ClassifyOut {
  keep: Bool
  diagnostics: List[Diagnostic]
  // ── Public entry point ─────────────────────────────────────────────────────
}

/// True iff `applyCfgErasure` would erase the WHOLE file — i.e. every
/// `@cfg` annotation on `fileAnnotations` evaluates to a false predicate
/// against `active`/`declared`. Exposed so a caller that must decide
/// something BEFORE running erasure (e.g. `lyric test` deciding whether a
/// `@test_module`'s synthesized entry point is even worth emitting — see
/// #6868) doesn't have to reimplement `classifyAnnotations`.  Malformed
/// `@cfg` predicates are treated as kept (not gated out), matching
/// `classifyAnnotations`'s own "surface F0012, don't silently erase"
/// policy.
pub func isFileCfgGatedOut(
  active: in List[String], declared: in List[String], fileAnnotations: in List[Annotation]
): Bool {
  isItemCfgGatedOut(active, declared, fileAnnotations)
}

/// True iff `applyCfgErasure` would erase an item carrying `annotations`
/// (its own `Item.annotations`, not the file's) against `active`/`declared`.
/// The item-level counterpart of `isFileCfgGatedOut`, with the same
/// malformed-predicate-is-kept policy: `lyric test` uses it to leave an
/// erased `test`/`property` item out of the synthesized runner, which is
/// generated before erasure runs (#7481).
pub func isItemCfgGatedOut(active: in List[String], declared: in List[String], annotations: in List[Annotation]): Bool {
  not classifyAnnotations(active, declared, false, annotations).keep
}

/// A copy of `active` with the target pseudo-feature `target.<name>`
/// appended (D-N-013).  Each backend bridge threads its own target name
/// (`dotnet` / `jvm` / `native`) so `@cfg(target = "X")` items erase
/// correctly on every path without new predicate grammar.
pub func withTargetFeature(active: in List[String], targetName: in String): List[String] {
  val extended: List[String] = newList()
  var i = 0
  while i < active.count {
    extended.add(active[i])
    i = i + 1
  }
  extended.add("target." + targetName)
  extended
}

/// Apply `@cfg`-driven erasure to a parsed `SourceFile`.  Items annotated
/// with one or more `@cfg(feature = "X")` annotations are dropped when
/// any predicate evaluates to false against `active`.  Annotations on
/// the file itself (`fileAnnotations`) are processed first: a false
/// predicate there erases every item in the file (the file is treated
/// as not present).
pub func applyCfgErasure(active: in List[String], declared: in List[String], sf: in SourceFile): CfgErasureResult {
  val allDiags: List[Diagnostic] = newList()

  val fileClass = classifyAnnotations(active, declared, false, sf.fileAnnotations)
  var fi = 0
  while fi < fileClass.diagnostics.count {
    allDiags.add(fileClass.diagnostics[fi])
    fi = fi + 1
  }

  if not fileClass.keep {
    val emptyItems: List[Item] = newList()
    val emptyImports: List[ImportDecl] = newList()
    val emptied = SourceFile(
      moduleDoc = sf.moduleDoc,
      fileAnnotations = sf.fileAnnotations,
      packageDecl = sf.packageDecl,
      imports = emptyImports,
      items = emptyItems,
      span = sf.span
    )
    return CfgErasureResult(file = emptied, diagnostics = allDiags)
  }

  val kept: List[Item] = newList()
  var i = 0
  while i < sf.items.count {
    val it = sf.items[i]
    val cls = classifyAnnotations(active, declared, false, it.annotations)
    var ci = 0
    while ci < cls.diagnostics.count {
      allDiags.add(cls.diagnostics[ci])
      ci = ci + 1
    }
    if cls.keep {
      kept.add(it)
    }
    i = i + 1
  }

  val filtered = SourceFile(
    moduleDoc = sf.moduleDoc,
    fileAnnotations = sf.fileAnnotations,
    packageDecl = sf.packageDecl,
    imports = sf.imports,
    items = kept,
    span = sf.span
  )
  CfgErasureResult(file = filtered, diagnostics = allDiags)
}

/// The `F0012` / `F0013` diagnostics of the file-level `@cfg` annotations in
/// `fileAnnotations`, against the manifest's `declared` features (`F0013` is
/// off when `declared` is empty).  For the multi-file package merge, whose
/// merged unit carries no file-level `@cfg` for `applyCfgErasure` to check.
pub func fileCfgDiagnostics(declared: in List[String], fileAnnotations: in List[Annotation]): List[Diagnostic] {
  classifyAnnotations(declared, declared, true, fileAnnotations).diagnostics
}
