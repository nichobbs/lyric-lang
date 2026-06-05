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
//! Boolean composition (`any` / `all` / `not`) and statement-level
//! gating remain v1.1 scope per the design note's scope cut.
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

// Walk an item's annotations and decide whether it survives erasure.
// Returns (keep, diagnostics).
func classifyAnnotations(active: in List[String], declared: in List[String], anns: in List[Annotation]): ClassifyOut {
  val diags: List[Diagnostic] = newList()
  var keep = true
  var i = 0
  while i < anns.count {
    val a = anns[i]
    if isCfgAnnotation(a) {
      // v1 only accepts a single `feature = "X"` argument.  Anything
      // else is malformed; we surface an F0012 diagnostic but treat
      // the item as KEPT (less confusing than silent erasure on a typo).
      val malformedMsg = "@cfg accepts a single 'feature = \"X\"' argument in v1 (boolean composition is deferred)"
      if a.args.count != 1 {
        diags.add(errorDiagnostic("F0012", malformedMsg, a.span))
      } else {
        match a.args[0] {
          case AAName(argName, value, _) -> {
            if argName != "feature" {
              diags.add(errorDiagnostic("F0012", malformedMsg, a.span))
            } else {
              match value {
                case AVString(featName, _) -> {
                  if declared.count > 0 and not listContains(declared, featName) {
                    diags.add(
                      warningDiagnostic(
                        "F0013",
                        "feature '" + featName + "' is not declared in the manifest's [features] section",
                        a.span
                      )
                    )
                  }
                  if not listContains(active, featName) {
                    keep = false
                  }
                }
                case _ -> diags.add(errorDiagnostic("F0012", malformedMsg, a.span))
              }
            }
          }
          case _ -> diags.add(errorDiagnostic("F0012", malformedMsg, a.span))
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

/// Apply `@cfg`-driven erasure to a parsed `SourceFile`.  Items annotated
/// with one or more `@cfg(feature = "X")` annotations are dropped when
/// any predicate evaluates to false against `active`.  Annotations on
/// the file itself (`fileAnnotations`) are processed first: a false
/// predicate there erases every item in the file (the file is treated
/// as not present).
pub func applyCfgErasure(active: in List[String], declared: in List[String], sf: in SourceFile): CfgErasureResult {
  val allDiags: List[Diagnostic] = newList()

  val fileClass = classifyAnnotations(active, declared, sf.fileAnnotations)
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
    val cls = classifyAnnotations(active, declared, it.annotations)
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
