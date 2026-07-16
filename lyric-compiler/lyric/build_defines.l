//! lyric/build_defines.l — compile-time value injection (docs/60).
//!
//! The substitution counterpart to `Lyric.Cfg`'s `@cfg` erasure: overwrites a
//! module-level `val` initializer annotated `@build_const("K")` with the
//! `String` value of build define `K`, or leaves the in-source fallback
//! literal untouched when `K` is not supplied. Runs in `pipeParseAndErase`
//! beside `applyCfgErasure` (docs/60 §5).
//!
//! Safety: a define value is inserted only as a `String`-literal AST node
//! post-parse — never re-lexed or re-parsed as Lyric source (docs/60 §8), so
//! there is no grammar-injection surface.
package Lyric.BuildDefines

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser

// ── Public surface ──────────────────────────────────────────────────────────

/// One resolved build define (key/value). The caller precedence-resolves the
/// set before handing it here (CLI over manifest over the well-known defines).
pub record Define {
  key: String
  value: String
}

/// Result of running `applyBuildDefines` over a parsed file: the possibly
/// rewritten `SourceFile` plus any diagnostics emitted during substitution.
pub record BuildDefinesResult {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// Construct the well-known defines the toolchain auto-injects on every build
/// (docs/60 §3.3). `version` / `target` / `build_profile` are deterministic
/// functions of the build configuration, so they preserve reproducibility.
pub func wellKnownDefines(version: in String, target: in String, buildProfile: in String): List[Define] {
  val ds: List[Define] = newList()
  ds.add(Define(key = "version", value = version))
  ds.add(Define(key = "target", value = target))
  ds.add(Define(key = "build_profile", value = buildProfile))
  ds
}

/// Merge two define lists; entries in `override` win over same-key entries in
/// `base`. Used to layer CLI over manifest over well-known.
pub func mergeDefines(base: in List[Define], override: in List[Define]): List[Define] {
  val out: List[Define] = newList()
  var i = 0
  while i < base.count {
    if not hasKey(override, base[i].key) {
      out.add(base[i])
    }
    i = i + 1
  }
  var j = 0
  while j < override.count {
    out.add(override[j])
    j = j + 1
  }
  out
}

// ── Private helpers ─────────────────────────────────────────────────────────

func hasKey(defines: in List[Define], key: in String): Bool {
  var i = 0
  while i < defines.count {
    if defines[i].key == key {
      return true
    }
    i = i + 1
  }
  false
}

/// Linear lookup — the define set is tiny in practice.
pub func lookupDefine(defines: in List[Define], key: in String): Option[String] {
  var i = 0
  while i < defines.count {
    if defines[i].key == key {
      return Some(value = defines[i].value)
    }
    i = i + 1
  }
  None
}

// True iff the annotation's name path is exactly `build_const`.
func isBuildConstAnnotation(a: in Annotation): Bool {
  if a.name.segments.count != 1 {
    return false
  }
  a.name.segments[0] == "build_const"
}

// Extract the string key from `@build_const("K")` — a single positional
// string-literal argument. Returns None for any other argument form (F0032).
func buildConstKey(a: in Annotation): Option[String] {
  if a.args.count != 1 {
    return None
  }
  match a.args[0] {
    case ALiteral(value, _) -> {
      match value {
        case AVString(s, _) -> Some(value = s)
        case _ -> None
      }
    }
    case _ -> None
  }
}

// Pre-typecheck String check: an explicit non-`String` annotation is rejected
// (F0030); an inferred (None) type is accepted because the fallback
// initializer is always a `String` literal, which the substitution preserves.
func valTypeOkForString(decl: in ValDecl): Bool {
  match decl.ty {
    case Some(t) -> isStringTypeExpr(t)
    case None -> true
  }
}

func isStringTypeExpr(t: in TypeExpr): Bool {
  match t.kind {
    case TRef(path) -> path.segments.count == 1 and path.segments[0] == "String"
    case _ -> false
  }
}

func stringLiteralExpr(text: in String, sp: in Span): Expr {
  Expr(kind = ELiteral(lit = LString(text = text)), span = sp)
}

// ── Pass ────────────────────────────────────────────────────────────────────

/// Apply `@build_const` substitution to a parsed file. A module-level `val`
/// annotated `@build_const("K")` has its initializer replaced with a
/// `String`-literal node holding define `K`'s value, or is left untouched
/// when `K` is not in `defines` (the dev-checkout fallback). Emits F0030
/// (non-String val), F0031 (annotation on a non-val item), F0032 (malformed
/// key argument).
pub func applyBuildDefines(defines: in List[Define], sf: in SourceFile): BuildDefinesResult {
  val diags: List[Diagnostic] = newList()
  val outItems: List[Item] = newList()
  var i = 0
  while i < sf.items.count {
    val it = sf.items[i]
    var hasAnn = false
    var malformed = false
    var keyOpt: Option[String] = None
    var annSpan = it.span
    var ai = 0
    while ai < it.annotations.count {
      val a = it.annotations[ai]
      if isBuildConstAnnotation(a) {
        hasAnn = true
        annSpan = a.span
        match buildConstKey(a) {
          case Some(k) -> keyOpt = Some(value = k)
          case None -> malformed = true
        }
      }
      ai = ai + 1
    }
    if not hasAnn {
      outItems.add(it)
    } else {
      match it.kind {
        case IVal(decl) -> {
          if malformed {
            diags.add(errorDiagnostic("F0032", "@build_const requires a single string-literal key, e.g. @build_const(\"version\")", annSpan))
            outItems.add(it)
          } else if not valTypeOkForString(decl) {
            diags.add(errorDiagnostic("F0030", "@build_const may only annotate a String val (docs/60 §4)", annSpan))
            outItems.add(it)
          } else {
            match keyOpt {
              case Some(k) -> {
                match lookupDefine(defines, k) {
                  case Some(v) -> {
                    val newDecl = ValDecl(pattern = decl.pattern, ty = decl.ty, init = stringLiteralExpr(v, decl.init.span), span = decl.span)
                    val newItem = Item(docComments = it.docComments, annotations = it.annotations, visibility = it.visibility, kind = IVal(decl = newDecl), span = it.span)
                    outItems.add(newItem)
                  }
                  case None -> outItems.add(it)
                }
              }
              case None -> outItems.add(it)
            }
          }
        }
        case _ -> {
          diags.add(errorDiagnostic("F0031", "@build_const may only be applied to a module-level val (docs/60 §6)", annSpan))
          outItems.add(it)
        }
      }
    }
    i = i + 1
  }
  val outFile = SourceFile(
    moduleDoc = sf.moduleDoc,
    fileAnnotations = sf.fileAnnotations,
    packageDecl = sf.packageDecl,
    imports = sf.imports,
    items = outItems,
    span = sf.span
  )
  BuildDefinesResult(file = outFile, diagnostics = diags)
}
