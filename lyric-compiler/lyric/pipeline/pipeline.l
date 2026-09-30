//! pipeline.l — Lyric.Pipeline: the shared target-independent middle-end
//! driver for the three backend bridges (docs/59 §9.2).
//!
//! `Msil.Bridge`, `Jvm.Bridge`, and `Lyric.LlvmBridge` orchestrate the same
//! front/middle-end pass sequence; before this package existed each carried
//! its own copy, and every pass-ordering fix had to land three times (band
//! J2 / #2665, D-progress-642).  This package is the single authority for:
//!
//!   * the pass ORDER — parse → cfg erasure → wire-expand → alias rewrite →
//!     @stubbable synthesis → interface-default-method inheritance (#6433) →
//!     typecheck → modecheck → contract elaboration → `?`-propagation →
//!     derive → mono → weave → await-hoist — with the
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
import Lyric.ImplDefaults as ImplDefaults
import Lyric.WireExpand as WireExpand
import Lyric.Mono
import Lyric.Derives
import Lyric.Weaver as Weaver
import Lyric.DiagnosticUtil as DiagUtil

/// Per-file middle-end knobs.  `tcFatal` gates the build on type-check
/// diagnostics (MSIL); when false, `tcReport` controls whether the advisory
/// diagnostics are echoed at all (JVM bundled stdlib packages pass false);
/// a reported advisory check still gates on T0080 (misplaced `old(...)`).
/// `pkgLabel` prefixes every gating diagnostic with the owning package name
/// for multi-package builds; "" prints the bare diagnostic.  `lineOrigins`
/// (#6282) resolves a multi-file package's merged-blob line numbers back to
/// their real on-disk file and line at every gate below; empty for every
/// single-file build and for a project package whose provenance is unknown.
/// `awaitInTryIsHazard` (#7198) — whether this target's async lowering has
/// the CLR-verifier-style hazard `Lyric.Propagate`'s `F0045` diagnostic
/// exists to prevent (a suspend/resume sequence physically inside a
/// try/catch/finally protected region): true for MSIL and native, whose
/// async lowering genuinely suspends; false for JVM, whose `async func`
/// lowering is a synchronous stub with no suspend point at all (docs/44),
/// so the same diagnostic would be a spurious platform-parity regression
/// there — see `lowerPropagateFile`'s doc.
/// The `@cfg` feature set one package of a build is erased with, when it
/// differs from the build's own.  A dependency compiled from source into the
/// consumer's bundle (the JVM target has no restored-binary form of a
/// workspace or path dependency) keeps the features its own manifest
/// resolves to, exactly as a separately built dependency does (#7378).
pub record PackageFeatureSet {
  packageName: String
  active: List[String]
  declared: List[String]
}

pub record MiddleEndOptions {
  tcFatal: Bool
  tcReport: Bool
  pkgLabel: String
  lineOrigins: List[DiagUtil.MergedLineOrigin]
  awaitInTryIsHazard: Bool
  /// Whether a list literal no collection type is expected of is bound to a
  /// local of its checked type (`SymbolTable.listLiteralTypeSites`, #7818).
  /// A backend whose generic instantiations are distinct runtime types (MSIL,
  /// native) needs it to build `None` beside `Some(1)` at one closed
  /// instantiation and to read the elements back at it.  The JVM erases
  /// generics: its literal is an `ArrayList` of erased elements whatever
  /// their instantiation, and the element types it needs it recovers from the
  /// literal itself.
  bindListLiteralTypes: Bool
  /// Whether a direct call to an `async func` must be turned into an
  /// explicit `await` before lowering (#7838): true for MSIL, whose `async
  /// func` returns its task and awaits only where an `await` is written;
  /// false for JVM (synchronous lowering) and native (hot tasks awaited at
  /// the call), which already await a direct call in place.
  awaitAsyncCalls: Bool
  /// Whether runtime contract checks (`requires:`, `ensures:`, etc.) should
  /// be emitted in the compiled output. Default is true (contract checks
  /// enabled). Controlled by the `[contracts]` table in lyric.toml (docs/63).
  contractsEnabled: Bool
  /// Receives the file as type-checked with its record `.copy(...)` calls
  /// desugared (`Lyric.Mono.desugarRecordCopiesFile`).  Contract metadata
  /// must take generic function bodies from this file, not the parsed one,
  /// so a generic exported to another package carries no `.copy` its
  /// consumer could not lower.  Pass an empty list; the pipeline appends one
  /// file per `pipeCheckAndMono` call.
  checkedSourceOut: List[SourceFile]
  /// Receives the type checker's `memberRecvClasses` for the file
  /// (receiver span key -> `Pkg.Name`): the JVM backend narrows a generic
  /// receiver it sees as `Object` with it (#7378).  Backends that keep
  /// generic types pass a map and ignore it.
  memberRecvClassesOut: Map[String, String]
}

// Report `diags` (package-labelled when `pkgLabel` is non-empty, further
// resolved to a real per-line file/line via `origins` when non-empty — #6282)
// and return true when any is error-severity.
func gate(pkgLabel: in String, origins: in List[DiagUtil.MergedLineOrigin], diags: in List[Diagnostic]): Bool {
  if pkgLabel.length == 0 {
    DiagUtil.diagReportAndAbort(diags)
  } else if origins.count == 0 {
    DiagUtil.diagReportAndAbortInPkg(pkgLabel, diags)
  } else {
    DiagUtil.diagReportAndAbortInPkgWithOrigins(pkgLabel, origins, diags)
  }
}

/// Parse `source` and apply `@cfg` erasure with the target pseudo-feature
/// (D-N-013) — the front of every user-file compile on every target.  The
/// erasure runs directly after parse, before anything indexes the items, so
/// `@cfg(feature = "X")`-gated items behave identically on single-file and
/// manifest builds (docs/59 §5.4, closed in D-progress-642).  Both passes
/// gate fatally.  Returns the erased file, or None after reporting.
///
/// `label` prefixes every diagnostic from this call (docs/63 §9.7 slice 1):
/// the real on-disk path for a single-file build, the owning package name
/// (or "" when genuinely unknown, e.g. a multi-file package pre-merge) for
/// a project build. Previously every parse-phase diagnostic was reported
/// via a hardcoded `gate("", …)`, bypassing the caller's label entirely —
/// a syntax error printed with no file attribution at all, even for a
/// single-file build.
///
/// `origins` (#6282) is a multi-file package's per-merged-line provenance
/// table (`Lyric.Emitter.mergePackageSourcesWithOrigins`); empty for every
/// single-file build, resolving every diagnostic straight to `label`.
pub func pipeParseAndErase(
  source: in String,
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
  label: in String,
  origins: in List[DiagUtil.MergedLineOrigin],
): Option[SourceFile] {
  val parseResult = parse(source)
  if gate(label, origins, parseResult.diagnostics) {
    return None
  }
  // Auto-inject the well-known `target` define (docs/60 §3.3) as a fallback
  // beneath the already-decoded user/manifest defines: `pipeParseAndErase` is
  // the one place that carries `targetName` on every backend and both the
  // single-file and project paths, so injecting here lands it uniformly. It is
  // a no-op when the caller already supplied a `target` define, so an explicit
  // `--define target=…` still wins.
  // The well-known `build_profile` define (docs/60 §3.3) is injected here too,
  // always as the `"debug"` fallback: a `--release`/AOT build injects
  // `build_profile=release` into its defines upstream of this call, so last-wins
  // keeps `release` and this fallback is skipped for release compiles.
  val definesWk = BD.withWellKnownProfile("debug", BD.withWellKnownTarget(targetName, defines))
  // Build-define substitution runs before @cfg erasure (docs/60 §5): a
  // define can never be read from an item cfg is about to erase, and cfg
  // predicates cannot observe a define. Both are pure SourceFile -> SourceFile
  // AST transforms; substitution only ever inserts String-literal nodes.
  val bdRes = BD.applyBuildDefines(definesWk, parseResult.file)
  if gate(label, origins, bdRes.diagnostics) {
    return None
  }
  val cfgRes = Cfg.applyCfgErasure(Cfg.withTargetFeature(activeFeatures, targetName), declaredFeatures, bdRes.file)
  if gate(label, origins, cfgRes.diagnostics) {
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
/// last segment), then module-level destructuring `val` desugaring (#7763),
/// then the import-alias rewrite, then `@stubbable` stub
/// synthesis, then same-file interface-default-method inheritance (#6433 —
/// runs AFTER `@stubbable` so a synthesized `<Iface>Stub` impl also
/// inherits any default methods, and unconditionally on every target: it is
/// a pure language-semantics fix, not a target-specific feature toggle),
/// then (JVM only) `Weaver.injectWeaveImports`.  Wire-expansion diagnostics
/// gate fatally.  `weWires` / `weConfigs` carry the templates collected
/// across the compilation (own file only for single-file builds).
///
/// `label` / `origins` (#6824 item 3) attribute the two gates above to the
/// real on-disk file exactly like `pipeParseAndErase`'s and `pipeWeave`'s
/// own `label`/`origins` parameters do — before this, both gates hardcoded
/// `gate("", noOrigins, …)`, so a wire/config-template or impl-default-
/// inheritance diagnostic on a multi-file project package fell back to no
/// attribution at all even when the caller had already resolved a real
/// path-or-package-name label and a `MergedLineOrigin` table for this exact
/// file (every bridge call site reaches this function AFTER the parse-phase
/// `pp.label`/`pp.origins` resolution). "" / empty reproduces the prior
/// behaviour unchanged.
pub func pipeExpandAndRewrite(
  file: in SourceFile,
  weWires: in Map[String, WireExpand.CollectedWireTemplate],
  weConfigs: in Map[String, WireExpand.CollectedConfigTemplate],
  runWireExpand: in Bool,
  runStubbable: in Bool,
  injectWeave: in Bool,
  label: in String,
  origins: in List[DiagUtil.MergedLineOrigin],
): Option[SourceFile] {
  var f: SourceFile = file
  if runWireExpand {
    val weRes = WireExpand.expandFile(f, weWires, weConfigs)
    if gate(label, origins, weRes.diagnostics) {
      return None
    }
    f = weRes.file
  }
  val prep = pipePrepareForCheck(f, runStubbable)
  if gate(label, origins, prep.diagnostics) {
    return None
  }
  f = prep.file
  if injectWeave {
    f = Weaver.injectWeaveImports(f)
  }
  Some(value = f)
}

/// A file after the rewrites that run between parse and type check, and
/// the diagnostics they reported.  `file` is meaningful only when
/// `diagnostics` holds no error.
pub record CheckReadyFile {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// Whether any of `diags` is an error.
pub func hasErrorDiagnostic(diags: in List[Diagnostic]): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].severity == DiagError {
      return true
    }
    i = i + 1
  }
  false
}

/// The source rewrites the type checker expects to have run: the build
/// (`pipeExpandAndRewrite`) and the language server both call this, so the
/// editor reports what `lyric build` reports (#7512: the server checked the
/// raw parse, where `Pkg.f(...)` is still a member chain rather than a
/// qualified call).  Stops at the first pass that reports an error.
pub func pipePrepareForCheck(file: in SourceFile, runStubbable: in Bool): CheckReadyFile {
  // A destructuring module-level `val` becomes one `val` per bound name
  // (#7763) before any pass indexes module values, so every backend and the
  // checker see the same single-name items; a refutable pattern (T0144)
  // stops here, whether or not the type check that follows is fatal.
  val mvRes = desugarModuleValPatterns(file)
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < mvRes.diagnostics.count {
    diags.add(mvRes.diagnostics[i])
    i = i + 1
  }
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = file, diagnostics = diags)
  }
  var f = Aliases.rewriteFile(mvRes.file)
  if runStubbable {
    f = Stubbable.stubbableRewriteFile(f)
  }
  val idRes = ImplDefaults.inheritDefaultsFile(f)
  var j = 0
  while j < idRes.diagnostics.count {
    diags.add(idRes.diagnostics[j])
    j = j + 1
  }
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = f, diagnostics = diags)
  }
  // Record/opaque `invariant:` construction checkers (#7222): synthesized
  // before type checking so they are checked, and exported, like any
  // function of the declaring package.
  CheckReadyFile(file = synthesizeInvariantCheckers(idRes.file), diagnostics = diags)
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
    if gate(opts.pkgLabel, opts.lineOrigins, tcRes.diagnostics) {
      return None
    }
  } else if opts.tcReport {
    // The check is advisory here, but T0080 (`old(...)` outside `ensures:`)
    // is purely syntactic — no builtin-coverage gap can make it a false
    // positive — and codegen has no lowering for a stray `old`, so it gates
    // regardless (#7731).  So does T0144: a module `val` pattern its
    // initializer can never match has no lowering either (#7763).
    val advisory: List[Diagnostic] = newList()
    val misplacedOld: List[Diagnostic] = newList()
    for d in tcRes.diagnostics {
      if d.code == "T0080" or d.code == "T0144" {
        misplacedOld.add(d)
      } else {
        advisory.add(d)
      }
    }
    DiagUtil.diagReport(advisory)
    if gate(opts.pkgLabel, opts.lineOrigins, misplacedOld) {
      return None
    }
  }

  // Record `.copy(...)` → constructor call, a cross-package function value →
  // its forwarding lambda, a widened function-value call argument → its
  // explicit conversion, an unannotated function-valued local → its checked
  // type as the annotation (#7711), an unannotated `newList()`/`newMap()`/
  // `None` local → the type its uses fix as the annotation (#7788), a call
  // through a function value → a
  // call through a local of the callee's checked type (#7716), and a name a
  // tuple pattern binds → a local annotated with its element type (#7728),
  // a value a destructuring module `val` binds → its checked type as the
  // annotation (#7763), a list literal no collection type is expected of → a
  // local annotated with its checked slice type (#7818),
  // while the type checker's span keys still
  // identify exactly one expression each (D-progress-948, 962, 963).
  val valueSites = funcValueSites(tcRes.symbols)
  val noListLiteralSites: Map[String, ListLiteralTypeSite] = newMap()
  val copyRes = pipeDesugarChecked(
    file0,
    tcRes,
    valueSites,
    if opts.bindListLiteralTypes { tcRes.symbols.listLiteralTypeSites } else { noListLiteralSites }
  )
  if gate(opts.pkgLabel, opts.lineOrigins, copyRes.diagnostics) {
    return None
  }
  opts.checkedSourceOut.add(copyRes.file)
  // Bound to an annotated local: the stage-0 seed compiler that builds this
  // package cannot infer `mapKeys`'s type arguments from a restored
  // package's field chain and instantiates it over `Object` (#7441, fixed
  // in the compiler itself; the seed predates the fix).
  val recvClasses: Map[String, String] = tcRes.symbols.memberRecvClasses
  for rk in mapKeys(recvClasses) {
    match mapGet(recvClasses, rk) {
      case Some(cls) -> {
        if not opts.memberRecvClassesOut.containsKey(rk) {
          opts.memberRecvClassesOut.add(rk, cls)
        }
      }
      case None -> ()
    }
  }
  // Route every construction of an invariant-bearing type through its
  // checker (#7222).  After `.copy` desugaring, so a copy's constructor call
  // is covered too; after `checkedSourceOut` is captured, so generic bodies
  // exported for another package's specialisation stay checker-free.
  val invChecked = wrapInvariantConstructions(copyRes.file, tcRes.symbols.invariantCtorSites)
  // Operators on distinct types go through the underlying value (#7361),
  // which also re-checks a range subtype's derived arithmetic (#7226).
  val checked = lowerDistinctOps(invChecked, tcRes.symbols.distinctOpSites, tcRes.symbols.distinctCompoundSites)

  val mcRes = checkFile(checked)
  if gate(opts.pkgLabel, opts.lineOrigins, mcRes.diagnostics) {
    return None
  }

  // W0002 for every contract quantifier the elaborator will drop (#7228).
  // In a `@proof_required` file a quantifier is an obligation for `lyric
  // prove`, so the warning would only repeat what the annotation says.
  if not vlIsProofRequired(mcRes.level) {
    val _ = gate(opts.pkgLabel, opts.lineOrigins, runtimeQuantifierWarnings(checked))
  }
  val elaborated = elaborateFileWithInterfaces(checked, monoIfaceDecls, opts.contractsEnabled)

  // Lower `?` error-propagation into match-unwrap + early-return (#1475).
  // Runs after the elaborator so a propagated Err/None short-circuit is not
  // forced through the success-shaped `ensures:` rewrite. `monoRecordDecls`
  // (#6967, mirroring `pipeWeave`'s identical #6702 threading below) lets
  // the `?`-hoist's `impl`-target field resolution see cross-file/
  // cross-package records, not just same-file ones. `opts.awaitInTryIsHazard`
  // (#7198) gates whether F0045's guard fires on this target.
  val asyncCalls: Map[String, Bool] = if opts.awaitAsyncCalls { tcRes.symbols.asyncCallSites } else { newMap() }
  val propRes = lowerPropagateFileWithAsyncCalls(elaborated, monoRecordDecls, opts.awaitInTryIsHazard, asyncCalls)
  if gate(opts.pkgLabel, opts.lineOrigins, propRes.diagnostics) {
    return None
  }

  val derived = deriveFileWithImports(propRes.file, deriveImports)

  val monoRes = monoFileWithLambdaTypes(
    derived,
    monoGenFuncs,
    monoIfaceDecls,
    monoRecordDecls,
    funcValueLambdaTypes(valueSites),
    tcRes.symbols.callResultTypes
  )
  if gate(opts.pkgLabel, opts.lineOrigins, monoRes.diagnostics) {
    return None
  }
  Some(value = mapExprsInFile(monoRes.file, foldNegatedIntLiteral))
}

// `-<unsuffixed integer literal>` becomes one negative literal (#7346).
// The type checker types `-2147483648` as `Int`, but its operand alone is
// too large for `Int`, and every backend sized the negation by the operand:
// the JVM pushed a long into an int slot (VerifyError) and MSIL emitted a
// long.  A single literal lets each backend size the constant by its real
// value.  Runs after elaboration and mono, so contract asserts and
// specialised bodies are covered.
func foldNegatedIntLiteral(e: in Expr): Expr {
  match e.kind {
    case EPrefix(op, operand) -> match op {
      case PreNeg -> match unparenthesized(operand).kind {
        case ELiteral(lit) -> match lit {
          case LInt(v, sfx, raw) -> match sfx {
            case NoIntSuffix -> Expr(
              kind = ELiteral(
                lit = LInt(
                  value = 0i64 -
                    v,
                  suffix = sfx,
                  raw = "-" +
                    raw
                )
              ),
              span = e.span
            )
            case _ -> e
          }
          case _ -> e
        }
        case _ -> e
      }
      case _ -> e
    }
    case _ -> e
  }
}

// The checker looks through parentheses under a negation (`-(2147483648)`
// is an `Int`), so the fold does too (#7397).
func unparenthesized(e: in Expr): Expr {
  match e.kind {
    case EParen(inner) -> unparenthesized(inner)
    case _ -> e
  }
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
///
/// `typeIndex` (#7496) says which package declares each type name, for the
/// A0047 row-type check; build it with `pipeTypeOwnerIndex` from every
/// package the type checker sees, plus the build's own packages.
///
/// `extraRecordDecls` (#6702) is a cross-file/cross-package record list —
/// the caller's own `monoRecordDecls` — threaded into the await-hoist's
/// `HoistEngine` invocation so an `impl` block's target type resolves its
/// own fields even when declared outside `file`; an `impl` targeting a
/// record declared in this SAME file already resolves without it.
pub func pipeWeave(
  file: in SourceFile,
  templates: in Map[String, Weaver.CollectedTemplate],
  typeIndex: in Weaver.TypeOwnerIndex,
  pkgLabel: in String,
  origins: in List[DiagUtil.MergedLineOrigin],
  extraRecordDecls: in List[RecordDecl],
  contractsEnabled: in Bool = true,
): Option[SourceFile] {
  // @proof_required modules always enable contracts: proof obligations must not be user-disableable (#7732)
  val effectiveContractsEnabled = if ContractElaborator.isProofRequired(file.fileAnnotations) {
    true
  } else {
    contractsEnabled
  }
  val weaveRes = Weaver.weaveFileWithDiagsAndTemplates(file, templates, typeIndex, effectiveContractsEnabled)
  if gate(pkgLabel, origins, weaveRes.diagnostics) {
    return None
  }
  Some(value = AwaitHoist.hoistAwaitsFile(weaveRes.file, extraRecordDecls))
}

/// `file0` with the rewrites its type check recorded made explicit
/// (`Lyric.Mono.desugarCheckedFile`): the first step after the check in
/// `pipeCheckAndMono`.
pub func pipeDesugarChecked(
  file0: in SourceFile,
  tcRes: in CheckResult,
  valueSites: in Map[String, FuncRefSite],
  listLiteralSites: in Map[String, ListLiteralTypeSite],
): MonoResult {
  desugarCheckedFile(
    annotateModuleVals(file0, tcRes.symbols.moduleValTypes),
    tcRes.symbols.recordCopySites,
    valueSites,
    tcRes.symbols.argConversionSites,
    tcRes.symbols.localBindingTypeSites,
    tcRes.symbols.funcValueCallSites,
    tcRes.symbols.tuplePatternBindingSites,
    listLiteralSites
  )
}

/// `file0`'s declarations with their defaults as the middle end will leave
/// them: a parameter or field default that widens gets its explicit
/// conversion (#7811).  For a backend that must know another package's
/// defaults before that package's own middle end has run (the JVM bundle
/// generates the entry package's code first).  The check's diagnostics are
/// dropped: the package's real middle end reports them.
pub func pipeCheckedDefaults(file0: in SourceFile, importedPkgs: in List[ImportedPackage]): SourceFile {
  val tcRes = checkWithImportedPackages(file0, importedPkgs)
  // Only the JVM bundle calls this, and the JVM never binds list literals
  // to their checked type (`MiddleEndOptions.bindListLiteralTypes`).
  val noListLiteralSites: Map[String, ListLiteralTypeSite] = newMap()
  pipeDesugarChecked(file0, tcRes, funcValueSites(tcRes.symbols), noListLiteralSites).file
}

/// True when `file` declares a parameter or field default anywhere: on a
/// function, a field, or a record, protected, `impl` or interface member.
pub func pipeFileDeclaresDefaults(file: in SourceFile): Bool {
  for it in file.items {
    val found = match it.kind {
      case IFunc(decl) -> paramsHaveDefault(decl.params)
      case IRecord(decl) -> recordMembersHaveDefault(decl.members)
      case IExposedRec(decl) -> recordMembersHaveDefault(decl.members)
      case IOpaque(decl) -> {
        var any = false
        for m in decl.members {
          match m {
            case OMField(fd) -> if optExprPresent(fd.dflt) { any = true }
            case OMInvariant(_) -> ()
          }
        }
        any
      }
      case IProtected(decl) -> {
        var any = false
        for m in decl.members {
          match m {
            case PMField(pf) -> match pf {
              case PFVar(_, _, init, _, _, _) -> if optExprPresent(init) { any = true }
              case PFLet(_, _, init, _, _, _) -> if optExprPresent(init) { any = true }
              case PFImmutable(fd) -> if optExprPresent(fd.dflt) { any = true }
            }
            case PMEntry(ed) -> if paramsHaveDefault(ed.params) { any = true }
            case PMFunc(fn) -> if paramsHaveDefault(fn.params) { any = true }
            case PMInvariant(_) -> ()
          }
        }
        any
      }
      case IImpl(decl) -> {
        var any = false
        for m in decl.members {
          match m {
            case IMplFunc(fn) -> if paramsHaveDefault(fn.params) { any = true }
            case IMplAssoc(_) -> ()
          }
        }
        any
      }
      case IInterface(decl) -> {
        var any = false
        for m in decl.members {
          match m {
            case IMSig(sig) -> if paramsHaveDefault(sig.params) { any = true }
            case IMFunc(fn) -> if paramsHaveDefault(fn.params) { any = true }
            case IMAssoc(_) -> ()
          }
        }
        any
      }
      case _ -> false
    }
    if found {
      return true
    }
  }
  false
}

func optExprPresent(e: in Option[Expr]): Bool {
  match e {
    case Some(_) -> true
    case None -> false
  }
}

func paramsHaveDefault(params: in List[Param]): Bool {
  for p in params {
    if optExprPresent(p.dflt) {
      return true
    }
  }
  false
}

func recordMembersHaveDefault(members: in List[RecordMember]): Bool {
  for m in members {
    match m {
      case RMField(fd) -> if optExprPresent(fd.dflt) { return true }
      case RMFunc(fn) -> if paramsHaveDefault(fn.params) { return true }
      case RMInvariant(_) -> ()
    }
  }
  false
}

/// The full per-file middle end: `pipeCheckAndMono` then `pipeWeave`.
/// Callers that must interleave work between mono and weave (the MSIL
/// project path collects aspect templates from every package's POST-mono
/// file before any package weaves) call the two halves directly — the
/// split points are these same functions, so the ordering authority is
/// not forked.
///
/// `typeIndex` (#7497) lets a project-build caller thread in a
/// `TypeOwnerIndex` it already built ONCE for the whole build (over
/// `importedPkgs` plus whatever `Weaver.typeOwnerIndexAddFile` calls the
/// caller made for packages `importedPkgs` doesn't carry — its own bundle
/// packages, path-dependency template sources) instead of rebuilding an
/// identical index from `importedPkgs` on every one of this function's
/// per-package calls (the MSIL project path already builds it once before
/// its weave loop — see `Msil.Bridge`'s `weaveTypeIndex` — this mirrors
/// that).  `None` keeps the previous on-demand behaviour: build it fresh
/// from `importedPkgs` for THIS call only.  Every single-file caller (and
/// the native bridge) passes `None`.
pub func pipeMiddleEnd(
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  deriveImports: in List[Item],
  monoGenFuncs: in List[FunctionDecl],
  monoIfaceDecls: in List[InterfaceDecl],
  monoRecordDecls: in List[RecordDecl],
  templates: in Map[String, Weaver.CollectedTemplate],
  opts: in MiddleEndOptions,
  typeIndex: in Option[Weaver.TypeOwnerIndex],
): Option[SourceFile] {
  match pipeCheckAndMono(file0, importedPkgs, deriveImports, monoGenFuncs, monoIfaceDecls, monoRecordDecls, opts) {
    case Some(monoFile) -> pipeWeave(
      monoFile,
      templates,
      match typeIndex { case Some(ix) -> ix; case None -> pipeTypeOwnerIndex(importedPkgs) },
      opts.pkgLabel,
      opts.lineOrigins,
      monoRecordDecls,
      opts.contractsEnabled
    )
    case None -> None
  }
}

/// The weaver's type-owner index (#7496) over `pkgs` — the same per-package
/// item lists the type checker resolves against, so a type name resolves to
/// the package that actually declares it.  Callers add packages the list
/// does not carry (a project's own packages, path-dependency template
/// sources) with `Weaver.typeOwnerIndexAddFile`.
pub func pipeTypeOwnerIndex(pkgs: in List[ImportedPackage]): Weaver.TypeOwnerIndex {
  val ix = Weaver.newTypeOwnerIndex()
  for p in pkgs {
    Weaver.typeOwnerIndexAddPackage(ix, p.name, p.items, p.imports)
  }
  ix
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
///   * `extern package { ... }` blocks (#6361 — a kernel file's callers
///     address these body-less members through the enclosing package's own
///     qualified path, e.g. `Grpc.Kernel.Net.netOpenChannel(...)` from a
///     sibling in-project package; without this the block was invisible to
///     every cross-package consumer, not just the type checker);
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
    case IExtern(_) -> true
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

/// Same visibility rule as `pipeIsCrossPackageItem`, but also admits
/// `internal` funcs/vals (#6580). Per the language reference §3.1, `internal`
/// is visible across every package WITHIN THE SAME PROJECT — unlike `pub`,
/// it is never exposed in a published contract for a separate consuming
/// project. Correct ONLY for a build's own in-project sibling packages (the
/// multi-package `[project.packages]` case on all three backends); a
/// restored cross-project dependency or a bundled stdlib DLL must keep using
/// `pipeIsCrossPackageItem` — an `internal` function there has no real
/// cross-assembly binding to call through.
pub func pipeIsCrossPackageItemProject(it: in Item): Bool {
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
    case IExtern(_) -> true
    case _ -> false
  }
  if isType {
    return true
  }
  val isVisibleFunc = match it.kind {
    case IFunc(decl) -> match decl.visibility { case Some(_) -> true; case None -> false }
    case _ -> false
  }
  if isVisibleFunc {
    return true
  }
  match it.kind {
    case IVal(_) -> match it.visibility { case Some(_) -> true; case None -> false }
    case _ -> false
  }
}

/// Append every same-PROJECT-visible item of `file` to `dest`
/// (`pipeIsCrossPackageItemProject` filter — `pub` and `internal`).
pub func pipeAddCrossPackageItemsProject(file: in SourceFile, dest: in List[Item]): Unit {
  var i = 0
  while i < file.items.count {
    if pipeIsCrossPackageItemProject(file.items[i]) {
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

// The function type of each desugared function-value lambda, keyed like its
// site, for mono's inference (D-progress-963).  A site whose result type has
// no source spelling is left out.
func funcValueLambdaTypes(sites: in Map[String, FuncRefSite]): Map[String, TypeExpr] {
  val types: Map[String, TypeExpr] = newMap()
  val keys = mapKeys(sites)
  var i = 0
  while i < keys.count {
    match mapGet(sites, keys[i]) {
      case Some(site) -> match site.retType {
        case Some(rt) -> types.add(
          keys[i],
          TypeExpr(
            kind = TFunction(parameters = site.paramTypes, retTy = rt),
            span = rt.span
          )
        )
        case None -> ()
      }
      case None -> ()
    }
    i = i + 1
  }
  types
}

/// The packages a restored dependency imports: those its synthesised source
/// declares plus those its contract records (the synthesised source keeps
/// only what its declarations need).
pub func pipeRestoredImportNames(source: in SourceFile, contractImports: in List[String]): List[String] {
  mergeImportNames(collectImportNames(source.imports), contractImports)
}

/// The packages a restored dependency imports whole, from its synthesised
/// source and its contract (`Contract.wholeImports`).  The type checker
/// follows them for the transitive visibility of a consumer's whole import
/// (docs/01 §9.2, D141).
pub func pipeRestoredWholeImportNames(source: in SourceFile, contractWholeImports: in List[String]): List[String] {
  mergeImportNames(collectWholeImportNames(source.imports), contractWholeImports)
}

func mergeImportNames(names: in List[String], contractImports: in List[String]): List[String] {
  var i = 0
  while i < contractImports.count {
    var seen = false
    var j = 0
    while j < names.count {
      if names[j] == contractImports[i] {
        seen = true
      }
      j = j + 1
    }
    if not seen {
      names.add(contractImports[i])
    }
    i = i + 1
  }
  names
}

/// A restored package's items with qualified calls in their bodies resolved
/// as in the package's own build (D-progress-966).  Generic bodies are stored
/// as source after alias rewriting, so a call to a sibling package reads
/// `Ui.Session.start(...)`; re-parsed, that is a member chain on a value.
/// Re-running the alias rewriter with the package's recorded `imports` in
/// scope collapses it back into the qualified call it was.
pub func pipeRestoredItemsWithImports(source: in SourceFile, imports: in List[String]): List[Item] {
  if imports.count == 0 {
    return source.items
  }
  val decls: List[ImportDecl] = newList()
  var i = 0
  while i < imports.count {
    val segs: List[String] = newList()
    var start = 0
    var j = 0
    val imp = imports[i]
    while j < imp.length {
      if imp.substring(j, 1) == "." {
        segs.add(imp.substring(start, j - start))
        start = j + 1
      }
      j = j + 1
    }
    if start < imp.length {
      segs.add(imp.substring(start))
    }
    decls.add(
      ImportDecl(
        path = ModulePath(segments = segs, span = source.span),
        selector = None,
        asAlias = None,
        isPubUse = false,
        isExtern = false,
        span = source.span
      )
    )
    i = i + 1
  }
  val withImports = SourceFile(
    moduleDoc = source.moduleDoc,
    fileAnnotations = source.fileAnnotations,
    packageDecl = source.packageDecl,
    imports = decls,
    items = source.items,
    span = source.span
  )
  Aliases.rewriteFile(withImports).items
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
///
/// The intrinsic contributes NOTHING to `dest` here — see
/// `pipeAddInferenceOnlyIntrinsicFuncs` for its separate, appended-last
/// inference-only stub.  A stdlib self-build (where `Std.Collections`'s
/// real, body-having `mapGet` also arrives via an in-bundle collector —
/// `Msil.Bridge.collectInBundleGenericFuncs` — over the SAME package
/// list) merges every collector's output into one first-wins-by-name
/// table (`Lyric.Mono`'s `funcDecls`/`genDecls`).  Adding the stub to
/// `dest` right here put it in the SAME early position as every other
/// stdlib entry, so on a stdlib self-build it was merged BEFORE the real
/// `mapGet` and won the first-wins slot, silently dropping the real,
/// specialisable `mapGet` from `genDecls` — no `mapGet__String__String`
/// was ever emitted for the stdlib's own in-bundle call sites (e.g.
/// `Std.HttpServer.appendExtraHeaders`), which then crashed at runtime
/// hitting codegen's inline intrinsic fallback (#6377 investigation).
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
        if not isIntrinsic and pubOk and isGeneric and hasBody and not pipeAnnsBlockSpecialization(decl.annotations) {
          dest.add(withOriginPkgMono(decl, pkgName))
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

/// Companion of `pipeAddGenericFuncs`: collects ONLY the codegen-intrinsic
/// `mapGet` as an inference-only stub (`pipeInferenceOnlyFuncDecl`,
/// `Lyric.Mono.annsInferenceOnlyMono`'s `__lyric_inference_only` marker) so
/// `mapGet`'s return type (`Option[V]`) stays visible to the monomorphizer's
/// inference tables without ever competing for the first-wins specialisation
/// slot a real `mapGet` (from an in-bundle collector, on a stdlib self-build)
/// needs to win.  Callers must append this list's output LAST — after every
/// real generic-func collector — exactly like the existing
/// stdlib/in-bundle/restored union-ctor stub lists (#5604), so a real
/// `mapGet` always wins the merge (#6364's fix without #6377's regression).
///
/// Checks `pub` and a real body explicitly, mirroring `pipeAddGenericFuncs`'s
/// own gates, rather than assuming them from the `mapGet`-name/package match
/// alone — so a future rename or visibility change of `Std.Collections.mapGet`
/// fails this filter cleanly instead of silently stubbing a decl that isn't
/// actually the intrinsic this function exists to shadow.
pub func pipeAddInferenceOnlyIntrinsicFuncs(items: in List[Item], pkgName: in String, dest: in List[FunctionDecl]): Unit {
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> {
        val isPub = match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
        val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
        val hasBody = match decl.body { case Some(_) -> true; case None -> false }
        val isIntrinsic = decl.name == "mapGet" and pkgName == "Std.Collections"
        if isIntrinsic and isPub and isGeneric and hasBody and not pipeAnnsBlockSpecialization(decl.annotations) {
          dest.add(pipeInferenceOnlyFuncDecl(decl))
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

/// Copy `decl` tagged with the `__lyric_inference_only` marker annotation
/// `Lyric.Mono.annsInferenceOnlyMono` recognises (alongside the pre-existing
/// `__lyric_union_ctor_infer` union-ctor-synth marker): the monomorphizer's
/// import merge adds a marked decl to its inference table (`funcDecls`) but
/// never to its specialisation candidates (`genDecls`), exactly like a
/// union-ctor synth.  `body` is dropped (`None`) — a codegen intrinsic's
/// declaration is never specialised, so there is no body to specialise
/// FROM, and keeping a body around risks a future accidental consumer
/// treating this as a real, callable definition.
func pipeInferenceOnlyFuncDecl(decl: in FunctionDecl): FunctionDecl {
  val marker: List[Annotation] = newList()
  var ai = 0
  while ai < decl.annotations.count {
    marker.add(decl.annotations[ai])
    ai = ai + 1
  }
  val markerSegs: List[String] = newList()
  markerSegs.add("__lyric_inference_only")
  val markerArgs: List[AnnotationArg] = newList()
  marker.add(
    Annotation(name = ModulePath(segments = markerSegs, span = decl.span), args = markerArgs, span = decl.span)
  )
  FunctionDecl(
    docComments = decl.docComments,
    annotations = marker,
    visibility = decl.visibility,
    isAsync = decl.isAsync,
    name = decl.name,
    generics = decl.generics,
    params = decl.params,
    ret = decl.ret,
    whereClause = decl.whereClause,
    contracts = decl.contracts,
    body = None,
    span = decl.span
  )
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
