//! pipeline.l — Lyric.Pipeline: the shared target-independent middle-end
//! driver for the three backend bridges (docs/59 §9.2).
//!
//! `Msil.Bridge`, `Jvm.Bridge`, and `Lyric.LlvmBridge` orchestrate the same
//! front/middle-end pass sequence; before this package existed each carried
//! its own copy, and every pass-ordering fix had to land three times (band
//! J2 / #2665, D-progress-642).  This package is the single authority for:
//!
//!   * the pass ORDER — parse → cfg erasure → wire-expand → alias rewrite →
//!     @stubbable synthesis → typecheck → modecheck → contract elaboration →
//!     `?`-propagation → derive → mono → weave → await-hoist — with the
//!     cfg-erasure placement D-progress-642 established (erasure directly
//!     after parse, before anything indexes the items, on every path
//!     including single-file builds), and the await-hoist LAST (#5606: it
//!     rewrites `f(a, await e)`-family shapes inside `async func` bodies
//!     into hoisted `val` bindings, so it must see the final tree — woven
//!     wrappers included — that codegen sees);
//!   * the diagnostics gating for each pass (which passes are fatal, which
//!     are advisory, and how a multi-package build labels the owning
//!     package);
//!   * the cross-package item-visibility rule (`pipeIsCrossPackageItem` —
//!     previously `isTypeItem` / `collectTypeItemsFromFile`, which had
//!     drifted three ways) and the monomorphizer input collectors
//!     (generic / non-generic pub funcs, interface and record decls).
//!
//! Where the targets genuinely differ, the difference is an explicit
//! parameter, never a fork:
//!
//!   * `MiddleEndOptions.tcFatal` — type-check diagnostics gate the build on
//!     MSIL but are advisory on the JVM and native targets (the self-hosted
//!     checker lacks full builtin coverage there);
//!   * `MiddleEndOptions.tcReport` — bundled stdlib packages on the JVM
//!     suppress the advisory noise on successful builds;
//!   * `pipeExpandAndRewrite`'s `injectWeave` — the JVM bundler walks
//!     `file.imports` to decide which packages' bytecode lands in the JAR,
//!     so `Weaver.injectWeaveImports` must run pre-typecheck there; MSIL
//!     seeds stdlib MemberRefs import-independently and deliberately skips
//!     it (documented intentional in D-progress-642);
//!   * `pipeExpandAndRewrite`'s `runWireExpand` / `runStubbable` — the
//!     native bridge does not expand docs/58 wires or synthesise
//!     `@stubbable` stubs today; passing `false` makes that gap explicit at
//!     the call site instead of an invisible omission.
//!
//! This package depends only on front-end / middle-end packages.  It MUST
//! NOT import `Msil.*` or `Jvm.*` — the JVM bridge deliberately does not
//! depend on the MSIL packages, and both import this one.
package Lyric.Pipeline

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.Propagate
import Lyric.Cfg as Cfg
import Lyric.BuildDefines as BD
import Lyric.AwaitHoist as AwaitHoist
import Lyric.AliasRewriter as Aliases
import Lyric.Stubbable as Stubbable
import Lyric.WireExpand as WireExpand
import Lyric.Mono
import Lyric.Derives
import Lyric.Weaver as Weaver
import Lyric.DiagnosticUtil as DiagUtil

/// Per-file middle-end knobs.  `tcFatal` gates the build on type-check
/// diagnostics (MSIL); when false, `tcReport` controls whether the advisory
/// diagnostics are echoed at all (JVM bundled stdlib packages pass false).
/// `pkgLabel` prefixes every gating diagnostic with the owning package name
/// for multi-package builds; "" prints the bare diagnostic.
pub record MiddleEndOptions {
  tcFatal: Bool
  tcReport: Bool
  pkgLabel: String
}

// Report `diags` (package-labelled when `pkgLabel` is non-empty) and return
// true when any is error-severity.
func gate(pkgLabel: in String, diags: in List[Diagnostic]): Bool {
  if pkgLabel.length == 0 {
    DiagUtil.diagReportAndAbort(diags)
  } else {
    DiagUtil.diagReportAndAbortInPkg(pkgLabel, diags)
  }
}

/// Parse `source` and apply `@cfg` erasure with the target pseudo-feature
/// (D-N-013) — the front of every user-file compile on every target.  The
/// erasure runs directly after parse, before anything indexes the items, so
/// `@cfg(feature = "X")`-gated items behave identically on single-file and
/// manifest builds (docs/59 §5.4, closed in D-progress-642).  Both passes
/// gate fatally.  Returns the erased file, or None after reporting.
pub func pipeParseAndErase(
  source: in String,
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
): Option[SourceFile] {
  val parseResult = parse(source)
  if gate("", parseResult.diagnostics) {
    return None
  }
  // Auto-inject the well-known `target` define (docs/60 §3.3) as a fallback
  // beneath the already-decoded user/manifest defines: `pipeParseAndErase` is
  // the one place that carries `targetName` on every backend and both the
  // single-file and project paths, so injecting here lands it uniformly. It is
  // a no-op when the caller already supplied a `target` define, so an explicit
  // `--define target=…` still wins.
  val definesWk = BD.withWellKnownTarget(targetName, defines)
  // Build-define substitution runs before @cfg erasure (docs/60 §5): a
  // define can never be read from an item cfg is about to erase, and cfg
  // predicates cannot observe a define. Both are pure SourceFile -> SourceFile
  // AST transforms; substitution only ever inserts String-literal nodes.
  val bdRes = BD.applyBuildDefines(definesWk, parseResult.file)
  if gate("", bdRes.diagnostics) {
    return None
  }
  val cfgRes = Cfg.applyCfgErasure(Cfg.withTargetFeature(activeFeatures, targetName), declaredFeatures, bdRes.file)
  if gate("", cfgRes.diagnostics) {
    return None
  }
  // Std.BuildInfo synthesis (docs/60 §9.2): if the file imports Std.BuildInfo,
  // append the per-build `buildInfo()` accessor. Runs after @cfg erasure so the
  // synthesized item is never itself erased. `activeFeatures` is the user's own
  // feature set (not the synthetic target pseudo-feature cfg adds).
  val biFile = BD.synthesizeBuildInfo(cfgRes.file, targetName, activeFeatures, definesWk)
  Some(value = biFile)
}

/// The pre-typecheck rewrite chain, in the one authoritative order:
/// docs/58 wire/config-template expansion FIRST (so an include alias's
/// qualified access is consumed by the expander, not collapsed by the
/// import-alias rewriter when the alias name matches an imported package's
/// last segment), then the import-alias rewrite, then `@stubbable` stub
/// synthesis, then (JVM only) `Weaver.injectWeaveImports`.  Wire-expansion
/// diagnostics gate fatally.  `weWires` / `weConfigs` carry the templates
/// collected across the compilation (own file only for single-file builds).
pub func pipeExpandAndRewrite(
  file: in SourceFile,
  weWires: in Map[String, CollectedWireTemplate],
  weConfigs: in Map[String, CollectedConfigTemplate],
  runWireExpand: in Bool,
  runStubbable: in Bool,
  injectWeave: in Bool,
): Option[SourceFile] {
  var f: SourceFile = file
  if runWireExpand {
    val weRes = WireExpand.expandFile(f, weWires, weConfigs)
    if gate("", weRes.diagnostics) {
      return None
    }
    f = weRes.file
  }
  f = Aliases.rewriteFile(f)
  if runStubbable {
    f = Stubbable.stubbableRewriteFile(f)
  }
  if injectWeave {
    f = Weaver.injectWeaveImports(f)
  }
  Some(value = f)
}

/// The check-through-mono half of the middle end on one (already rewritten)
/// file: typecheck → modecheck → contract elaboration → `?`-propagation →
/// derive → mono.  Returns the post-mono file, or None after reporting a
/// fatal diagnostic.
///
/// `deriveImports` carries the type-shaped items of every imported package
/// (`flattenImportedItems(importedPkgs)` on the project paths; empty on the
/// single-file paths, where `deriveFileWithImports` degenerates to
/// `deriveFile`).  `monoGenFuncs` / `monoIfaceDecls` / `monoRecordDecls`
/// are the monomorphizer's cross-package inputs — the caller composes them
/// from its own source shapes (stdlib packages, in-bundle siblings,
/// restored artifacts) via the `pipeAdd*` collectors below.
pub func pipeCheckAndMono(
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  deriveImports: in List[Item],
  monoGenFuncs: in List[FunctionDecl],
  monoIfaceDecls: in List[InterfaceDecl],
  monoRecordDecls: in List[RecordDecl],
  opts: in MiddleEndOptions,
): Option[SourceFile] {
  val tcRes = checkWithImportedPackages(file0, importedPkgs)
  if opts.tcFatal {
    if gate(opts.pkgLabel, tcRes.diagnostics) {
      return None
    }
  } else {
    if opts.tcReport {
      DiagUtil.diagReport(tcRes.diagnostics)
    }
  }

  val mcRes = checkFile(file0)
  if gate(opts.pkgLabel, mcRes.diagnostics) {
    return None
  }

  val elaborated = elaborateFile(file0)

  // Lower `?` error-propagation into match-unwrap + early-return (#1475).
  // Runs after the elaborator so a propagated Err/None short-circuit is not
  // forced through the success-shaped `ensures:` rewrite.
  val propRes = lowerPropagateFile(elaborated)
  if gate(opts.pkgLabel, propRes.diagnostics) {
    return None
  }

  val derived = deriveFileWithImports(propRes.file, deriveImports)

  val monoRes = monoFileWithImportsAndTypeDecls(derived, monoGenFuncs, monoIfaceDecls, monoRecordDecls)
  if gate(opts.pkgLabel, monoRes.diagnostics) {
    return None
  }
  Some(value = monoRes.file)
}

/// Aspect weaving — after mono, before codegen, on every target.  Resolves
/// cross-package `from`-instance aspects against `templates` (pass an empty
/// map on single-file builds — `weaveFileWithDiagsAndTemplates` with no
/// templates is the documented behaviour-preserving degeneration of
/// `weaveFileWithDiags`).  Weave-time diagnostics (A0042/A0043/A0044) gate
/// fatally.
///
/// The await-hoist (#5606) runs directly after the weave as the FINAL
/// middle-end rewrite: `f(a, await e)`-family shapes in `async func` bodies
/// become hoisted `val` bindings so no await suspends with operands already
/// on the MSIL evaluation stack.  It is semantics-preserving on every target
/// (left-to-right evaluation order is kept), and running it here — on the
/// one tree all backends consume — keeps the MSIL async-SM pre-scan and
/// emission in lockstep by construction.
pub func pipeWeave(
  file: in SourceFile, templates: in Map[String, CollectedTemplate], pkgLabel: in String
): Option[SourceFile] {
  val weaveRes = Weaver.weaveFileWithDiagsAndTemplates(file, templates)
  if gate(pkgLabel, weaveRes.diagnostics) {
    return None
  }
  Some(value = AwaitHoist.hoistAwaitsFile(weaveRes.file))
}

/// The full per-file middle end: `pipeCheckAndMono` then `pipeWeave`.
/// Callers that must interleave work between mono and weave (the MSIL
/// project path collects aspect templates from every package's POST-mono
/// file before any package weaves) call the two halves directly — the
/// split points are these same functions, so the ordering authority is
/// not forked.
pub func pipeMiddleEnd(
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  deriveImports: in List[Item],
  monoGenFuncs: in List[FunctionDecl],
  monoIfaceDecls: in List[InterfaceDecl],
  monoRecordDecls: in List[RecordDecl],
  templates: in Map[String, CollectedTemplate],
  opts: in MiddleEndOptions,
): Option[SourceFile] {
  match pipeCheckAndMono(file0, importedPkgs, deriveImports, monoGenFuncs, monoIfaceDecls, monoRecordDecls, opts) {
    case Some(monoFile) -> pipeWeave(monoFile, templates, opts.pkgLabel)
    case None -> None
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Cross-package visibility + monomorphizer-input collectors.
// ─────────────────────────────────────────────────────────────────────────────
/// The ONE cross-package item-visibility rule: true for top-level items that
/// must reach packages importing this one, so cross-package type names,
/// `pub func` signatures, and `pub val` constants resolve at typecheck.
///
///   * every type-shaped item — records, exposed records, unions, enums,
///     distinct types, interfaces, type aliases, opaques;
///   * `extern type` / `protected type` declarations (kernel boundary types
///     referenced by importing signatures — #1488, #2377);
///   * `impl Iface for T` conformances (interface subsumption on
///     cross-package calls; keyed by `TypeId`, ignored by
///     `addSigsFromItems`, so carrying them is sound and additive);
///   * `pub func` free functions (#2704) and module-level `pub val`s
///     (#2195), or cross-package references abort with T0010/T0020.
pub func pipeIsCrossPackageItem(it: in Item): Bool {
  val isType = match it.kind {
    case IRecord(_) -> true
    case IExposedRec(_) -> true
    case IUnion(_) -> true
    case IEnum(_) -> true
    case IDistinctType(_) -> true
    case IInterface(_) -> true
    case ITypeAlias(_) -> true
    case IOpaque(_) -> true
    case IExternType(_) -> true
    case IProtected(_) -> true
    case IImpl(_) -> true
    case _ -> false
  }
  if isType {
    return true
  }
  val isPubFunc = match it.kind {
    case IFunc(decl) -> match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
    case _ -> false
  }
  if isPubFunc {
    return true
  }
  match it.kind {
    case IVal(_) -> match it.visibility { case Some(VisPub(_)) -> true; case _ -> false }
    case _ -> false
  }
}

/// Append every cross-package-visible item of `file` to `dest`
/// (`pipeIsCrossPackageItem` filter).
pub func pipeAddCrossPackageItems(file: in SourceFile, dest: in List[Item]): Unit {
  var i = 0
  while i < file.items.count {
    if pipeIsCrossPackageItem(file.items[i]) {
      dest.add(file.items[i])
    }
    i = i + 1
  }
}

/// True iff the annotation list carries a marker that makes a generic
/// unsuitable for monomorphization-by-copy.  `@externTarget` is a kernel
/// boundary whose body codegen synthesises from the BCL target (and
/// `specializeFunc` drops annotations, so a copy would lose it); `@axiom`
/// funcs are proof-only and must not be emitted as runtime code.  Benign
/// markers like `@stable` do not block specialization.
pub func pipeAnnsBlockSpecialization(anns: in List[Annotation]): Bool {
  var i = 0
  while i < anns.count {
    val segs = anns[i].name.segments
    if segs.count == 1 {
      val n = segs[0]
      if n == "externTarget" or n == "axiom" {
        return true
      }
    }
    i = i + 1
  }
  false
}

/// Append every generic block-or-expr-bodied func in `items` that is
/// eligible for cross-package monomorphization to `dest`.
///
/// `requirePub` — user-package and restored-artifact collectors demand
/// `pub` (a private func's cross-assembly MemberRef would fail to bind);
/// stdlib collectors pass false (stdlib items are implicitly public).
/// `excludeIntrinsics` — stdlib collectors pass true so
/// `Std.Collections.mapGet` stays with its codegen intrinsic: a
/// monomorphized copy would rename the call, bypass the intrinsic, and
/// copy a body that calls the un-lowerable generic kernel extern
/// `tryGetValue`.  `pkgName` is only consulted for that exclusion.
pub func pipeAddGenericFuncs(
  items: in List[Item],
  pkgName: in String,
  requirePub: in Bool,
  excludeIntrinsics: in Bool,
  dest: in List[FunctionDecl],
): Unit {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> {
        var pubOk = true
        if requirePub {
          pubOk = match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
        }
        val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
        val hasBody = match decl.body { case Some(_) -> true; case None -> false }
        val isIntrinsic = excludeIntrinsics and decl.name == "mapGet" and pkgName == "Std.Collections"
        if pubOk and isGeneric and hasBody and not pipeAnnsBlockSpecialization(decl.annotations) and not isIntrinsic {
          dest.add(decl)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

/// Append every non-generic block-bodied `pub func` in `items` to `dest`.
/// These feed the monomorphizer's inference tables only (never the
/// specialisation worklist) so a generic call whose type argument flows
/// through a cross-package return can specialise (#3705, #5196).
/// Expression-bodied wrappers (`= ()` extern stubs) are excluded — they are
/// BCL boundary stubs whose return types may not be representable in the
/// Lyric AST type system.
pub func pipeAddNonGenericFuncs(items: in List[Item], dest: in List[FunctionDecl]): Unit {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> {
        val isPub = match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
        val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
        val hasBlockBody = match decl.body {
          case Some(fb) -> match fb { case FBBlock(_) -> true; case FBExpr(_) -> false }
          case None -> false
        }
        if isPub and not isGeneric and hasBlockBody and not pipeAnnsBlockSpecialization(decl.annotations) {
          dest.add(decl)
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

/// Append every `IInterface` decl in `items` to `dest`.  Fed to the
/// monomorphizer (#3813) so a method-call return on an interface-typed
/// receiver can be inferred and the enclosing generic call specialised.
/// Interfaces only feed inference; they are never specialised.
pub func pipeAddInterfaceDecls(items: in List[Item], dest: in List[InterfaceDecl]): Unit {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IInterface(decl) -> dest.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
}

/// Returning convenience over `pipeAddInterfaceDecls`.
pub func pipeInterfaceDecls(items: in List[Item]): List[InterfaceDecl] {
  val ifaces: List[InterfaceDecl] = newList()
  pipeAddInterfaceDecls(items, ifaces)
  ifaces
}

/// Append every record decl (plain + exposed) in `items` to `dest`.  Fed to
/// the monomorphizer (#3813 follow-up) so a `recv.field` projection on a
/// value whose record type is declared in an imported package can be
/// inferred and the enclosing generic call specialised.
pub func pipeAddRecordDecls(items: in List[Item], dest: in List[RecordDecl]): Unit {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IRecord(decl) -> dest.add(decl)
      case IExposedRec(decl) -> dest.add(decl)
      case _ -> ()
    }
    i = i + 1
  }
}

/// Returning convenience over `pipeAddRecordDecls`.
pub func pipeRecordDecls(items: in List[Item]): List[RecordDecl] {
  val recs: List[RecordDecl] = newList()
  pipeAddRecordDecls(items, recs)
  recs
}

/// Join a ModulePath's segments with "." (the Lyric package-name spelling).
pub func pipeDottedPath(path: in ModulePath): String {
  modulePathJoin(path.segments)
}
