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
import Std.String as Str
import Lyric.Lexer
import Lyric.Parser

// ── Public surface ──────────────────────────────────────────────────────────
/// One resolved build define (key/value), decoded from the CLI's
/// `"KEY=VALUE"` strings by `decodeDefines` (last-wins on repeats).
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

/// Prepend the auto-derived well-known `version` define (docs/60 §3, §9.2) as a
/// FALLBACK beneath any caller-supplied `cli` defines: because `decodeDefines`
/// is last-wins and the well-known entry comes first, an explicit
/// `--define version=…` always overrides it. `version` is the manifest's
/// `[package].version`, so this is what populates `BuildInfo.version` (and any
/// `@build_const("version")` val) on a project build without an explicit
/// `--define`. Omitted when empty — single-file builds carry no manifest
/// version, so they keep the deterministic `"0.0.0"` fallback.
///
/// The `build_profile` well-known define (from `--release`) and the manifest
/// `[build.define]` layering remain follow-ups (#5852); the `target` well-known
/// define ships via `withWellKnownTarget` (injected in `pipeParseAndErase`,
/// which already carries `targetName`), and this ships the `version` slice
/// against the project path that consumes it.
pub func withWellKnownDefines(version: in String, cli: in List[String]): List[String] {
  val result: List[String] = newList()
  if version.length > 0 {
    result.add("version=" + version)
  }
  var i = 0
  while i < cli.count {
    result.add(cli[i])
    i = i + 1
  }
  result
}

/// Append the auto-derived well-known `target` define (docs/60 §3.3) as a
/// FALLBACK: added only when the caller has not already supplied a `target`
/// define, so an explicit `--define target=…` still wins. `targetName` is the
/// active backend (`dotnet` / `jvm` / `native`), which is deterministic per
/// build invocation, so injecting it on every build keeps the reproducibility
/// byte-compare intact (docs/60 §8). Injected in `pipeParseAndErase` (which
/// already receives `targetName`), so it lands uniformly on every backend and
/// on both the single-file and project paths — unlike the `version` fallback,
/// which is manifest-sourced and therefore project-only. Operates on the
/// already-decoded `Define` list so it composes after `decodeDefines`'
/// last-wins dedup.
pub func withWellKnownTarget(targetName: in String, defines: in List[Define]): List[Define] {
  if targetName.length == 0 or hasKey(defines, "target") {
    return defines
  }
  val result: List[Define] = newList()
  var i = 0
  while i < defines.count {
    result.add(defines[i])
    i = i + 1
  }
  result.add(Define(key = "target", value = targetName))
  result
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

// Pre-typecheck String check (F0030): an explicit annotation must be `String`;
// with no annotation, the fallback initializer must itself be a `String`
// literal (see the `None` arm).
func valTypeOkForString(decl: in ValDecl): Bool {
  match decl.ty {
    case Some(t) -> isStringTypeExpr(t)
    // No explicit annotation: the fallback initializer must itself be a
    // `String` literal, else substitution would flip the val's inferred type
    // (e.g. `@build_const("port") val PORT = 8080` is `Int` on the fallback
    // but `String` after substitution) — F0030 (docs/60 §4).
    case None -> isStringLiteralInit(decl.init)
  }
}

func isStringLiteralInit(e: in Expr): Bool {
  match e.kind {
    case ELiteral(lit) -> {
      // Every String-literal spelling counts: plain, triple-quoted, and raw
      // are all `String` at the type level (#5904).
      match lit {
        case LString(_) -> true
        case LTripleString(_) -> true
        case LRawString(_) -> true
        case _ -> false
      }
    }
    case _ -> false
  }
}

func isStringTypeExpr(t: in TypeExpr): Bool {
  match t.kind {
    case TRef(path) -> path.segments.count == 1 and path.segments[0] == "String"
    case _ -> false
  }
}

/// Decode a `["KEY=VALUE", ...]` list (the request-carried, cross-package-safe
/// `List[String]` representation) into `Define`s. Later entries override
/// earlier same-key entries (last-wins, matching conventional repeatable-flag
/// precedence). Entries without `=` are skipped (the CLI validates the form).
pub func decodeDefines(kvs: in List[String]): List[Define] {
  val decoded: List[Define] = newList()
  var i = kvs.count - 1
  while i >= 0 {
    match Str.indexOf(kvs[i], "=") {
      case Some(eq) -> {
        val k = Str.substring(kvs[i], 0, eq)
        if k.length > 0 and not hasKey(decoded, k) {
          decoded.add(Define(key = k, value = Str.substring(kvs[i], eq + 1)))
        }
      }
      case None -> ()
    }
    i = i - 1
  }
  decoded
}

func stringLiteralExpr(text: in String, sp: in Span): Expr {
  Expr(kind = ELiteral(lit = LString(text = text)), span = sp)
}

// ── Std.BuildInfo synthesis (docs/60 §9.2) ───────────────────────────────────
// The build-metadata surface. `import Std.BuildInfo` opts a file in; the
// compiler synthesizes a `buildInfo()` accessor into that file (the consumer's
// own package), so each program reports *its own* resolved build metadata, not
// the stdlib's (docs/60 §9.2). The values come from the same resolved-defines
// map plus the target/feature parameters already flowing through
// `pipeParseAndErase`; nothing new is threaded through the backends.
// True iff the file has a bare, unaliased, unselective `import Std.BuildInfo`.
// Both an aliased import (`import Std.BuildInfo as BI`) and a selector-group
// import (`import Std.BuildInfo.{BuildInfo as BI}` or `.{BuildInfo}`) are
// deliberately NOT matched: the synthesized accessor references `BuildInfo`
// unqualified, so it only resolves when the plain import brings the whole
// package's public surface into scope. Under an alias or an aliased selector
// the bare `BuildInfo` name is not in scope, so triggering there would surface
// a confusing error on code the user never wrote. The documented spelling is
// the bare `import Std.BuildInfo` (docs/60 §9.2).
func importsStdBuildInfo(imports: in List[ImportDecl]): Bool {
  var i = 0
  while i < imports.count {
    val imp = imports[i]
    val p = imp.path
    val unaliased = match imp.asAlias { case Some(_) -> false; case None -> true }
    val unselective = match imp.selector { case Some(_) -> false; case None -> true }
    if unaliased and unselective and p.segments.count == 2 and p.segments[0] == "Std" and p.segments[1] == "BuildInfo" {
      return true
    }
    i = i + 1
  }
  false
}

// True iff a module-level `buildInfo` binding already exists — a `func` or a
// `val` — meaning the user opted to define their own, so we leave it untouched
// (no duplicate, no override). The `IConst` arm is defensive AST completeness:
// a module-level `const` item is not producible by the current grammar, but the
// AST variant exists, so it is handled for free rather than silently ignored.
func hasUserBuildInfoDecl(items: in List[Item]): Bool {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> if decl.name == "buildInfo" { return true }
      case IConst(decl) -> if decl.name == "buildInfo" { return true }
      case IVal(decl) -> {
        match decl.pattern.kind {
          case PBinding(name, _) -> if name == "buildInfo" { return true }
          case _ -> ()
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

func biPath(name: in String, sp: in Span): ModulePath {
  val segs: List[String] = newList()
  segs.add(name)
  ModulePath(segments = segs, span = sp)
}

// `Some("v")` for a supplied define, `None` otherwise — the reproducibility
// seam for `gitHash` / `buildTimestamp` (docs/60 §9.2).
func optStringExpr(v: in Option[String], sp: in Span): Expr {
  match v {
    case Some(s) -> {
      val args: List[CallArg] = newList()
      args.add(CANamed(name = "value", value = stringLiteralExpr(s, sp), span = sp))
      val callee = Expr(kind = EPath(path = biPath("Some", sp)), span = sp)
      Expr(kind = ECall(fn = callee, args = args), span = sp)
    }
    case None -> Expr(kind = EPath(path = biPath("None", sp)), span = sp)
  }
}

// `["f1", "f2", ...]` — the active feature set as a `List[String]` literal.
func featuresListExpr(features: in List[String], sp: in Span): Expr {
  val elems: List[Expr] = newList()
  var i = 0
  while i < features.count {
    elems.add(stringLiteralExpr(features[i], sp))
    i = i + 1
  }
  Expr(kind = EList(exprs = elems), span = sp)
}

// The `BuildInfo(version = ..., ...)` constructor call. Every field is set
// explicitly (no reliance on record defaults) — the cross-package construction
// the emitter must lower correctly.
func buildInfoCtorExpr(
  version: in String,
  target: in String,
  profile: in String,
  gitHash: in Option[String],
  buildTs: in Option[String],
  features: in List[String],
  sp: in Span,
): Expr {
  val args: List[CallArg] = newList()
  args.add(CANamed(name = "version", value = stringLiteralExpr(version, sp), span = sp))
  args.add(CANamed(name = "target", value = stringLiteralExpr(target, sp), span = sp))
  args.add(CANamed(name = "profile", value = stringLiteralExpr(profile, sp), span = sp))
  args.add(CANamed(name = "gitHash", value = optStringExpr(gitHash, sp), span = sp))
  args.add(CANamed(name = "buildTimestamp", value = optStringExpr(buildTs, sp), span = sp))
  args.add(CANamed(name = "features", value = featuresListExpr(features, sp), span = sp))
  val callee = Expr(kind = EPath(path = biPath("BuildInfo", sp)), span = sp)
  Expr(kind = ECall(fn = callee, args = args), span = sp)
}

// `pub func buildInfo(): BuildInfo { return BuildInfo(...) }` — `pub` so an
// uncalled accessor never trips an unused-binding diagnostic.
func buildInfoFuncItem(
  version: in String,
  target: in String,
  profile: in String,
  gitHash: in Option[String],
  buildTs: in Option[String],
  features: in List[String],
  sp: in Span,
): Item {
  val ctor = buildInfoCtorExpr(version, target, profile, gitHash, buildTs, features, sp)
  val stmts: List[Statement] = newList()
  stmts.add(Statement(kind = SReturn(value = Some(value = ctor)), span = sp))
  val body = FBBlock(block = Block(statements = stmts, span = sp))
  val retTy = TypeExpr(kind = TRef(path = biPath("BuildInfo", sp)), span = sp)
  val noDoc: List[DocComment] = newList()
  val noAnn: List[Annotation] = newList()
  val noParams: List[Param] = newList()
  val noContracts: List[ContractClause] = newList()
  val fn = FunctionDecl(
    docComments = noDoc,
    annotations = noAnn,
    visibility = Some(value = VisPub(span = sp)),
    isAsync = false,
    name = "buildInfo",
    generics = None,
    params = noParams,
    ret = Some(value = retTy),
    whereClause = None,
    contracts = noContracts,
    body = Some(value = body),
    span = sp
  )
  Item(
    docComments = newList(),
    annotations = newList(),
    visibility = Some(value = VisPub(span = sp)),
    kind = IFunc(decl = fn),
    span = sp
  )
}

/// Synthesize the `buildInfo()` accessor into a file that imports
/// `Std.BuildInfo` (docs/60 §9.2). No-op for a file that does not import it, or
/// that already declares its own `buildInfo`. The record's `version` / `profile`
/// come from the well-known `version` / `build_profile` defines (deterministic
/// fallbacks otherwise); `target` and `features` are the build's own parameters;
/// `gitHash` / `buildTimestamp` are `Some` only when the `git_hash` /
/// `build_timestamp` defines are supplied (reproducibility seam, docs/60 §9.2).
pub func synthesizeBuildInfo(
  sf: in SourceFile,
  targetName: in String,
  features: in List[String],
  defines: in List[Define],
): SourceFile {
  if not importsStdBuildInfo(sf.imports) {
    return sf
  }
  if hasUserBuildInfoDecl(sf.items) {
    return sf
  }
  val version = match lookupDefine(defines, "version") { case Some(v) -> v; case None -> "0.0.0" }
  val profile = match lookupDefine(defines, "build_profile") { case Some(v) -> v; case None -> "debug" }
  val gitHash = lookupDefine(defines, "git_hash")
  val buildTs = lookupDefine(defines, "build_timestamp")
  val outItems: List[Item] = newList()
  var i = 0
  while i < sf.items.count {
    outItems.add(sf.items[i])
    i = i + 1
  }
  outItems.add(buildInfoFuncItem(version, targetName, profile, gitHash, buildTs, features, sf.span))
  SourceFile(
    moduleDoc = sf.moduleDoc,
    fileAnnotations = sf.fileAnnotations,
    packageDecl = sf.packageDecl,
    imports = sf.imports,
    items = outItems,
    span = sf.span
  )
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
          case Some(k) -> {
            keyOpt = Some(value = k)
          }
          case None -> {
            malformed = true
          }
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
            diags.add(
              errorDiagnostic(
                "F0032",
                "@build_const requires a single string-literal key, e.g. @build_const(\"version\")",
                annSpan
              )
            )
            outItems.add(it)
          } else if not valTypeOkForString(decl) {
            diags.add(errorDiagnostic("F0030", "@build_const may only annotate a String val (docs/60 §4)", annSpan))
            outItems.add(it)
          } else {
            match keyOpt {
              case Some(k) -> {
                match lookupDefine(defines, k) {
                  case Some(v) -> {
                    val newDecl = ValDecl(
                      pattern = decl.pattern,
                      ty = decl.ty,
                      init = stringLiteralExpr(v, decl.init.span),
                      span = decl.span
                    )
                    val newItem = Item(
                      docComments = it.docComments,
                      annotations = it.annotations,
                      visibility = it.visibility,
                      kind = IVal(decl = newDecl),
                      span = it.span
                    )
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
