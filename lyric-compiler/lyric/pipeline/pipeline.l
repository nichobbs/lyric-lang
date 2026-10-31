//! pipeline.l — Lyric.Pipeline: the shared target-independent middle-end
//! driver for the three backend bridges (docs/59 §9.2).
//!
//! `Msil.Bridge`, `Jvm.Bridge`, and `Lyric.LlvmBridge` orchestrate the same
//! front/middle-end pass sequence; before this package existed each carried
//! its own copy, and every pass-ordering fix had to land three times (band
//! J2 / #2665, D-progress-642).  This package is the single authority for:
//!
//!   * the pass ORDER — parse → cfg erasure → wire-expand → plugin-expand
//!     (D207) → alias rewrite →
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
//!   * `MiddleEndOptions.tcFatal` — type-check diagnostics gate the build
//!     for the user's own packages on every target, but are advisory for
//!     the stdlib packages the JVM bundle compiles from source (the
//!     self-hosted checker lacks full builtin coverage there);
//!   * `MiddleEndOptions.nativeIntrinsics` — only a native check knows the
//!     native FFI intrinsics (`NativePtr[T]`, `NativeWeak[T]`, ...);
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
import Std.String as Str
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
import Lyric.TypeAliasResolve as TypeAliasResolve
import Lyric.ImplDefaults as ImplDefaults
import Lyric.WireExpand as WireExpand
import Lyric.PluginExpand as PluginExpand
import Lyric.Mono
import Lyric.Derives
import Lyric.Weaver as Weaver
import Lyric.SelfFields as SelfFields
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.PackageMerge as PM

/// Per-file middle-end knobs.  `tcFatal` gates the build on type-check
/// diagnostics (every target's own packages, and the native target's path
/// dependencies, #7910); when false, `tcReport` controls whether the advisory
/// diagnostics are echoed at all (JVM bundled stdlib packages pass false);
/// a reported advisory check still gates on T0080 (misplaced `old(...)`).
/// `pkgLabel` prefixes every gating diagnostic with the owning package name
/// for multi-package builds; "" prints the bare diagnostic.  `filePaths`
/// names the package's files by `Position.fileId` (docs/70 §4.1;
/// `Lyric.PackageMerge.packageFilePaths`), so every gate below prints a
/// diagnostic against the file it is in, at that file's own line; empty
/// when no path is known, and `pkgLabel` labels every diagnostic.
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

/// A specialisation of a value-generic record declared in package `pkg`.
pub record ForeignValueRecord {
  pkg: String
  item: Item
}

pub record MiddleEndOptions {
  tcFatal: Bool
  tcReport: Bool
  pkgLabel: String
  filePaths: List[String] = newList()
  awaitInTryIsHazard: Bool
  /// Whether a list literal no collection type is expected of is bound to a
  /// local of its checked type (`SymbolTable.listLiteralTypeSites`, #7818).
  /// A backend whose generic instantiations are distinct runtime types (MSIL,
  /// native) needs it to build `None` beside `Some(1)` at one closed
  /// instantiation and to read the elements back at it.  The JVM erases
  /// generics: its literal is an `ArrayList` of erased elements whatever
  /// their instantiation, and the element types it needs it recovers from the
  /// literal itself.  Every backend binds a literal whose position alone
  /// fixes its shape (`ListLiteralTypeSite.shapeRequired`, #8192).
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
  /// Receives the type checker's `methodCallArities` for the file (callee
  /// `methodCallSiteKey` -> the resolved method's parameter count, for each
  /// method call that leaves out a defaulted argument).  Every backend looks
  /// a method's overloads up by this count, so the call binds to the
  /// overload the checker resolved (#7828).
  methodCallAritiesOut: Map[String, Int]
  /// Receives the type checker's `typeArgCalleeSites` for the file: the
  /// callees written as a generic function under explicit type arguments
  /// (`f[Int](...)`), which the `?` and `await` hoists leave in their calls
  /// (#8279).  The caller passes it to `pipeWeave` for the `await` hoist.
  typeArgCalleesOut: Map[String, Bool]
  /// Receives every generic function with a body, as it stands just before
  /// monomorphisation, which erases them from the file.  A backend that
  /// instantiates generics itself at the call (native) appends them to the
  /// package's output so another package of the project can call them.  The
  /// private ones are included: instantiating a `pub` generic in another
  /// package compiles its body there, and that body may call a private
  /// generic of its own package (#8417).  Other backends pass a list and
  /// ignore it.
  genericItemsOut: List[Item]
  /// Receives, on native, each specialisation of another package's
  /// value-generic record this package uses (D173 item 3), with the package
  /// that declares the record.  The bridge adds it to that package's output
  /// once, so every package shares one `Vec__V3`.  Other backends erase the
  /// value parameters instead; they pass a list and ignore it.
  foreignValueRecordsOut: List[ForeignValueRecord]
  /// Why this package may not do I/O, from the manifest's `[layers]`
  /// (docs/65 §5, D149): "layer 'logic'" for a package in a layer whose
  /// rule does not allow `io`, "" otherwise.  A package-level `@pure` has
  /// the same effect without it.  Such a package may not call an `@io`
  /// function (Y0003) or a protected type's `entry` (Y0008), nor hold
  /// shared mutable state in a module-level `val` (Y0007).
  ioForbiddenReason: String = ""
  /// Whether the file is checked for `--target native`, the one target
  /// that lowers the FFI intrinsics of docs/01 §11.6 (`NativePtr[T]`,
  /// `NativeWeak[T]`, `nativeAddrOf`, `nativeNullPtr`); elsewhere they are
  /// unknown names.
  nativeIntrinsics: Bool = false
  /// Whether `array[N, T]` is a `List[T]` on this target (dotnet and the
  /// JVM): `Lyric.ContractElaborator.lowerArraysToLists` gives it that
  /// representation after the array operations are lowered (D167).  Native
  /// lowers the array types itself.
  arraysAsLists: Bool = false
  /// With `arraysAsLists`, keep an `array[N, T]` of a primitive element
  /// (`primitiveArrayElement`) an array, with its fill, copy and literal
  /// intrinsics, for a backend that has typed primitive arrays (the JVM,
  /// #8041).
  primitiveArrays: Bool = false
  /// Also record, in `memberRecvClassesOut` under `<origin>|<siteKey>`, the
  /// receiver classes of the bodies of other packages' generics specialised
  /// into this one, resolved by checking those bodies in the declaring
  /// package's scope (`foreignMemberRecvClasses`).  For a backend that
  /// erases generics and narrows an erased receiver with them (the JVM): a
  /// specialised copy carries the declaring package's spans, which this
  /// package's own check never saw (#7868).
  foreignRecvClasses: Bool = false
  /// Leave the type checker's warnings unreported: a dependency compiled
  /// from source into a consumer's build was already reported when the
  /// dependency itself was built.
  quietWarnings: Bool = false
}

// Report `diags`, each against the file it is in (`files`, by file id) or
// else labelled `pkgLabel` ("" for no label), and return true when any is
// error-severity.
func gate(pkgLabel: in String, files: in List[String], diags: in List[Diagnostic]): Bool {
  DiagUtil.diagReportAndAbortInFiles(pkgLabel, files, diags)
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
/// `files` names the file by file id (`Lyric.DiagnosticUtil.diagFilePath`);
/// empty labels every diagnostic `label`.  A package of several files is
/// parsed by `pipeParsePackage` instead.
pub func pipeParseAndErase(
  source: in String,
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
  label: in String,
  files: in List[String],
): Option[SourceFile] {
  val r = pipeParseAndEraseCollect(source, targetName, activeFeatures, declaredFeatures, defines)
  if gate(label, files, r.diagnostics) {
    return None
  }
  Some(value = r.file)
}

/// `pipeParseAndErase` for a caller that reports the diagnostics itself:
/// they are returned, not printed.  The passes stop at the first that
/// reports an error; the file is meaningful only when none did.
pub func pipeParseAndEraseCollect(
  source: in String,
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
): CheckReadyFile {
  val diags: List[Diagnostic] = newList()
  val parseResult = parse(source)
  appendDiagnostics(diags, parseResult.diagnostics)
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = parseResult.file, diagnostics = diags)
  }
  eraseParsed(
    parseResult.file,
    Str.contains(source, "array["),
    targetName,
    activeFeatures,
    declaredFeatures,
    defines,
    diags
  )
}

/// The front of a build of one package of several files (docs/19 §4,
/// docs/70 §4.1): `sources` parsed each as its own file of package
/// `packageName` and assembled into one package
/// (`Lyric.PackageMerge.assemblePackageFiles`), then build defines, `@cfg`
/// erasure and the rest of `pipeParseAndErase`'s passes, which stop at the
/// first that reports an error.  Every diagnostic's position names its file
/// (`Position.fileId` indexes `paths`).  `packageName` "" holds a package of
/// one file to the name it declares.  The diagnostics are returned, not
/// printed; the file is meaningful only when none is an error.
pub func pipeParsePackageCollect(
  packageName: in String,
  sources: in List[String],
  paths: in List[String],
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
): CheckReadyFile {
  val diags: List[Diagnostic] = newList()
  val asm = PM.assemblePackageFiles(packageName, sources, paths, activeFeatures, declaredFeatures, targetName)
  for d in asm.diagnostics {
    diags.add(d.diag)
  }
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = asm.file, diagnostics = diags)
  }
  eraseParsed(asm.file, asm.spellsArray, targetName, activeFeatures, declaredFeatures, defines, diags)
}

/// `pipeParsePackageCollect` with its diagnostics sent to `sink`, each
/// against its own file (`paths`, by file id) or else labelled `label`.
/// None after an error.
pub func pipeParsePackageTo(
  sink: in DiagSink,
  packageName: in String,
  sources: in List[String],
  paths: in List[String],
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
  label: in String,
): Option[SourceFile] {
  val r = pipeParsePackageCollect(packageName, sources, paths, targetName, activeFeatures, declaredFeatures, defines)
  if gateTo(sink, label, paths, r.diagnostics) {
    return None
  }
  Some(value = r.file)
}

/// The label a package's diagnostics fall back to when their file's path is
/// unknown: the path of a package of one known file, else `name`.
pub func pipePackageLabel(name: in String, sources: in List[String], paths: in List[String]): String {
  if sources.count == 1 and paths.count > 0 and paths[0].length > 0 {
    paths[0]
  } else {
    name
  }
}

/// The name `pipeParsePackage` holds a package's files to: `name` for a
/// package of several files or one whose name is a manifest entry's
/// (`nameFromManifest`), "" (the name its one file declares) otherwise.
pub func pipeHeldPackageName(name: in String, sourceCount: in Int, nameFromManifest: in Bool): String {
  if sourceCount > 1 or nameFromManifest {
    name
  } else {
    ""
  }
}

/// A dependency package's files assembled for reading its declarations only
/// (its aspect, wire and config templates and its plugins), its file-level
/// `@cfg` decided by `activeFeatures` (the dependency's own) and
/// `targetName`.  The dependency was checked when it was built, so the
/// diagnostics are not reported.
pub func pipeParseDependencyPackage(
  name: in String,
  sources: in List[String],
  paths: in List[String],
  targetName: in String,
  activeFeatures: in List[String],
): SourceFile {
  val noDeclared: List[String] = newList()
  PM.assemblePackageFiles(pipeHeldPackageName(name, sources.count, false), sources, paths, activeFeatures, noDeclared, targetName).file
}

/// One package of a build as its files, in the package's order: `sources[i]`
/// is file `i`'s text and `paths[i]` its path ("" or missing: unknown).
/// `nameFromManifest`: `name` is a manifest entry's, so even a package of
/// one file is held to it (B0013); otherwise a package of one file takes
/// the name it declares, and `name` may be "".
pub record PackageFiles {
  name: String
  sources: List[String]
  paths: List[String] = newList()
  nameFromManifest: Bool = false
}

/// `sources` as packages of one file each, `paths[i]` naming file `i`
/// ("" or missing: unknown), each taking the name it declares.
pub func pipeOneFilePackages(sources: in List[String], paths: in List[String]): List[PackageFiles] {
  val pkgs: List[PackageFiles] = newList()
  var i = 0
  while i < sources.count {
    val one: List[String] = newList()
    one.add(sources[i])
    val onePath: List[String] = newList()
    onePath.add(if i < paths.count { paths[i] } else { "" })
    pkgs.add(PackageFiles(name = "", sources = one, paths = onePath))
    i = i + 1
  }
  pkgs
}

// The passes of `pipeParseAndErase` after the parse, over `parsed`, appending
// to `diags`.  `spellsArray` is whether the source spells an `array[` type.
func eraseParsed(
  parsed: in SourceFile,
  spellsArray: in Bool,
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
  diags: in List[Diagnostic],
): CheckReadyFile {
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
  val bdRes = BD.applyBuildDefines(definesWk, parsed)
  appendDiagnostics(diags, bdRes.diagnostics)
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = bdRes.file, diagnostics = diags)
  }
  val cfgRes = Cfg.applyCfgErasure(Cfg.withTargetFeature(activeFeatures, targetName), declaredFeatures, bdRes.file)
  appendDiagnostics(diags, cfgRes.diagnostics)
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = cfgRes.file, diagnostics = diags)
  }
  // Std.BuildInfo synthesis (docs/60 §9.2): if the file imports Std.BuildInfo,
  // append the per-build `buildInfo()` accessor. Runs after @cfg erasure so the
  // synthesized item is never itself erased. `activeFeatures` is the user's own
  // feature set (not the synthetic target pseudo-feature cfg adds).
  val biFile = BD.synthesizeBuildInfo(cfgRes.file, targetName, activeFeatures, definesWk)
  val arrayImports = if spellsArray { withArrayImports(biFile) } else { biFile }
  CheckReadyFile(file = hoistValueRecordMethods(markWrappingArith(arrayImports, definesWk)), diagnostics = diags)
}

func appendDiagnostics(dst: in List[Diagnostic], src: in List[Diagnostic]): Unit {
  for d in src {
    dst.add(d)
  }
}

/// A file that spells an `array[N, T]` type may need `Std.Collections` after
/// lowering (a `List` for `.toSlice()` and, on dotnet and the JVM, the array
/// itself), so the import is added before anything resolves imports (D167).
func withArrayImports(file: in SourceFile): SourceFile {
  val segs0 = file.packageDecl.path.segments
  if segs0.count > 0 and segs0[0] == "Std" {
    return file
  }
  for imp in file.imports {
    if imp.path.segments.count == 2 and imp.path.segments[0] == "Std" and imp.path.segments[1] == "Collections" and (match imp.asAlias { case Some(_) -> false; case None -> true }) and (match imp.selector { case Some(_) -> false; case None -> true }) {
      return file
    }
  }
  val imports: List[ImportDecl] = newList()
  for imp in file.imports {
    imports.add(imp)
  }
  val segs: List[String] = newList()
  segs.add("Std")
  segs.add("Collections")
  imports.add(
    ImportDecl(
      path = ModulePath(segments = segs, span = file.span),
      selector = None,
      asAlias = None,
      isPubUse = false,
      isExtern = false,
      span = file.span
    )
  )
  SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = imports,
    items = file.items,
    span = file.span
  )
}

/// The file annotation that tells `pipeCheckAndMono` to leave the file's
/// integer arithmetic wrapping instead of checking it for overflow (D163).
pub func wrappingArithMarker(): String = "__lyric_wrapping_arith"

/// Integer overflow panics in a `debug` build and wraps in a `release` build
/// (D163).  The standard library always wraps, whichever profile the program
/// is built with, so a stdlib routine behaves the same whether it was
/// prebuilt (dotnet) or compiled from source into the program (JVM, native).
/// The decision is made here, where the resolved profile is known on every
/// target and build path, and carried to the overflow pass on the file.
func markWrappingArith(file: in SourceFile, defines: in List[BD.Define]): SourceFile {
  val release = match BD.lookupDefine(defines, "build_profile") { case Some(p) -> p == "release"; case None -> false }
  val isStd = file.packageDecl.path.segments.count > 0 and file.packageDecl.path.segments[0] == "Std"
  if not release and not isStd {
    return file
  }
  val anns: List[Annotation] = newList()
  for a in file.fileAnnotations {
    anns.add(a)
  }
  val segs: List[String] = newList()
  segs.add(wrappingArithMarker())
  val noArgs: List[AnnotationArg] = newList()
  anns.add(Annotation(name = ModulePath(segments = segs, span = file.span), args = noArgs, span = file.span))
  SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = anns,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = file.items,
    span = file.span
  )
}

/// Whether `file` carries `wrappingArithMarker()`.
pub func hasWrappingArith(file: in SourceFile): Bool {
  for a in file.fileAnnotations {
    if a.name.segments.count == 1 and a.name.segments[0] == wrappingArithMarker() {
      return true
    }
  }
  false
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
/// `label` / `files` (#6824 item 3) attribute the two gates above to the
/// file each diagnostic is in, exactly as `pipeParseAndErase`'s and
/// `pipeWeave`'s own `label`/`files` parameters do.  "" / empty prints the
/// bare diagnostic.
pub func pipeExpandAndRewrite(
  file: in SourceFile,
  weWires: in Map[String, WireExpand.CollectedWireTemplate],
  weConfigs: in Map[String, WireExpand.CollectedConfigTemplate],
  plugins: in Map[String, PluginExpand.PluginPackage],
  runWireExpand: in Bool,
  runStubbable: in Bool,
  injectWeave: in Bool,
  label: in String,
  files: in List[String],
): Option[SourceFile] {
  val r = pipeExpandAndRewriteCollect(file, weWires, weConfigs, plugins, runWireExpand, runStubbable, injectWeave)
  if gate(label, files, r.diagnostics) {
    return None
  }
  Some(value = r.file)
}

/// `pipeExpandAndRewrite` for a caller that reports the diagnostics itself:
/// they are returned, not printed.  The file is meaningful only when none is
/// an error.
pub func pipeExpandAndRewriteCollect(
  file: in SourceFile,
  weWires: in Map[String, WireExpand.CollectedWireTemplate],
  weConfigs: in Map[String, WireExpand.CollectedConfigTemplate],
  plugins: in Map[String, PluginExpand.PluginPackage],
  runWireExpand: in Bool,
  runStubbable: in Bool,
  injectWeave: in Bool,
): CheckReadyFile {
  val diags: List[Diagnostic] = newList()
  var f: SourceFile = file
  if runWireExpand {
    val weRes = WireExpand.expandFile(f, weWires, weConfigs)
    appendDiagnostics(diags, weRes.diagnostics)
    if hasErrorDiagnostic(diags) {
      return CheckReadyFile(file = f, diagnostics = diags)
    }
    f = weRes.file
  }
  // D207 plugin desugaring, on every target: `plugins` holds the build's
  // source packages (`PluginExpand.collectPluginPackage`).
  val peRes = PluginExpand.expandFile(f, plugins)
  appendDiagnostics(diags, peRes.diagnostics)
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = f, diagnostics = diags)
  }
  f = peRes.file
  val prep = pipePrepareForCheck(f, runStubbable)
  appendDiagnostics(diags, prep.diagnostics)
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = f, diagnostics = diags)
  }
  f = prep.file
  if injectWeave {
    f = Weaver.injectWeaveImports(f)
  }
  CheckReadyFile(file = f, diagnostics = diags)
}

/// D207 plugin desugaring for a `--shape component` build (docs/69 §9.3),
/// run by the native bridge before the component shims so they see the
/// plugin's exports and host imports.  The later `pipeExpandAndRewrite` finds
/// no plugin annotation left and passes the file through.  K-diagnostics gate
/// like `pipeExpandAndRewrite`'s.
pub func pipePluginExpandForComponent(
  file: in SourceFile,
  plugins: in Map[String, PluginExpand.PluginPackage],
  label: in String,
  files: in List[String],
): Option[SourceFile] {
  val r = PluginExpand.expandFileForComponent(file, plugins)
  if gate(label, files, r.diagnostics) {
    return None
  }
  Some(value = r.file)
}

/// Which of `pipeExpandAndRewrite`'s optional rewrites a build for a target
/// runs.  The one place the three bridges' differences live, so a check that
/// asks "would a build for this target reject this program?" (`lyric prove`,
/// #8311) runs the rewrites that build runs.
pub record ExpandProfile {
  runWireExpand: Bool
  runStubbable: Bool
  injectWeave: Bool
}

/// The rewrites a build for `targetName` (`dotnet`, `jvm`, `native`) runs
/// before the type check: the managed targets expand wires and synthesise
/// `@stubbable` stubs, only the JVM injects weave imports, and the native
/// bridge synthesises no stubs.
pub func pipeExpandProfile(targetName: in String): ExpandProfile {
  if targetName == "jvm" {
    return ExpandProfile(runWireExpand = true, runStubbable = true, injectWeave = true)
  }
  if targetName == "native" {
    return ExpandProfile(runWireExpand = true, runStubbable = false, injectWeave = false)
  }
  if targetName == "dotnet" {
    return ExpandProfile(runWireExpand = true, runStubbable = true, injectWeave = false)
  }
  panic("Lyric.Pipeline.pipeExpandProfile: unknown target '" + targetName + "' (expected dotnet, jvm or native)")
}

/// `pipeExpandAndRewrite` with the rewrites `targetName`'s build runs.
pub func pipeExpandAndRewriteFor(
  targetName: in String,
  file: in SourceFile,
  weWires: in Map[String, WireExpand.CollectedWireTemplate],
  weConfigs: in Map[String, WireExpand.CollectedConfigTemplate],
  plugins: in Map[String, PluginExpand.PluginPackage],
  label: in String,
  files: in List[String],
): Option[SourceFile] {
  val p = pipeExpandProfile(targetName)
  pipeExpandAndRewrite(file, weWires, weConfigs, plugins, p.runWireExpand, p.runStubbable, p.injectWeave, label, files)
}

/// `pipeExpandAndRewriteCollect` with the rewrites `targetName`'s build runs.
pub func pipeExpandAndRewriteCollectFor(
  targetName: in String,
  file: in SourceFile,
  weWires: in Map[String, WireExpand.CollectedWireTemplate],
  weConfigs: in Map[String, WireExpand.CollectedConfigTemplate],
  plugins: in Map[String, PluginExpand.PluginPackage],
): CheckReadyFile {
  val p = pipeExpandProfile(targetName)
  pipeExpandAndRewriteCollect(file, weWires, weConfigs, plugins, p.runWireExpand, p.runStubbable, p.injectWeave)
}

/// A file after the rewrites that run between parse and type check, and
/// the diagnostics they reported.  `file` is meaningful only when
/// `diagnostics` holds no error.
pub record CheckReadyFile {
  file: SourceFile
  diagnostics: List[Diagnostic]
}

/// C bindings (D158): each `@library("lib") extern func f(...): R =
/// "symbol"` becomes a body-less IFunc marked `@__cbinding("lib", "symbol")`,
/// so a managed backend's token allocation, typing and call lowering treat
/// it like any other package function and only its emission differs: a
/// P/Invoke method on MSIL, a foreign-function downcall on the JVM.  An
/// extern func without `@library` is left alone (the type checker reports
/// it, T0149, on every target but native).
///
/// C callbacks (D229).  A callback parameter (a function type with a
/// `NativeUserdata` slot, or a trailing `NativePtr[Byte]`) becomes a
/// `NativePtr[Byte]`, the C function pointer, and so does a `NativeUserdata`
/// parameter.  Each callback parameter gets a body-less trampoline
/// `__lyric_cbt_<f>_<i>` marked `@__cbtrampoline(<slot>)`, whose parameters
/// are the callback's C signature: the MSIL backend emits it as an
/// `UnmanagedCallersOnly` method and the JVM backend as the target of an
/// upcall stub, and either recovers the closure from the userdata slot.
/// Every call to such a binding in this package is rewritten so the backends
/// see the adaptation explicitly:
///
///   f(cb, ud)  ~>  __lyric_cb_call(f(__lyric_cb_fnptr(cb, "__lyric_cbt_f_0"),
///                                    __lyric_cb_ud(ud, "__lyric_cbud_3")),
///                                  "__lyric_cbud_3")
///
/// `__lyric_cb_fnptr` evaluates its operand and yields the trampoline's
/// address.  `__lyric_cb_ud` passes a pointer through unchanged; a closure
/// it pins for the call (a `GCHandle` on .NET, a handle-table entry on the
/// JVM) in the named local, and `__lyric_cb_call` releases every such pin
/// once the C function returns.  Arguments to the other `NativePtr[Byte]`
/// parameters of a binding are wrapped the same way, since the type checker
/// admits a closure for any of them (docs/01 §11.6).
pub func pipeCBindingsToFuncs(file: in SourceFile): SourceFile {
  val items: List[Item] = newList()
  val adapted: Map[String, List[String]] = newMap()
  val adaptedParams: Map[String, List[String]] = newMap()
  var changed = false
  for it in file.items {
    match it.kind {
      case IExternFunc(decl) -> match cBindingLibrary(it.annotations) {
        case Some(lib) -> {
          changed = true
          val roles = cBindingParamRoles(decl)
          items.add(cBindingFuncItem(it, cBindingPointerSignature(decl), lib))
          var pi = 0
          var needsAdapt = false
          while pi < roles.count {
            if roles[pi].length > 0 {
              needsAdapt = true
            }
            if roles[pi].startsWith("__lyric_cbt_") {
              items.add(cBindingTrampolineItem(decl, decl.params[pi], roles[pi]))
            }
            pi = pi + 1
          }
          if needsAdapt {
            adapted.add(decl.name, roles)
            val names: List[String] = newList()
            for p in decl.params {
              names.add(p.name)
            }
            adaptedParams.add(decl.name, names)
          }
        }
        case None -> items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  if not changed {
    return file
  }
  val converted = SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
  if adapted.count == 0 {
    return converted
  }
  val counter = CBindingTempCounter(next = 0)
  val pkg = file.packageDecl.path.segments
  mapExprsInFile(converted, { e: Expr -> adaptCBindingCall(e, pkg, adapted, adaptedParams, counter) })
}

/// The next free suffix for a call's pinned-userdata locals.
record CBindingTempCounter {
  var next: Int
}

/// Each parameter's role at a call of the C binding `decl`: the trampoline's
/// name for a callback parameter, `"ud"` for a parameter that may receive a
/// closure as its userdata pointer (`NativePtr[Byte]` or `NativeUserdata`),
/// and `""` for any other.
func cBindingParamRoles(decl: in ExternFuncDecl): List[String] {
  val roles: List[String] = newList()
  var i = 0
  while i < decl.params.count {
    val te = decl.params[i].ty
    if cBindingCallbackSlot(te) >= 0 {
      roles.add("__lyric_cbt_" + decl.name + "_" + toString(i))
    } else if isCBindingUserdataType(te) {
      roles.add("ud")
    } else {
      roles.add("")
    }
    i = i + 1
  }
  roles
}

func unparenType(te: in TypeExpr): TypeExpr {
  match te.kind {
    case TParen(inner) -> unparenType(inner)
    case _ -> te
  }
}

func isNativeUserdataTypeExpr(te: in TypeExpr): Bool {
  match unparenType(te).kind {
    case TRef(path) -> path.segments.count == 1 and path.segments[0] == "NativeUserdata"
    case _ -> false
  }
}

func isBytePointerTypeExpr(te: in TypeExpr): Bool {
  match unparenType(te).kind {
    case TGenericApp(head, args) -> {
      if head.segments.count != 1 or head.segments[0] != "NativePtr" or args.count != 1 {
        return false
      }
      match args[0] {
        case TAType(inner) -> match unparenType(inner).kind {
          case TRef(ip) -> ip.segments.count == 1 and ip.segments[0] == "Byte"
          case _ -> false
        }
        case TAValue(_) -> false
      }
    }
    case _ -> false
  }
}

func isCBindingUserdataType(te: in TypeExpr): Bool = isNativeUserdataTypeExpr(te) or isBytePointerTypeExpr(te)

/// The userdata slot of a callback type: its first `NativeUserdata`
/// parameter, else a trailing `NativePtr[Byte]`; -1 when `te` is not a
/// callback type (the type checker reports a function type without one,
/// T0181).
pub func cBindingCallbackSlot(te: in TypeExpr): Int {
  match unparenType(te).kind {
    case TFunction(ps, _) -> {
      var i = 0
      while i < ps.count {
        if isNativeUserdataTypeExpr(ps[i]) {
          return i
        }
        i = i + 1
      }
      if ps.count > 0 and isBytePointerTypeExpr(ps[ps.count - 1]) {
        return ps.count - 1
      }
      -1
    }
    case _ -> -1
  }
}

func bytePointerTypeExpr(span: in Span): TypeExpr {
  val head: List[String] = newList()
  head.add("NativePtr")
  val inner: List[String] = newList()
  inner.add("Byte")
  val targs: List[TypeArg] = newList()
  targs.add(TAType(ty = TypeExpr(kind = TRef(path = ModulePath(segments = inner, span = span)), span = span)))
  TypeExpr(kind = TGenericApp(head = ModulePath(segments = head, span = span), args = targs), span = span)
}

/// `decl` with every callback and `NativeUserdata` parameter written as the
/// `NativePtr[Byte]` it is in C.
func cBindingPointerSignature(decl: in ExternFuncDecl): ExternFuncDecl {
  val ps: List[Param] = newList()
  for p in decl.params {
    if cBindingCallbackSlot(p.ty) >= 0 or isNativeUserdataTypeExpr(p.ty) {
      ps.add(
        Param(
          mode = p.mode,
          modeExplicit = p.modeExplicit,
          name = p.name,
          ty = bytePointerTypeExpr(p.ty.span),
          dflt = p.dflt,
          annotations = p.annotations,
          span = p.span
        )
      )
    } else {
      ps.add(p)
    }
  }
  ExternFuncDecl(name = decl.name, params = ps, ret = decl.ret, symbol = decl.symbol, span = decl.span)
}

/// The trampoline C calls for callback parameter `p` of `decl`: a body-less
/// function with the callback's C signature (its userdata slot a
/// `NativePtr[Byte]`), marked `@__cbtrampoline(<slot>)`.
func cBindingTrampolineItem(decl: in ExternFuncDecl, p: in Param, name: in String): Item {
  val span = decl.span
  val slot = cBindingCallbackSlot(p.ty)
  val cParams: List[Param] = newList()
  var retTe: Option[TypeExpr] = None
  match unparenType(p.ty).kind {
    case TFunction(ps, r) -> {
      var i = 0
      while i < ps.count {
        val pty = if i == slot { bytePointerTypeExpr(ps[i].span) } else { ps[i] }
        val noAnns: List[Annotation] = newList()
        cParams.add(
          Param(
            mode = p.mode,
            modeExplicit = false,
            name = "p" + toString(i),
            ty = pty,
            dflt = None,
            annotations = noAnns,
            span = span
          )
        )
        i = i + 1
      }
      retTe = Some(value = r)
    }
    case _ -> ()
  }
  val args: List[AnnotationArg] = newList()
  args.add(ALiteral(value = AVInt(value = slot.toLong(), span = span), span = span))
  val segs: List[String] = newList()
  segs.add("__cbtrampoline")
  val anns: List[Annotation] = newList()
  anns.add(Annotation(name = ModulePath(segments = segs, span = span), args = args, span = span))
  val noDocs: List[DocComment] = newList()
  val noContracts: List[ContractClause] = newList()
  val fn = FunctionDecl(
    docComments = noDocs,
    annotations = anns,
    visibility = None,
    isAsync = false,
    name = name,
    generics = None,
    params = cParams,
    ret = retTe,
    whereClause = None,
    contracts = noContracts,
    body = None,
    span = span
  )
  val noItemAnns: List[Annotation] = newList()
  Item(docComments = noDocs, annotations = noItemAnns, visibility = None, kind = IFunc(decl = fn), span = span)
}

/// The userdata slot of a `@__cbtrampoline` IFunc, if it is one.
pub func cBindingTrampolineSlot(decl: in FunctionDecl): Option[Int] {
  for a in decl.annotations {
    if a.name.segments.count == 1 and a.name.segments[0] == "__cbtrampoline" and a.args.count == 1 {
      match a.args[0] {
        case ALiteral(v, _) -> match v { case AVInt(x, _) -> return Some(value = x.toInt()); case _ -> () }
        case _ -> ()
      }
    }
  }
  None
}

func intrinsicCallExpr(name: in String, args: in List[CallArg], span: in Span): Expr {
  val segs: List[String] = newList()
  segs.add(name)
  val callee = Expr(kind = EPath(path = ModulePath(segments = segs, span = span)), span = span)
  Expr(kind = ECall(fn = callee, args = args), span = span)
}

func stringLitExpr(s: in String, span: in Span): Expr = Expr(kind = ELiteral(lit = LString(text = s)), span = span)

func cBindingArgValue(a: in CallArg): Expr {
  match a {
    case CANamed(_, v, _) -> v
    case CAPositional(e) -> e
  }
}

func withCBindingArgValue(a: in CallArg, v: in Expr): CallArg {
  match a {
    case CANamed(n, _, sp) -> CANamed(name = n, value = v, span = sp)
    case CAPositional(_) -> CAPositional(expr = v)
  }
}

/// Whether `path` names a declaration of package `pkg`: a bare name, or one
/// qualified by the package's own path.
func namesOwnPackageItem(path: in ModulePath, pkg: in List[String]): Bool {
  val n = path.segments.count
  if n == 0 {
    return false
  }
  if n == 1 {
    return true
  }
  if n - 1 != pkg.count {
    return false
  }
  var k = 0
  while k < n - 1 {
    if path.segments[k] != pkg[k] {
      return false
    }
    k = k + 1
  }
  true
}

/// Rewrite one call of an adapted C binding of package `pkg` (see
/// `pipeCBindingsToFuncs`); any other expression is returned unchanged.
func adaptCBindingCall(
  e: in Expr,
  pkg: in List[String],
  adapted: in Map[String, List[String]],
  adaptedParams: in Map[String, List[String]],
  counter: in CBindingTempCounter,
): Expr {
  match e.kind {
    case ECall(fn, args) -> match fn.kind {
      case EPath(path) -> adaptCBindingCallTo(
        e,
        fn,
        path,
        args,
        pkg,
        adapted,
        adaptedParams,
        counter
      )
      case _ -> e
    }
    case _ -> e
  }
}

func adaptCBindingCallTo(
  e: in Expr,
  fnExpr: in Expr,
  path: in ModulePath,
  args: in List[CallArg],
  pkg: in List[String],
  adapted: in Map[String, List[String]],
  adaptedParams: in Map[String, List[String]],
  counter: in CBindingTempCounter,
): Expr {
  if not namesOwnPackageItem(path, pkg) {
    return e
  }
  val name = path.segments[path.segments.count - 1]
  val roles = match mapGet(adapted, name) { case Some(r) -> r; case None -> return e }
  val paramNames = match mapGet(adaptedParams, name) { case Some(pn) -> pn; case None -> return e }
  val paired = match pairCallArgs(paramNames, 0, args) { case Ok(p) -> p; case Err(_) -> return e }
  val newArgs: List[CallArg] = newList()
  for a in args {
    newArgs.add(a)
  }
  val temps: List[CallArg] = newList()
  var k = 0
  while k < paired.count {
    val ai = paired[k]
    if ai >= 0 and roles[k].length > 0 {
      val v = cBindingArgValue(args[ai])
      val wrapArgs: List[CallArg] = newList()
      wrapArgs.add(CAPositional(expr = v))
      if roles[k] == "ud" {
        val tmp = "__lyric_cbud_" + toString(counter.next)
        counter.next = counter.next + 1
        wrapArgs.add(CAPositional(expr = stringLitExpr(tmp, v.span)))
        temps.add(CAPositional(expr = stringLitExpr(tmp, v.span)))
        newArgs[ai] = withCBindingArgValue(args[ai], intrinsicCallExpr("__lyric_cb_ud", wrapArgs, v.span))
      } else {
        wrapArgs.add(CAPositional(expr = stringLitExpr(roles[k], v.span)))
        newArgs[ai] = withCBindingArgValue(args[ai], intrinsicCallExpr("__lyric_cb_fnptr", wrapArgs, v.span))
      }
    }
    k = k + 1
  }
  val call = Expr(kind = ECall(fn = fnExpr, args = newArgs), span = e.span)
  if temps.count == 0 {
    return call
  }
  val outer: List[CallArg] = newList()
  outer.add(CAPositional(expr = call))
  for t in temps {
    outer.add(t)
  }
  intrinsicCallExpr("__lyric_cb_call", outer, e.span)
}

/// The library an `@library("name")` annotation among `anns` names.
pub func cBindingLibrary(anns: in List[Annotation]): Option[String] {
  for a in anns {
    if a.name.segments.count == 1 and a.name.segments[0] == "library" and a.args.count == 1 {
      match a.args[0] {
        case ALiteral(value, _) -> match value { case AVString(v, _) -> return Some(value = v); case _ -> () }
        case _ -> ()
      }
    }
  }
  None
}

/// The `(library, symbol)` of a `@__cbinding` IFunc, if it is one.
pub func cBindingTarget(decl: in FunctionDecl): Option[CBinding] {
  for a in decl.annotations {
    if a.name.segments.count == 1 and a.name.segments[0] == "__cbinding" and a.args.count == 2 {
      val lib = match a.args[0] { case ALiteral(v, _) -> match v { case AVString(x, _) -> x; case _ -> "" }; case _ -> "" }
      val sym = match a.args[1] { case ALiteral(v, _) -> match v { case AVString(x, _) -> x; case _ -> "" }; case _ -> "" }
      return Some(value = CBinding(library = lib, symbol = sym))
    }
  }
  None
}

/// A C binding's library and exported symbol.
pub record CBinding {
  library: String
  symbol: String
}

func cBindingFuncItem(it: in Item, decl: in ExternFuncDecl, lib: in String): Item {
  val args: List[AnnotationArg] = newList()
  args.add(ALiteral(value = AVString(value = lib, span = decl.span), span = decl.span))
  args.add(ALiteral(value = AVString(value = decl.symbol, span = decl.span), span = decl.span))
  val segs: List[String] = newList()
  segs.add("__cbinding")
  val anns: List[Annotation] = newList()
  anns.add(Annotation(name = ModulePath(segments = segs, span = decl.span), args = args, span = decl.span))
  val noDocs: List[DocComment] = newList()
  val noContracts: List[ContractClause] = newList()
  val fn = FunctionDecl(
    docComments = noDocs,
    annotations = anns,
    visibility = it.visibility,
    isAsync = false,
    name = decl.name,
    generics = None,
    params = decl.params,
    ret = decl.ret,
    whereClause = None,
    contracts = noContracts,
    body = None,
    span = decl.span
  )
  Item(
    docComments = it.docComments,
    annotations = it.annotations,
    visibility = it.visibility,
    kind = IFunc(decl = fn),
    span = it.span
  )
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

/// Each `fixture n[: T] = e` as the module-level `val n[: T] = e` it stands
/// for, exactly as `Lyric.TestSynth` rewrites it for `lyric test`, so a
/// fixture is one thing in every command: a module `val` any item of a
/// `@test_module` may read.  Without this the checker accepted an ordinary
/// function reading a fixture and codegen, which dropped fixtures, failed
/// with a location-less T0115 / J008 (#8327).
pub func fixturesAsModuleVals(file: in SourceFile): SourceFile {
  var any = false
  for it in file.items {
    match it.kind {
      case IFixture(_) -> {
        any = true
      }
      case _ -> ()
    }
  }
  if not any {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFixture(fd) -> items.add(
        Item(
          docComments = it.docComments,
          annotations = it.annotations,
          visibility = it.visibility,
          kind = IVal(
            decl = ValDecl(
              pattern = Pattern(
                kind = PBinding(name = fd.name, inner = None),
                span = fd.nameSpan
              ),
              ty = fd.ty,
              init = fd.init,
              span = fd.span
            )
          ),
          span = it.span
        )
      )
      case _ -> items.add(it)
    }
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
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
  val mvRes = desugarModuleValPatterns(fixturesAsModuleVals(file))
  val diags: List[Diagnostic] = newList()
  var i = 0
  while i < mvRes.diagnostics.count {
    diags.add(mvRes.diagnostics[i])
    i = i + 1
  }
  if hasErrorDiagnostic(diags) {
    return CheckReadyFile(file = file, diagnostics = diags)
  }
  // Record-body methods with an `inout` receiver become dot-named functions
  // (#8179) before anything indexes the items.
  // A dot-named function declared through one of the file's own aliases is
  // named after the aliased type (#8217); a project build has already done
  // this for the aliases its packages import (`canonicalAliasDotNamedAll`).
  val own: List[SourceFile] = newList()
  own.add(mvRes.file)
  val arRes = Aliases.rewriteFileReporting(hoistByRefReceiverMethods(canonicalAliasDotNamed(mvRes.file, own)))
  for d in arRes.diagnostics {
    diags.add(d)
  }
  var f = arRes.file
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

/// Each file of a build with every dot-named function it declares through a
/// type alias (`func Num.neg` for `alias Num = Int`) named after the aliased
/// type (`Int.neg`), and every call written through the alias (`Num.neg(k)`,
/// `Pkg.Num.neg(k)`) renamed with it, before any backend or the type checker
/// indexes the files (#8217).  An alias is the file's own or a `pub` alias of
/// a package of `files` the file imports, followed through chains; only an
/// alias of a plain named type is followed (an alias of a generic instance,
/// a function or a tuple type is left for the type checker, T0171).  The
/// type checker resolves the same aliases for a restored package's
/// declarations (`renameAliasDotNamed`).
pub func canonicalAliasDotNamedAll(files: in List[SourceFile]): List[SourceFile] {
  val renamed: List[SourceFile] = newList()
  for f in files {
    renamed.add(canonicalAliasDotNamed(f, files))
  }
  renamed
}

func canonicalAliasDotNamed(file: in SourceFile, files: in List[SourceFile]): SourceFile {
  val raw: Map[String, TypeExpr] = newMap()
  addAliasDecls(file, false, raw)
  for imp in file.imports {
    if not imp.isExtern {
      val pkg = modulePathJoin(imp.path.segments)
      for other in files {
        if modulePathJoin(other.packageDecl.path.segments) == pkg {
          addAliasDecls(other, true, raw)
        }
      }
    }
  }
  if raw.count == 0 {
    return file
  }
  // A name the file declares as a type of its own is never an alias here.
  val ownTypes: List[String] = newList()
  for it in file.items {
    match it.kind {
      case IRecord(d) -> ownTypes.add(d.name)
      case IExposedRec(d) -> ownTypes.add(d.name)
      case IUnion(d) -> ownTypes.add(d.name)
      case IEnum(d) -> ownTypes.add(d.name)
      case IOpaque(d) -> ownTypes.add(d.name)
      case IProtected(d) -> ownTypes.add(d.name)
      case IDistinctType(d) -> ownTypes.add(d.name)
      case _ -> ()
    }
  }
  val targets: Map[String, String] = newMap()
  for name in mapKeys(raw) {
    if not ownTypes.contains(name) {
      match aliasPlainTarget(raw, name) {
        case Some(t) -> if t != name { targets.add(name, t) }
        case None -> ()
      }
    }
  }
  if targets.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> match aliasDotNamedTarget(targets, fd.name) {
        case Some(n) -> items.add(it.copy(kind = IFunc(decl = fd.copy(name = n))))
        case None -> items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  mapFileAndContracts(
    file.copy(items = items),
    { e: Expr ->
      match e.kind {
        case ECall(fn, args) -> match fn.kind {
          case EPath(p) -> if p.segments.count >= 2 and targets.containsKey(p.segments[p.segments.count - 2]) {
            val segs: List[String] = newList()
            var i = 0
            while i < p.segments.count {
              segs.add(if i == p.segments.count - 2 { aliasTargetOr(targets, p.segments[i]) } else { p.segments[i] })
              i = i + 1
            }
            Expr(kind = ECall(fn = fn.copy(kind = EPath(path = p.copy(segments = segs))), args = args), span = e.span)
          } else {
            e
          }
          case EMember(recv, m) -> match recv.kind {
            case EPath(rp) -> if rp.segments.count >= 1 and targets.containsKey(rp.segments[rp.segments.count - 1]) {
              val segs: List[String] = newList()
              var i = 0
              while i < rp.segments.count {
                segs.add(if i == rp.segments.count - 1 { aliasTargetOr(targets, rp.segments[i]) } else { rp.segments[i] })
                i = i + 1
              }
              val newRecv = recv.copy(kind = EPath(path = rp.copy(segments = segs)))
              Expr(kind = ECall(fn = fn.copy(kind = EMember(receiver = newRecv, memberName = m)), args = args), span = e.span)
            } else {
              e
            }
            // `Pkg.Num.neg(k)` written as members of a package path.
            case EMember(inner, owner) -> if targets.containsKey(owner) and isPathExpr(inner) {
              val newRecv = recv.copy(kind = EMember(receiver = inner, memberName = aliasTargetOr(targets, owner)))
              Expr(kind = ECall(fn = fn.copy(kind = EMember(receiver = newRecv, memberName = m)), args = args), span = e.span)
            } else {
              e
            }
            case _ -> e
          }
          case _ -> e
        }
        case _ -> e
      }
    },
    { s: Statement -> s }
  )
}

// The aliases `file` declares (only its `pub` ones when `pubOnly`) into
// `into`, a name already there winning.
func addAliasDecls(file: in SourceFile, pubOnly: in Bool, into: in Map[String, TypeExpr]): Unit {
  for it in file.items {
    match it.kind {
      case ITypeAlias(d) -> {
        val isPub = match it.visibility { case Some(_) -> true; case None -> false }
        val plain = match d.generics { case Some(_) -> false; case None -> true }
        if plain and (isPub or not pubOnly) and not into.containsKey(d.name) {
          into.add(d.name, d.rhs)
        }
      }
      case _ -> ()
    }
  }
}

// The plain named type the alias `name` stands for, following chains
// through `raw`; `None` for an alias of any other type, or a cycle.
func aliasPlainTarget(raw: in Map[String, TypeExpr], name: in String): Option[String] {
  var cur = name
  var steps = 0
  while steps < 32 {
    match mapGet(raw, cur) {
      case Some(te) -> match te.kind {
        case TRef(p) -> if p.segments.count == 0 {
          return None
        } else {
          cur = p.segments[p.segments.count - 1]
        }
        case _ -> return None
      }
      case None -> return if steps == 0 { None } else { Some(value = cur) }
    }
    steps = steps + 1
  }
  None
}

func isPathExpr(e: in Expr): Bool {
  match e.kind {
    case EPath(_) -> true
    case EMember(inner, _) -> isPathExpr(inner)
    case _ -> false
  }
}

func aliasDotNamedTarget(targets: in Map[String, String], name: in String): Option[String] {
  val dot = Str.lastIndexOfRaw(name, ".")
  if dot <= 0 {
    return None
  }
  match mapGet(targets, name.substring(0, dot)) {
    case Some(t) -> Some(value = t + name.substring(dot))
    case None -> None
  }
}

func aliasTargetOr(targets: in Map[String, String], name: in String): String {
  match mapGet(targets, name) {
    case Some(t) -> t
    case None -> name
  }
}

/// Each dot-named function this package declares through a type alias
/// (`func Num.neg` for `alias Num = Int`) renamed to the name the type
/// checker registered it under, the aliased type's (`Int.neg`,
/// `SymbolTable.dotNameRenames`, #8217): every call of it, by method syntax
/// or through the alias, names it that way after `rewriteByRefDotCalls`.
pub func renameAliasDotNamed(file: in SourceFile, renames: in Map[String, String]): SourceFile {
  if renames.count == 0 {
    return file
  }
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  var renamed = false
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> match mapGet(renames, pkg + "|" + fd.name) {
        case Some(n) -> {
          renamed = true
          items.add(it.copy(kind = IFunc(decl = fd.copy(name = n))))
        }
        case None -> items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  if renamed {
    file.copy(items = items)
  } else {
    file
  }
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
/// Where the middle end's diagnostics go: printed, as a build reports them,
/// or with `collect` attributed into `located` for a caller that reports
/// them itself (`lyric prove`, #8227).
pub record DiagSink {
  collect: Bool
  located: List[DiagUtil.LocatedDiagnostic]
}

/// A sink that prints.
pub func printDiagnostics(): DiagSink {
  DiagSink(collect = false, located = newList())
}

/// A sink that collects into `located`.
pub func collectDiagnostics(located: in List[DiagUtil.LocatedDiagnostic]): DiagSink {
  DiagSink(collect = true, located = located)
}

// `gate` into `sink`: whether any of `diags` is an error.
func gateTo(sink: in DiagSink, pkgLabel: in String, files: in List[String], diags: in List[Diagnostic]): Bool {
  if sink.collect {
    return DiagUtil.diagLocateAll(pkgLabel, files, diags, sink.located)
  }
  gate(pkgLabel, files, diags)
}

/// Report `diags` into `sink`, each against the file it is in (`files`, by
/// file id) or else labelled `pkgLabel`: whether any of them is an error.  For a bridge's own front-end
/// diagnostics, so a build prints them and a check (`lyric prove`, #8311)
/// collects the same ones.
pub func pipeGateTo(sink: in DiagSink, pkgLabel: in String, files: in List[String], diags: in List[Diagnostic]): Bool {
  gateTo(sink, pkgLabel, files, diags)
}

/// `pipeParseAndErase` with its diagnostics sent to `sink`.
pub func pipeParseAndEraseTo(
  sink: in DiagSink,
  source: in String,
  targetName: in String,
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  defines: in List[BD.Define],
  label: in String,
  files: in List[String],
): Option[SourceFile] {
  val r = pipeParseAndEraseCollect(source, targetName, activeFeatures, declaredFeatures, defines)
  if gateTo(sink, label, files, r.diagnostics) {
    return None
  }
  Some(value = r.file)
}

/// `pipeExpandAndRewriteFor` with its diagnostics sent to `sink`.
pub func pipeExpandAndRewriteForTo(
  sink: in DiagSink,
  targetName: in String,
  file: in SourceFile,
  weWires: in Map[String, WireExpand.CollectedWireTemplate],
  weConfigs: in Map[String, WireExpand.CollectedConfigTemplate],
  plugins: in Map[String, PluginExpand.PluginPackage],
  label: in String,
  files: in List[String],
): Option[SourceFile] {
  val r = pipeExpandAndRewriteCollectFor(targetName, file, weWires, weConfigs, plugins)
  if gateTo(sink, label, files, r.diagnostics) {
    return None
  }
  Some(value = r.file)
}

/// `pipePluginExpandForComponent` with its diagnostics sent to `sink`.
pub func pipePluginExpandForComponentTo(
  sink: in DiagSink,
  file: in SourceFile,
  plugins: in Map[String, PluginExpand.PluginPackage],
  label: in String,
  files: in List[String],
): Option[SourceFile] {
  val r = PluginExpand.expandFileForComponent(file, plugins)
  if gateTo(sink, label, files, r.diagnostics) {
    return None
  }
  Some(value = r.file)
}

// `diags` without its warnings when `quiet`.
func withoutWarningsIf(quiet: in Bool, diags: in List[Diagnostic]): List[Diagnostic] {
  if not quiet {
    return diags
  }
  val kept: List[Diagnostic] = newList()
  for d in diags {
    match d.severity {
      case DiagWarning -> ()
      case _ -> kept.add(d)
    }
  }
  kept
}

// Report `diags` into `sink` without their deciding anything.
func reportTo(sink: in DiagSink, pkgLabel: in String, files: in List[String], diags: in List[Diagnostic]): Unit {
  if sink.collect {
    val _ = DiagUtil.diagLocateAll(pkgLabel, files, diags, sink.located)
  } else {
    DiagUtil.diagReport(diags)
  }
}

/// The type check of a file and what a build rejects a file for up to and
/// including the mode check: the type checker, the checked desugarings, the
/// effect rules, the lowerings the mode check runs on, the mode check.
pub record CheckFront {
  tcRes: CheckResult
  valueSites: Map[String, FuncRefSite]
  checked: SourceFile
}

/// The front of `pipeCheckAndMono`: everything up to and including the mode
/// check, with its diagnostics sent to `sink`.  None after an error.
/// `lyric prove` runs exactly this, so it rejects what a build rejects up to
/// the mode check (#8227).
pub func pipeCheckFront(
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  opts: in MiddleEndOptions,
  sink: in DiagSink,
): Option[CheckFront] {
  val tcRes = if opts.nativeIntrinsics {
    checkWithImportedPackagesForNative(file0, importedPkgs)
  } else {
    checkWithImportedPackages(file0, importedPkgs)
  }
  if opts.tcFatal {
    if gateTo(sink, opts.pkgLabel, opts.filePaths, withoutWarningsIf(opts.quietWarnings, tcRes.diagnostics)) {
      return None
    }
  } else if opts.tcReport {
    // The check is advisory here, but T0080 (`old(...)` outside `ensures:`)
    // is purely syntactic — no builtin-coverage gap can make it a false
    // positive — and codegen has no lowering for a stray `old`, so it gates
    // regardless (#7731).  So does T0144: a module `val` pattern its
    // initializer can never match has no lowering either (#7763).  These are
    // the advisory-mode diagnostics that still stop the build.
    val advisory: List[Diagnostic] = newList()
    val gatingAdvisoryDiags: List[Diagnostic] = newList()
    for d in tcRes.diagnostics {
      if d.code == "T0080" or d.code == "T0144" {
        gatingAdvisoryDiags.add(d)
      } else {
        advisory.add(d)
      }
    }
    reportTo(sink, opts.pkgLabel, opts.filePaths, advisory)
    if gateTo(sink, opts.pkgLabel, opts.filePaths, gatingAdvisoryDiags) {
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
  // local annotated with its checked slice type (#7818), an operand the
  // await or `?` hoist will bind → a local annotated with its position's
  // type, which the hoist keeps (#7823),
  // while the type checker's span keys still
  // identify exactly one expression each (D-progress-948, 962, 963).
  val valueSites = funcValueSites(tcRes.symbols)
  // A call that passes a receiver or argument by reference to a dot-named
  // function becomes a plain call of it (#8179, #8183) before anything binds
  // a call's operands (the D171 argument-order rewrite, the `?`/`await`
  // hoists), so the receiver is an argument the call keeps as a place.
  val byRefCalls = renameAliasDotNamed(
    rewriteByRefDotCalls(file0, tcRes.symbols.byRefDotCallSites),
    tcRes.symbols.dotNameRenames
  )
  val copyRes = pipeDesugarChecked(
    byRefCalls,
    tcRes,
    valueSites,
    if opts.bindListLiteralTypes {
      tcRes.symbols.listLiteralTypeSites
    } else {
      shapeRequiredListLiteralSites(tcRes.symbols.listLiteralTypeSites)
    },
    // A native build also binds each never-producing `?` operand nothing
    // typed at the enclosing function's instantiation (#8181).
    if opts.nativeIntrinsics {
      withPropagateFallbacks(tcRes.symbols.hoistOperandTypeSites, tcRes.symbols.propagateFallbackSites)
    } else {
      tcRes.symbols.hoistOperandTypeSites
    }
  )
  if gateTo(sink, opts.pkgLabel, opts.filePaths, copyRes.diagnostics) {
    return None
  }
  if gateTo(sink, opts.pkgLabel, opts.filePaths, effectDiagnostics(file0, tcRes.symbols, opts.ioForbiddenReason)) {
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
  for ak in mapKeys(tcRes.symbols.methodCallArities) {
    match mapGet(tcRes.symbols.methodCallArities, ak) {
      case Some(n) -> if not opts.methodCallAritiesOut.containsKey(ak) { opts.methodCallAritiesOut.add(ak, n) }
      case None -> ()
    }
  }
  // Route every construction of an invariant-bearing type through its
  // checker (#7222).  After `.copy` desugaring, so a copy's constructor call
  // is covered too; after `checkedSourceOut` is captured, so generic bodies
  // exported for another package's specialisation stay checker-free.
  // Each public callable's parameter defaults, as checked and desugared, are
  // compiled into thunks its contract metadata can name (#7827, D168): here,
  // before mono drops the public generic functions from the file and while
  // every default carries its conversions.  A native build emits no contract
  // metadata (and a `--shape module` build exports every public function to
  // JavaScript), so it gets none.
  // A target whose generic instantiations are distinct runtime types (MSIL,
  // native) converts each value that flowed into a place of the same generic
  // type over a supertype of its type argument (D211); the JVM erases the
  // arguments and shares the value.
  val covered = if opts.bindListLiteralTypes and tcRes.symbols.covariantSites.count > 0 {
    applyCovariantSites(copyRes.file, tcRes.symbols)
  } else {
    copyRes.file
  }
  val withThunks = if opts.nativeIntrinsics { covered } else { synthesizeDefaultThunks(covered) }
  val invChecked = wrapInvariantConstructions(withThunks, tcRes.symbols.invariantCtorSites)
  // Operators on distinct types go through the underlying value (#7361),
  // which also re-checks a range subtype's derived arithmetic (#7226).
  val distinctLowered = lowerDistinctOps(invChecked, tcRes.symbols.distinctOpSites, tcRes.symbols.distinctCompoundSites)
  // Component-wise arithmetic on homogeneous numeric records (D155), and
  // field-by-field `==` / `!=` on value records and records deriving
  // `Equals` (D164).
  val recordLowered = lowerShowSites(lowerRecordSites(distinctLowered, tcRes.symbols), tcRes.symbols)
  // `array[N, T]` (D167): bounds-checked indexing, `.length`, `.toSlice()`,
  // `for` over an array, copies on store and zero-filled declarations become
  // forms every backend lowers.  Before the overflow pass, which still finds
  // a compound assignment's statement and its operators by their own spans.
  val arraysLowered = lowerArraySites(recordLowered, tcRes.symbols, opts.primitiveArrays, opts.arraysAsLists)
  // Integer overflow panics in a debug build and wraps in a release build or
  // in the standard library (D163); `.wrappingAdd(...)` and its siblings
  // become the plain operator either way.
  val overflowChecked = lowerOverflowChecks(
    arraysLowered,
    tcRes.symbols.overflowSites,
    tcRes.symbols.overflowCompoundTemps,
    not hasWrappingArith(recordLowered)
  )
  // A value reaching an inline range type at a position the elaborator's
  // range checks do not cover (a field, an element, a function-value
  // argument) is checked through a synthesized checker (#8031).  After the
  // overflow pass, which finds compound assignments by their own spans.
  val checked = insertRangeSiteChecks(overflowChecked, tcRes.symbols.rangeCheckSites, tcRes.symbols.rangeCompoundSites)

  val mcRes = checkFile(checked)
  if gateTo(sink, opts.pkgLabel, opts.filePaths, mcRes.diagnostics) {
    return None
  }

  // W0002 for every contract quantifier the elaborator will drop (#7228).
  // In a `@proof_required` file a quantifier is an obligation for `lyric
  // prove`, so the warning would only repeat what the annotation says.
  if not vlIsProofRequired(mcRes.level) {
    val _ = gateTo(sink, opts.pkgLabel, opts.filePaths, runtimeQuantifierWarnings(checked))
  }
  Some(value = CheckFront(tcRes = tcRes, valueSites = valueSites, checked = checked))
}

/// Component-wise arithmetic on homogeneous numeric records (D155) and
/// field-by-field `==` / `!=` on value records and records deriving `Equals`
/// (D164), lowered from the sites the checker recorded in `sym`.
pub func lowerRecordSites(file: in SourceFile, sym: in SymbolTable): SourceFile {
  lowerRecordEq(lowerRecordArith(file, sym.recordArithSites), sym.recordEqSites, sym.arrayEqSites, sym.wrapEqSites)
}

/// `array[N, T]` (D167) and `buffer[T]` pointer-closure sites recorded in
/// `sym`, lowered to forms every backend handles.
pub func lowerArraySites(
  file: in SourceFile, sym: in SymbolTable, primitiveArrays: in Bool, bufferHandles: in Bool
): SourceFile {
  lowerArrays(
    file,
    ArraySites(
      index = sym.arrayIndexSites,
      len = sym.arrayLenSites,
      slice = sym.arraySliceSites,
      forIter = sym.arrayForSites,
      copy = sym.arrayCopySites,
      zero = sym.arrayZeroSites,
      ctorZero = sym.arrayCtorZeroArgs,
      literal = if primitiveArrays { sym.arrayLiteralSites } else { newMap() },
      pointerClosures = sym.bufferPointerSites,
      bufferHandles = bufferHandles
    )
  )
}

/// Qualify each bare enum case-name pattern the type checker resolved against
/// an enum scrutinee (`SymbolTable.enumCasePatternSites`, #8421): `case Select`
/// becomes `case Ui.Core.WidgetKind.Select`, so a backend that reduces an enum
/// to its ordinal compares against the scrutinee's own enum even when another
/// enum in the program has a case of the same name.
pub func qualifyEnumCasePatterns(file: in SourceFile, sites: in Map[String, String]): SourceFile {
  if mapKeys(sites).count == 0 {
    return file
  }
  mapExprsInFile(
    file,
    { e: Expr ->
      match e.kind {
        case EMatch(scrutinee, arms) -> {
          val qualified: List[MatchArm] = newList()
          for arm in arms {
            qualified.add(
              MatchArm(pattern = qualifyEnumCasePattern(arm.pattern, sites), guard = arm.guard, body = arm.body, span = arm.span)
            )
          }
          Expr(kind = EMatch(scrutinee = scrutinee, arms = qualified), span = e.span)
        }
        case _ -> e
      }
    }
  )
}

func qualifyEnumCasePattern(p: in Pattern, sites: in Map[String, String]): Pattern {
  match p.kind {
    case PBinding(name, inner) -> match inner {
      case Some(ip) -> Pattern(
        kind = PBinding(
          name = name,
          inner = Some(value = qualifyEnumCasePattern(ip, sites))
        ),
        span = p.span
      )
      case None -> match mapGet(sites, recordCopySiteKey(p.span)) {
        case Some(enumPath) -> {
          val segs = dottedSegments(enumPath)
          segs.add(name)
          val noArgs: List[Pattern] = newList()
          Pattern(kind = PConstructor(head = ModulePath(segments = segs, span = p.span), args = noArgs), span = p.span)
        }
        case None -> p
      }
    }
    case PConstructor(head, args) -> {
      val inner: List[Pattern] = newList()
      for a in args {
        inner.add(qualifyEnumCasePattern(a, sites))
      }
      Pattern(kind = PConstructor(head = head, args = inner), span = p.span)
    }
    case PRecord(head, fields, ignoreRest) -> {
      val fs: List[RecordPatternField] = newList()
      for f in fields {
        match f {
          case RPFNamed(fname, fp, fsp) -> fs.add(
            RPFNamed(name = fname, pattern = qualifyEnumCasePattern(fp, sites), span = fsp)
          )
          case other -> fs.add(other)
        }
      }
      Pattern(kind = PRecord(head = head, fields = fs, ignoreRest = ignoreRest), span = p.span)
    }
    case PTuple(ps) -> {
      val qualifiedTuple: List[Pattern] = newList()
      for q in ps {
        qualifiedTuple.add(qualifyEnumCasePattern(q, sites))
      }
      Pattern(kind = PTuple(patterns = qualifiedTuple), span = p.span)
    }
    case PParen(ip) -> Pattern(kind = PParen(inner = qualifyEnumCasePattern(ip, sites)), span = p.span)
    case PTypeTest(ip, ty) -> Pattern(
      kind = PTypeTest(inner = qualifyEnumCasePattern(ip, sites), ty = ty),
      span = p.span
    )
    case POr(ps) -> {
      val qualifiedAlts: List[Pattern] = newList()
      for q in ps {
        qualifiedAlts.add(qualifyEnumCasePattern(q, sites))
      }
      Pattern(kind = POr(patterns = qualifiedAlts), span = p.span)
    }
    case _ -> p
  }
}

pub func pipeCheckAndMono(
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  deriveImports: in List[Item],
  monoGenFuncs: in List[FunctionDecl],
  monoIfaceDecls: in List[InterfaceDecl],
  monoRecordDecls: in List[RecordDecl],
  opts: in MiddleEndOptions,
): Option[SourceFile] {
  val front = match pipeCheckFront(file0, importedPkgs, opts, printDiagnostics()) {
    case Some(f) -> f
    case None -> return None
  }
  val tcRes = front.tcRes
  val valueSites = front.valueSites
  val checked = front.checked

  // A member body's bare field references become `self.<name>` under the
  // type checker's scoping, so no backend decides between a local and a
  // field itself (#8264).  Before the elaborator, which resolves each
  // member's own contract clauses itself and inserts its interface's clauses,
  // whose bare names no field may capture.
  val caseSites = tcRes.symbols.casePatternSites
  val selfResolved = SelfFields.resolveSelfFieldsInFile(checked, monoRecordDecls, caseSites)
  val elaborated = elaborateFileWithTypes(
    selfResolved,
    monoIfaceDecls,
    monoRecordDecls,
    caseSites,
    opts.contractsEnabled,
    InvariantBoundary(
      foreign = invariantBoundaryTypes(tcRes.symbols, true),
      local = invariantBoundaryTypes(tcRes.symbols, false)
    )
  )

  // Lower `?` error-propagation into match-unwrap + early-return (#1475).
  // Runs after the elaborator so a propagated Err/None short-circuit is not
  // forced through the success-shaped `ensures:` rewrite. `monoRecordDecls`
  // (#6967, mirroring `pipeWeave`'s identical #6702 threading below) lets
  // the `?`-hoist's `impl`-target field resolution see cross-file/
  // cross-package records, not just same-file ones. `opts.awaitInTryIsHazard`
  // (#7198) gates whether F0045's guard fires on this target.
  val asyncCalls: Map[String, Bool] = if opts.awaitAsyncCalls { tcRes.symbols.asyncCallSites } else { newMap() }
  for tk in mapKeys(tcRes.symbols.typeArgCalleeSites) {
    if not opts.typeArgCalleesOut.containsKey(tk) {
      opts.typeArgCalleesOut.add(tk, true)
    }
  }
  val propRes = lowerPropagateFileWithTypeArgCallees(
    elaborated,
    monoRecordDecls,
    opts.awaitInTryIsHazard,
    asyncCalls,
    tcRes.symbols.propagateErrWidenings,
    tcRes.symbols.typeArgCalleeSites
  )
  if gate(opts.pkgLabel, opts.filePaths, propRes.diagnostics) {
    return None
  }

  // An `inout` receiver becomes an ordinary parameter (#8179) before the
  // package's generic functions are exported to its siblings and mono.  A
  // lambda whose checked type returns `Unit` ends in `()` before then too, so
  // the specialisations another package makes of a generic carry it (#8299).
  val derived = deriveFileWithImports(
    endUnitLambdasInUnit(renameByRefReceivers(propRes.file), tcRes.symbols.lambdaUnitSites),
    deriveImports
  )

  val noSpecSites: Map[String, Map[String, ArgConversionSite]] = newMap()
  val lambdaTypes = funcValueLambdaTypes(valueSites)
  val noUnionSites: Map[String, ValueUnionCtorSite] = newMap()
  val derivedLens0 = markValueUnionCtors(
    markValueRecordCtors(
      withArrayLens(
        rewriteDottedGenericCalls(derived, tcRes.symbols.dottedGenericCallSites),
        tcRes.symbols.arrayTypeLens
      ),
      tcRes.symbols.valueRecordCtorSites
    ),
    if opts.arraysAsLists { noUnionSites } else { tcRes.symbols.valueUnionCtorSites }
  )
  val derivedLens1 = if opts.nativeIntrinsics {
    spellLambdaGenericCallTypeArgs(derivedLens0, tcRes.symbols.genericCallTypeArgSites)
  } else {
    derivedLens0
  }
  // Native erases an enum to its ordinal, so a bare case-name pattern would
  // resolve bundle-wide (first enum wins); the checker knows the scrutinee's
  // enum, so the pattern is qualified with it here (#8421).
  val derivedLens = if opts.nativeIntrinsics {
    qualifyEnumCasePatterns(derivedLens1, tcRes.symbols.enumCasePatternSites)
  } else {
    derivedLens1
  }
  for gi in derivedLens.items {
    match gi.kind {
      case IFunc(gd) -> {
        val isGen = match gd.generics { case Some(_) -> true; case None -> false }
        val hasBody = match gd.body { case Some(_) -> true; case None -> false }
        if isGen and hasBody {
          opts.genericItemsOut.add(gi)
        }
      }
      case _ -> ()
    }
  }
  val monoRes0 = monoFileWithLambdaTypes(
    derivedLens,
    monoGenFuncs,
    monoIfaceDecls,
    monoRecordDecls,
    lambdaTypes,
    tcRes.symbols.callResultTypes,
    tcRes.symbols.genericCallTypeArgSites,
    tcRes.symbols.valueGenericCallSites,
    tcRes.symbols.lambdaParamTypeSites,
    noSpecSites
  )
  if gate(opts.pkgLabel, opts.filePaths, monoRes0.diagnostics) {
    return None
  }
  // The dot-named calls in another package's generic bodies that are
  // rewritten into plain calls there (#8179, #8217, #8219), keyed
  // `<origin>|<recordCopySiteKey>`: the bodies arrive here as parsed.
  val foreignDotCalls: Map[String, ByRefDotCall] = newMap()
  foreignMethodCallArities(
    monoRes0.foreignSpecs,
    file0,
    importedPkgs,
    monoGenFuncs,
    opts.nativeIntrinsics,
    opts.methodCallAritiesOut,
    foreignDotCalls
  )
  if opts.foreignRecvClasses {
    foreignMemberRecvClasses(
      monoRes0.foreignSpecs,
      file0,
      importedPkgs,
      monoGenFuncs,
      opts.nativeIntrinsics,
      opts.memberRecvClassesOut
    )
  }
  val foreignUnitSites = foreignUnitLambdaSites(
    monoRes0.foreignSpecs,
    file0,
    importedPkgs,
    monoGenFuncs,
    opts.nativeIntrinsics
  )
  val foreignProp = foreignPropagateSites(monoRes0.foreignSpecs, file0, importedPkgs, monoGenFuncs, opts)
  val foreignFuncValues: Map[String, FuncRefSite] = newMap()
  foreignFuncValueSites(
    monoRes0.foreignSpecs,
    file0,
    importedPkgs,
    monoGenFuncs,
    opts.nativeIntrinsics,
    foreignFuncValues
  )
  // A specialisation whose body uses `==`/`!=` on a type parameter bound to
  // a named type or a tuple is re-checked too, so the comparison is lowered
  // as the bound type's (D172 item 4).
  val toRecheck: List[UnsignedSpecRequest] = newList()
  for us in monoRes0.unsignedSpecs {
    toRecheck.add(us)
  }
  // A generic from another package is checked in that package's scope, with
  // the types this package declares added to it (`addConsumerTypes`), so an
  // operator on a type parameter bound to a distinct or record type declared
  // here is lowered for that type (#7996, #8017, #8530); its `==` reaches the
  // bound type's own structural equality (D172 item 3) instead.
  for ss in monoRes0.structSpecs {
    if (ss.originPkg == "" and (specUsesEquality(ss.specDecl) or specMayRender(ss.specDecl))) or ss.opBound {
      toRecheck.add(ss)
    }
  }
  // A generic from another package whose own body spells `UInt`/`ULong` has
  // concrete unsigned operands independent of its type parameters, which only
  // a check of the specialisation can give their signedness, whatever the
  // type arguments are (#8019).
  val rechecked: Map[String, Bool] = newMap()
  for rc in toRecheck {
    rechecked.add(rc.specName, true)
  }
  for fs in monoRes0.foreignSpecs {
    if not rechecked.containsKey(fs.specName) and specMentionsUnsigned(fs.specDecl) {
      rechecked.add(fs.specName, true)
      toRecheck.add(fs)
    }
  }
  if toRecheck.count == 0 {
    return match finishValueRecords(lowerForeignPropagate(rewriteForeignFuncValues(rewriteForeignDotCalls(endForeignUnitLambdas(monoRes0.file, foreignUnitSites), foreignDotCalls), foreignFuncValues), foreignProp, opts), file0, importedPkgs, tcRes, opts) {
      case Some(f) -> Some(value = finishMono(f, opts))
      case None -> None
    }
  }
  // A specialisation binding a type parameter to `UInt`/`ULong` is checked
  // on its own, and specialised again with what the checker records in it
  // (#7842).
  val recheckDiags: List[Diagnostic] = newList()
  val specArrays: Map[String, SpecArraySites] = newMap()
  val specSites = recheckSpecs(
    toRecheck,
    file0,
    importedPkgs,
    monoGenFuncs,
    opts.nativeIntrinsics,
    recheckDiags,
    Some(value = tcRes.symbols),
    specArrays
  )
  if gate(opts.pkgLabel, opts.filePaths, recheckDiags) {
    return None
  }
  val monoRes = monoFileWithLambdaTypes(
    derivedLens,
    monoGenFuncs,
    monoIfaceDecls,
    monoRecordDecls,
    lambdaTypes,
    tcRes.symbols.callResultTypes,
    tcRes.symbols.genericCallTypeArgSites,
    tcRes.symbols.valueGenericCallSites,
    tcRes.symbols.lambdaParamTypeSites,
    specSites
  )
  if gate(opts.pkgLabel, opts.filePaths, monoRes.diagnostics) {
    return None
  }
  // A specialisation is lowered in the consuming file, so whether its
  // overflow checks apply follows the consumer's profile and package (the
  // marker on `file0`), not the file the generic was declared in.
  match finishValueRecords(lowerSpecArrays(lowerForeignPropagate(rewriteForeignFuncValues(rewriteForeignDotCalls(endForeignUnitLambdas(monoRes.file, foreignUnitSites), foreignDotCalls), foreignFuncValues), foreignProp, opts), specArrays, opts.primitiveArrays, not opts.arraysAsLists, not hasWrappingArith(file0)), file0, importedPkgs, tcRes, opts) {
    case Some(f) -> Some(value = finishMono(f, opts))
    case None -> None
  }
}

// The monomorphised file as the backend receives it: negated integer
// literals folded, and on a target that represents `array[N, T]` as a
// `List[T]` (D167), the array intrinsics and types lowered to lists.
func finishMono(file: in SourceFile, opts: in MiddleEndOptions): SourceFile {
  // Again after mono: a function with an `inout` receiver specialised from
  // a restored package's generic body arrives with its `self` (#8179).
  val folded = mapExprsInFile(renameByRefReceivers(file), foldNegatedIntLiteral)
  if opts.arraysAsLists {
    lowerArraysToLists(folded, opts.primitiveArrays)
  } else {
    folded
  }
}

/// `array[N, T]` as a `List[T]` (D167): the fill and copy intrinsics become
/// loops and every remaining `array[N, T]` type expression becomes `List[T]`.
func lowerArraysToLists(file: in SourceFile, primitiveArrays: in Bool): SourceFile {
  val marker: Map[String, TypeExpr] = newMap()
  marker.add(arraysAsListsKey(), TypeExpr(kind = TUnit, span = file.span))
  if primitiveArrays {
    marker.add(primitiveArraysKey(), TypeExpr(kind = TUnit, span = file.span))
  }
  TypeAliasResolve.resolveAliasesInFile(marker, lowerArrayIntrinsicsToLists(file, primitiveArrays))
}

// ─── Unsigned specialisations (#7842) ──────────────────────────────────────
// A generic body is type-checked once, over its type parameters, so whether
// an operand of type `T` is a `UInt`/`ULong` (and must compare, divide and
// print unsigned) is known only once `T` is bound.  Each specialisation
// binding a type parameter to `UInt`/`ULong` is type-checked as the
// non-generic function it is, in the scope of the package declaring the
// generic, and the conversions the checker records in its body
// (`argConversionSites`: unsigned operands, widenings, literal suffixes) are
// returned keyed by the specialisation's name.  The other functions in that
// scope are checked as signatures only.  A specialisation whose body does
// not check cleanly cannot be given its operands' signedness, so it is M0007.
pub func recheckUnsignedSpecs(
  specs: in List[UnsignedSpecRequest],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
  diags: in List[Diagnostic],
): Map[String, Map[String, ArgConversionSite]] {
  val noArrays: Map[String, SpecArraySites] = newMap()
  recheckSpecs(specs, file0, importedPkgs, monoGenFuncs, native, diags, None, noArrays)
}

/// The `array[N, T]` operations (D167) a re-checked specialisation records
/// that its generic body, checked over `T`, could not: the sites to lower on
/// the specialised function's own body.
pub record SpecArraySites {
  arrays: ArraySites
  arrayEq: Map[String, ArrayEqSite]
  recordEq: Map[String, RecordEqSite]
  wrapEq: Map[String, WrapEqSite]
  /// The resolved lengths of the function's `array[N, T]` type expressions
  /// whose `N` is not a literal.
  lens: Map[String, Int]
  /// Each construction of a value-generic record with the lengths it binds
  /// (D169): a generic from another package reaches this file with none of
  /// its constructions marked.
  valueCtors: Map[String, List[TypeArg]]
  /// Each construction of a case of a union with value generic parameters,
  /// for a target with one union per length (#8149).
  valueUnionCtors: Map[String, ValueUnionCtorSite]
  /// The operators on distinct types (#7361), compound assignments to them,
  /// and the derived component-wise operators on records (D155) the
  /// specialised body holds, which its generic body, checked over a type
  /// parameter, could not record (#7996, #8017).
  distinctOps: Map[String, String]
  distinctCompound: Map[String, String]
  recordArith: Map[String, RecordArithSite]
  /// The `+`, `-`, `*` and unary `-` on `Int`, `Long`, `UInt`, `ULong` and
  /// `Byte` the specialised body holds, which its generic body, checked over
  /// a type parameter, could not record, so a specialisation at `Int` panics
  /// on overflow in a debug build as the same code written at `Int` does
  /// (D163, #8532).  Empty for the standard library, which always wraps.
  overflow: Map[String, String]
  overflowTemps: Map[String, CompoundTemps]
  /// The stringified operands of a structured type the specialised body holds
  /// (D282), which its generic body, checked over a type parameter, could not
  /// record, and the functions rendering them.
  show: Map[String, String]
  showHelpers: List[FunctionDecl]
}

// A specialisation binding a type parameter to `UInt`/`ULong` or to an array
// type is re-checked as the non-generic function it is.  `known`, for the
// file's own generics, holds what the generic body's own check recorded and
// the pre-monomorphisation passes have already lowered.
pub func recheckSpecs(
  specs: in List[UnsignedSpecRequest],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
  diags: in List[Diagnostic],
  known: in Option[SymbolTable],
  arrAcc: in Map[String, SpecArraySites],
): Map[String, Map[String, ArgConversionSite]] {
  val acc: Map[String, Map[String, ArgConversionSite]] = newMap()
  // One check per origin package and round; a round holds at most one
  // specialisation of each generic, since the specialisations of one generic
  // share its source spans.
  var pending: List[UnsignedSpecRequest] = newList()
  for sp in specs {
    pending.add(sp)
  }
  while pending.count > 0 {
    val origin = pending[0].originPkg
    val round: List[UnsignedSpecRequest] = newList()
    val rest: List[UnsignedSpecRequest] = newList()
    val roundSpans: List[Int] = newList()
    for sp in pending {
      val start = sp.specDecl.span.startPos.offset
      if sp.originPkg == origin and not intListContainsPipe(roundSpans, start) {
        round.add(sp)
        roundSpans.add(start)
      } else {
        rest.add(sp)
      }
    }
    pending = rest
    recheckSpecRound(round, origin, file0, importedPkgs, monoGenFuncs, native, diags, acc, known, arrAcc)
  }
  acc
}

// The scope a specialisation of `origin`'s generic is checked in: that
// package's items as signatures (`items`), with its private generics, which a
// specialised body may call, the packages it imports (`imports`), and every
// other package (`checkPkgs`).  False when `origin` is not among
// `importedPkgs`.
func addOriginScope(
  origin: in String,
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  items: in List[Item],
  imports: in List[ImportDecl],
  checkPkgs: in List[ImportedPackage],
): Bool {
  var found = false
  for ip in importedPkgs {
    if ip.name == origin {
      found = true
      for it in ip.items {
        items.add(signatureOnlyItem(it))
      }
      for dep in ip.imports {
        imports.add(wholeImportDecl(dep, file0.span))
      }
    } else {
      checkPkgs.add(ip)
    }
  }
  if not found {
    return false
  }
  for gf in monoGenFuncs {
    if originPkgOf(gf.annotations) == origin and not itemsDeclareFunc(items, gf) {
      items.add(funcItem(stripBody(gf)))
    }
  }
  true
}

// ─── Method calls in other packages' generics (#7828, #8098) ───────────────
// A call that leaves out a defaulted argument, or that a dot-named function
// answers, is dispatched to the callee the type checker resolved
// (`SymbolTable.methodCallArities`), keyed by the call's source span.  A
// specialisation of another package's generic carries that package's spans,
// which this package's check never saw, so each such specialisation whose
// body calls a method that may need the resolution is checked in the scope
// of the package declaring the generic, and what the checker records in its
// body goes to `acc` keyed `<origin>|<methodCallSiteKey>`; each backend looks
// a call in a body specialised from `origin` up under that key.  The checker
// resolves a call in a generic body the same way for every specialisation,
// so one specialisation of each generic is checked.  The same check records
// the dot-named calls in those bodies that are rewritten into plain calls
// (`SymbolTable.byRefDotCallSites`), which go to `dotCalls` under the same
// keys for `rewriteForeignDotCalls`.
pub func foreignMethodCallArities(
  specs: in List[UnsignedSpecRequest],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
  acc: in Map[String, Int],
  dotCalls: in Map[String, ByRefDotCall],
): Unit {
  if specs.count == 0 {
    return
  }
  val names = dispatchSensitiveMethodNames(file0, importedPkgs)
  for rn in mapKeys(dotCallRewriteMethodNames(file0, importedPkgs)) {
    if not names.containsKey(rn) {
      names.add(rn, true)
    }
  }
  if names.count == 0 {
    return
  }
  val byOrigin: Map[String, List[FunctionDecl]] = newMap()
  val seen: Map[String, Bool] = newMap()
  for sp in specs {
    val seenKey = sp.originPkg + "|" + recordCopySiteKey(sp.specDecl.span)
    if not seen.containsKey(seenKey) and specCallsAnyMethod(sp.specDecl, names) {
      seen.add(seenKey, true)
      match mapGet(byOrigin, sp.originPkg) {
        case Some(ds) -> ds.add(sp.specDecl)
        case None -> {
          val ds: List[FunctionDecl] = newList()
          ds.add(sp.specDecl)
          byOrigin.add(sp.originPkg, ds)
        }
      }
    }
  }
  for origin in mapKeys(byOrigin) {
    match mapGet(byOrigin, origin) {
      case Some(decls) -> foreignOriginArities(origin, decls, file0, importedPkgs, monoGenFuncs, native, acc, dotCalls)
      case None -> ()
    }
  }
}

// The receiver classes (`SymbolTable.memberRecvClasses`) of the bodies of
// `specs`, specialisations of other packages' generics, resolved in the scope
// of the package declaring each generic and recorded in `acc` under
// `<origin>|<siteKey>`.  A receiver's class is that of its nominal type, which
// no specialisation of the generic changes (a type parameter has none), so one
// specialisation of each generic stands for all.
pub func foreignMemberRecvClasses(
  specs: in List[UnsignedSpecRequest],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
  acc: in Map[String, String],
): Unit {
  if specs.count == 0 {
    return
  }
  val byOrigin: Map[String, List[FunctionDecl]] = newMap()
  val seen: Map[String, Bool] = newMap()
  for sp in specs {
    if sp.originPkg.length == 0 {
      continue
    }
    val seenKey = sp.originPkg + "|" + recordCopySiteKey(sp.specDecl.span)
    if not seen.containsKey(seenKey) and specHasMemberAccess(sp.specDecl) {
      seen.add(seenKey, true)
      match mapGet(byOrigin, sp.originPkg) {
        case Some(ds) -> ds.add(sp.specDecl)
        case None -> {
          val ds: List[FunctionDecl] = newList()
          ds.add(sp.specDecl)
          byOrigin.add(sp.originPkg, ds)
        }
      }
    }
  }
  for origin in mapKeys(byOrigin) {
    match mapGet(byOrigin, origin) {
      case Some(decls) -> match checkInOriginScope(origin, decls, file0, importedPkgs, monoGenFuncs, native) {
        case Some(res) -> {
          for k in mapKeys(res.symbols.memberRecvClasses) {
            if not acc.containsKey(origin + "|" + k) {
              match mapGet(res.symbols.memberRecvClasses, k) {
                case Some(cls) -> acc.add(origin + "|" + k, cls)
                case None -> ()
              }
            }
          }
        }
        case None -> ()
      }
      case None -> ()
    }
  }
}

func specHasMemberAccess(decl: in FunctionDecl): Bool {
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noImports: List[ImportDecl] = newList()
  val items: List[Item] = newList()
  items.add(funcItem(decl))
  val f = SourceFile(
    moduleDoc = noDocs,
    files = newList(),
    fileAnnotations = noAnns,
    packageDecl = PackageDecl(path = ModulePath(segments = newList(), span = decl.span), span = decl.span),
    imports = noImports,
    items = items,
    span = decl.span
  )
  anyExprInFile(f, { e: Expr -> match e.kind { case EMember(_, _) -> true; case _ -> false } })
}

func foreignOriginArities(
  origin: in String,
  decls: in List[FunctionDecl],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
  acc: in Map[String, Int],
  dotCalls: in Map[String, ByRefDotCall],
): Unit {
  // A package not available here was never resolved against, so its
  // generics' calls dispatch by the arguments written, as before.
  val res = match checkInOriginScope(origin, decls, file0, importedPkgs, monoGenFuncs, native) {
    case Some(r) -> r
    case None -> return
  }
  // A package's source offsets are unique across its files (and a restored
  // package is synthesised as one source), so an entry recorded at a
  // signature's default never shares a key with a call in a body.
  for k in mapKeys(res.symbols.methodCallArities) {
    if not acc.containsKey(origin + "|" + k) {
      match mapGet(res.symbols.methodCallArities, k) {
        case Some(code) -> acc.add(origin + "|" + k, code)
        case None -> ()
      }
    }
  }
  // A call the origin package's check rewrites names its function through
  // that package, which a call specialised here does not belong to.
  for k in mapKeys(res.symbols.byRefDotCallSites) {
    if not dotCalls.containsKey(origin + "|" + k) {
      match mapGet(res.symbols.byRefDotCallSites, k) {
        case Some(site) -> dotCalls.add(
          origin + "|" + k,
          if site.originPkg.length > 0 { site } else { site.copy(originPkg = origin) }
        )
        case None -> ()
      }
    }
  }
}

// `decls` (specialisations of `origin`'s generics) type-checked in the scope
// of `origin`, the package declaring them: its other functions as signatures
// only.  None when `origin` is not available here.
func checkInOriginScope(
  origin: in String,
  decls: in List[FunctionDecl],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
): Option[CheckResult] {
  val items: List[Item] = newList()
  val imports: List[ImportDecl] = newList()
  val checkPkgs: List[ImportedPackage] = newList()
  if not addOriginScope(origin, file0, importedPkgs, monoGenFuncs, items, imports, checkPkgs) {
    return None
  }
  for d in decls {
    items.add(funcItem(d))
  }
  val checkFile = SourceFile(
    moduleDoc = file0.moduleDoc,
    files = file0.files,
    fileAnnotations = file0.fileAnnotations,
    packageDecl = PackageDecl(
      path = ModulePath(segments = dottedSegments(origin), span = file0.span),
      span = file0.span
    ),
    imports = imports,
    items = items,
    span = file0.span
  )
  Some(
    value = if native {
      checkWithImportedPackagesForNative(checkFile, checkPkgs)
    } else {
      checkWithImportedPackages(checkFile, checkPkgs)
    }
  )
}

// ─── Unit lambdas in other packages' generics (#8299) ──────────────────────
// `endUnitLambdasInUnit` ends a lambda whose checked type returns `Unit` in
// `()`, for this package's own code.  A specialisation of another package's
// generic is copied from that package's declaration, which this package's
// check never saw, so each one whose body holds a lambda is checked in the
// scope of its package, and what the checker records in it is returned per
// package (a package's source offsets are unique across its files).
pub func foreignUnitLambdaSites(
  specs: in List[UnsignedSpecRequest],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
): Map[String, Map[String, Bool]] {
  val sitesByOrigin: Map[String, Map[String, Bool]] = newMap()
  val byOrigin: Map[String, List[FunctionDecl]] = newMap()
  val seen: Map[String, Bool] = newMap()
  for sp in specs {
    val seenKey = sp.originPkg + "|" + recordCopySiteKey(sp.specDecl.span)
    if sp.originPkg.length > 0 and not seen.containsKey(seenKey) and funcDeclHasLambda(sp.specDecl) {
      seen.add(seenKey, true)
      match mapGet(byOrigin, sp.originPkg) {
        case Some(ds) -> ds.add(sp.specDecl)
        case None -> {
          val ds: List[FunctionDecl] = newList()
          ds.add(sp.specDecl)
          byOrigin.add(sp.originPkg, ds)
        }
      }
    }
  }
  for origin in mapKeys(byOrigin) {
    match mapGet(byOrigin, origin) {
      case Some(decls) -> match checkInOriginScope(origin, decls, file0, importedPkgs, monoGenFuncs, native) {
        case Some(res) -> sitesByOrigin.add(origin, res.symbols.lambdaUnitSites)
        case None -> ()
      }
      case None -> ()
    }
  }
  sitesByOrigin
}

// ─── Function values in other packages' generics (#8329) ────────────────────
// A package's own function named as a value (not called) inside its generic
// body is stood for, in that package, by a forwarding thunk.  A
// specialisation of the generic in another package is lowered there, which
// has no such thunk and cannot see the name, so each specialisation whose
// body names one of its origin package's functions as a bare path is checked
// in the scope of that package, and what the checker records
// (`SymbolTable.ownFuncValueSites`) goes to `acc` keyed
// `<origin>|<recordCopySiteKey>`; `rewriteForeignFuncValues` turns each such
// reference into a forwarding lambda calling the function by its qualified
// name, as a function of an imported package used as a value is (D-progress-963).
pub func foreignFuncValueSites(
  specs: in List[UnsignedSpecRequest],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
  acc: in Map[String, FuncRefSite],
): Unit {
  val byOrigin: Map[String, List[FunctionDecl]] = newMap()
  val seen: Map[String, Bool] = newMap()
  for sp in specs {
    if sp.originPkg.length == 0 {
      continue
    }
    val seenKey = sp.originPkg + "|" + recordCopySiteKey(sp.specDecl.span)
    if not seen.containsKey(seenKey) and specNamesOriginFunc(sp.specDecl, sp.originPkg, importedPkgs) {
      seen.add(seenKey, true)
      match mapGet(byOrigin, sp.originPkg) {
        case Some(ds) -> ds.add(sp.specDecl)
        case None -> {
          val ds: List[FunctionDecl] = newList()
          ds.add(sp.specDecl)
          byOrigin.add(sp.originPkg, ds)
        }
      }
    }
  }
  for origin in mapKeys(byOrigin) {
    match mapGet(byOrigin, origin) {
      case Some(decls) -> match checkInOriginScope(origin, decls, file0, importedPkgs, monoGenFuncs, native) {
        case Some(res) -> {
          for k in mapKeys(res.symbols.ownFuncValueSites) {
            if not acc.containsKey(origin + "|" + k) {
              match mapGet(res.symbols.ownFuncValueSites, k) {
                case Some(site) -> acc.add(origin + "|" + k, site)
                case None -> ()
              }
            }
          }
        }
        case None -> ()
      }
      case None -> ()
    }
  }
}

// Whether the body of `decl`, specialised from a generic of `origin`, names
// one of that package's non-generic functions as a bare path.
func specNamesOriginFunc(decl: in FunctionDecl, origin: in String, importedPkgs: in List[ImportedPackage]): Bool {
  val names: Map[String, Bool] = newMap()
  for ip in importedPkgs {
    if ip.name == origin {
      for it in ip.items {
        match it.kind {
          case IFunc(fd) -> match fd.generics { case Some(_) -> (); case None -> names.add(fd.name, true) }
          case _ -> ()
        }
      }
    }
  }
  if names.count == 0 {
    return false
  }
  val isRef = { e: Expr ->
    match e.kind {
      case EPath(p) -> p.segments.count == 1 and names.containsKey(p.segments[0])
      case _ -> false
    }
  }
  match decl.body {
    case Some(FBBlock(b)) -> anyInBlock(b, isRef)
    case Some(FBExpr(ex)) -> anyInExpr(ex, isRef)
    case None -> false
  }
}

/// Each function of `file` specialised from another package's generic, its
/// references to that package's functions as values replaced by forwarding
/// lambdas as that package's check recorded them (`foreignFuncValueSites`).
pub func rewriteForeignFuncValues(file: in SourceFile, sites: in Map[String, FuncRefSite]): SourceFile {
  if sites.count == 0 {
    return file
  }
  var changed = false
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> {
        val origin = originPkgOf(fd.annotations)
        val own: Map[String, FuncRefSite] = newMap()
        if origin.length > 0 {
          val prefix = origin + "|"
          for k in mapKeys(sites) {
            if Str.startsWith(k, prefix) {
              match mapGet(sites, k) {
                case Some(site) -> own.add(k.substring(prefix.length), site)
                case None -> ()
              }
            }
          }
        }
        if own.count > 0 {
          changed = true
          val one = mapExprsInFile(
            oneItemFile(file, it),
            { e: Expr ->
              match e.kind {
                case EPath(_) -> match mapGet(own, recordCopySiteKey(e.span)) {
                  case Some(site) -> funcRefLambdaMono(site, e.span)
                  case None -> e
                }
                case _ -> e
              }
            }
          )
          items.add(one.items[0])
        } else {
          items.add(it)
        }
      }
      case _ -> items.add(it)
    }
  }
  if changed {
    file.copy(items = items)
  } else {
    file
  }
}

// ─── `?` in other packages' generics (#8337) ───────────────────────────────
// `?` is lowered into a `match` and an early return before specialisation,
// for this package's own code.  A generic of another package arrives as it was
// written (a sibling package's parsed source, a restored package's contract
// body), so its `?` would reach the backend unlowered and compile as the
// operand itself.  Each specialisation of such a generic is lowered here,
// with what the check of its body in its own package's scope records: the
// error widenings of its `?`s and its direct async calls.  A package that is
// not available to check is lowered without them.
pub record ForeignPropagateSites {
  widenings: Map[String, PropagateErrWidening]
  asyncCalls: Map[String, Bool]
  typeArgCallees: Map[String, Bool]
}

pub func foreignPropagateSites(
  specs: in List[UnsignedSpecRequest],
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  opts: in MiddleEndOptions,
): Map[String, ForeignPropagateSites] {
  val sitesByOrigin: Map[String, ForeignPropagateSites] = newMap()
  val byOrigin: Map[String, List[FunctionDecl]] = newMap()
  val seen: Map[String, Bool] = newMap()
  for sp in specs {
    if sp.originPkg.length == 0 {
      continue
    }
    val seenKey = sp.originPkg + "|" + recordCopySiteKey(sp.specDecl.span)
    if not seen.containsKey(seenKey) and funcDeclHasPropagate(sp.specDecl) {
      seen.add(seenKey, true)
      match mapGet(byOrigin, sp.originPkg) {
        case Some(ds) -> ds.add(sp.specDecl)
        case None -> {
          val ds: List[FunctionDecl] = newList()
          ds.add(sp.specDecl)
          byOrigin.add(sp.originPkg, ds)
        }
      }
    }
  }
  for origin in mapKeys(byOrigin) {
    match mapGet(byOrigin, origin) {
      case Some(decls) -> match checkInOriginScope(origin, decls, file0, importedPkgs, monoGenFuncs, opts.nativeIntrinsics) {
        case Some(res) -> sitesByOrigin.add(
          origin,
          ForeignPropagateSites(
            widenings = res.symbols.propagateErrWidenings,
            asyncCalls = if opts.awaitAsyncCalls {
              res.symbols.asyncCallSites
            } else {
              newMap()
            },
            typeArgCallees = res.symbols.typeArgCalleeSites
          )
        )
        case None -> sitesByOrigin.add(
          origin,
          ForeignPropagateSites(
            widenings = newMap(),
            asyncCalls = newMap(),
            typeArgCallees = newMap()
          )
        )
      }
      case None -> ()
    }
  }
  sitesByOrigin
}

func funcDeclHasPropagate(fd: in FunctionDecl): Bool {
  val isProp = { e: Expr -> match e.kind { case EPropagate(_) -> true; case _ -> false } }
  match fd.body {
    case Some(FBBlock(b)) -> anyInBlock(b, isProp)
    case Some(FBExpr(ex)) -> anyInExpr(ex, isProp)
    case None -> false
  }
}

/// Each function of `file` specialised from another package's generic, its
/// `?` lowered as `foreignPropagateSites` recorded for that package.
pub func lowerForeignPropagate(
  file: in SourceFile,
  sitesByOrigin: in Map[String, ForeignPropagateSites],
  opts: in MiddleEndOptions,
): SourceFile {
  if sitesByOrigin.count == 0 {
    return file
  }
  val noRecords: List[RecordDecl] = newList()
  var changed = false
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> match mapGet(sitesByOrigin, originPkgOf(fd.annotations)) {
        case Some(sites) -> {
          if funcDeclHasPropagate(fd) {
            val res = lowerPropagateFileWithTypeArgCallees(
              oneItemFile(file, it),
              noRecords,
              opts.awaitInTryIsHazard,
              sites.asyncCalls,
              sites.widenings,
              sites.typeArgCallees
            )
            // The lowering's own diagnostics (F0020, F0045) are properties of the
            // generic's body, so the declaring package's build already reported
            // them; a specialisation cannot newly fail them.
            if res.diagnostics.count == 0 and res.file.items.count == 1 {
              changed = true
              items.add(res.file.items[0])
            } else {
              items.add(it)
            }
          } else {
            items.add(it)
          }
        }
        case None -> items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  if changed {
    file.copy(items = items)
  } else {
    file
  }
}

func funcDeclHasLambda(fd: in FunctionDecl): Bool {
  val isLambda = { e: Expr -> match e.kind { case ELambda(_, _) -> true; case _ -> false } }
  match fd.body {
    case Some(FBBlock(b)) -> anyInBlock(b, isLambda)
    case Some(FBExpr(ex)) -> anyInExpr(ex, isLambda)
    case None -> false
  }
}

// Each function of `file` specialised from another package's generic, with
// its `Unit` lambdas ended in `()` as that package's check typed them
// (`foreignUnitLambdaSites`).
func endForeignUnitLambdas(file: in SourceFile, sitesByOrigin: in Map[String, Map[String, Bool]]): SourceFile {
  if sitesByOrigin.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> match mapGet(sitesByOrigin, originPkgOf(fd.annotations)) {
        case Some(sites) -> {
          val single = SourceFile(
            moduleDoc = file.moduleDoc,
            files = file.files,
            fileAnnotations = file.fileAnnotations,
            packageDecl = file.packageDecl,
            imports = file.imports,
            items = singleItemList(it),
            span = file.span
          )
          items.add(endUnitLambdasInUnit(single, sites).items[0])
        }
        case None -> items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

func singleItemList(it: in Item): List[Item] {
  val l: List[Item] = newList()
  l.add(it)
  l
}

/// Each function specialised from another package's generic, its dot-named
/// calls rewritten into plain calls of the function as the declaring
/// package's check recorded them (`foreignMethodCallArities`): a method call
/// on a primitive receiver, one bound to an extension, and one passing a
/// place by reference (#8179, #8217, #8219).
pub func rewriteForeignDotCalls(file: in SourceFile, dotCalls: in Map[String, ByRefDotCall]): SourceFile {
  if dotCalls.count == 0 {
    return file
  }
  var changed = false
  val items: List[Item] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> {
        val origin = originPkgOf(fd.annotations)
        val sites: Map[String, ByRefDotCall] = newMap()
        if origin.length > 0 {
          val prefix = origin + "|"
          for k in mapKeys(dotCalls) {
            if Str.startsWith(k, prefix) {
              match mapGet(dotCalls, k) {
                case Some(site) -> sites.add(k.substring(prefix.length), site)
                case None -> ()
              }
            }
          }
        }
        if sites.count > 0 {
          changed = true
          val one = rewriteByRefDotCalls(oneItemFile(file, it), sites)
          items.add(one.items[0])
        } else {
          items.add(it)
        }
      }
      case _ -> items.add(it)
    }
  }
  if changed {
    file.copy(items = items)
  } else {
    file
  }
}

// The names of the dot-named functions a call of which is rewritten into a
// plain call of the function: one with an `out`/`inout` parameter (#8179),
// one of a primitive (#8217), and an extension, declared by a package that
// does not declare its type (#8219).
func dotCallRewriteMethodNames(file0: in SourceFile, importedPkgs: in List[ImportedPackage]): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  noteRewrittenDotNamed(file0.items, names)
  for ip in importedPkgs {
    noteRewrittenDotNamed(ip.items, names)
  }
  names
}

func noteRewrittenDotNamed(items: in List[Item], names: in Map[String, Bool]): Unit {
  val types: List[String] = newList()
  for it in items {
    match it.kind {
      case IRecord(d) -> types.add(d.name)
      case IExposedRec(d) -> types.add(d.name)
      case IUnion(d) -> types.add(d.name)
      case IEnum(d) -> types.add(d.name)
      case IOpaque(d) -> types.add(d.name)
      case IProtected(d) -> types.add(d.name)
      case IDistinctType(d) -> types.add(d.name)
      case _ -> ()
    }
  }
  for it in items {
    match it.kind {
      case IFunc(fn) -> {
        val dot = Str.lastIndexOfRaw(fn.name, ".")
        if dot > 0 {
          val owner = fn.name.substring(0, dot)
          val byRef = fnHasByRefParam(fn)
          if byRef or not types.contains(owner) {
            val m = fn.name.substring(dot + 1)
            if not names.containsKey(m) {
              names.add(m, true)
            }
          }
        }
      }
      case _ -> ()
    }
  }
}

func fnHasByRefParam(fn: in FunctionDecl): Bool {
  for p in fn.params {
    match p.mode {
      case PMInout -> return true
      case PMOut -> return true
      case _ -> ()
    }
  }
  false
}

// The names of the methods whose calls the backends dispatch by the type
// checker's resolution: one with a defaulted parameter (a call may leave it
// out) and one an owner declares more than once, counting a dot-named
// function `func T.m(...)` with `T`'s own `m`.
func dispatchSensitiveMethodNames(file0: in SourceFile, importedPkgs: in List[ImportedPackage]): Map[String, Bool] {
  val names: Map[String, Bool] = newMap()
  val perOwner: Map[String, Bool] = newMap()
  noteMethodItems(modulePathJoin(file0.packageDecl.path.segments) + "|", file0.items, names, perOwner)
  for ip in importedPkgs {
    noteMethodItems(ip.name + "|", ip.items, names, perOwner)
  }
  names
}

func noteMethodItems(
  pkg: in String, items: in List[Item], names: in Map[String, Bool], perOwner: in Map[String, Bool]
): Unit {
  for it in items {
    match it.kind {
      case IFunc(fn) -> {
        val dot = Str.lastIndexOfRaw(fn.name, ".")
        if dot > 0 {
          noteMethod(pkg + fn.name.substring(0, dot), fn.name.substring(dot + 1), fn.params, names, perOwner)
        }
      }
      case IRecord(decl) -> noteRecordMethods(pkg, decl, names, perOwner)
      case IExposedRec(decl) -> noteRecordMethods(pkg, decl, names, perOwner)
      case IInterface(decl) -> {
        for m in decl.members {
          match m {
            case IMSig(sig) -> noteMethod(pkg + decl.name, sig.name, sig.params, names, perOwner)
            case IMFunc(fn) -> noteMethod(pkg + decl.name, fn.name, fn.params, names, perOwner)
            case IMAssoc(_) -> ()
          }
        }
      }
      case IImpl(decl) -> {
        for m in decl.members {
          match m {
            case IMplFunc(fn) -> noteMethod("", fn.name, fn.params, names, perOwner)
            case IMplAssoc(_) -> ()
          }
        }
      }
      case _ -> ()
    }
  }
}

func noteRecordMethods(
  pkg: in String, decl: in RecordDecl, names: in Map[String, Bool], perOwner: in Map[String, Bool]
): Unit {
  for m in decl.members {
    match m {
      case RMFunc(fn) -> noteMethod(pkg + decl.name, fn.name, fn.params, names, perOwner)
      case _ -> ()
    }
  }
}

func noteMethod(
  owner: in String,
  name: in String,
  params: in List[Param],
  names: in Map[String, Bool],
  perOwner: in Map[String, Bool],
): Unit {
  for p in params {
    match p.dflt {
      case Some(_) -> {
        if not names.containsKey(name) {
          names.add(name, true)
        }
      }
      case None -> ()
    }
  }
  // Owners are counted per package and type: a record's own methods and the
  // dot-named functions of the type.  An impl method (`owner` "") is not
  // counted: it never shares a name with its type's own methods (T0139).
  if owner.length > 0 {
    val ownerKey = owner + "." + name
    if perOwner.containsKey(ownerKey) {
      if not names.containsKey(name) {
        names.add(name, true)
      }
    } else {
      perOwner.add(ownerKey, true)
    }
  }
}

// True when `decl`'s body calls a method named in `names`, as `x.m(...)` or
// as a bare call to a sibling method.
func specCallsAnyMethod(decl: in FunctionDecl, names: in Map[String, Bool]): Bool {
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noImports: List[ImportDecl] = newList()
  val items: List[Item] = newList()
  items.add(funcItem(decl))
  val f = SourceFile(
    moduleDoc = noDocs,
    files = newList(),
    fileAnnotations = noAnns,
    packageDecl = PackageDecl(path = ModulePath(segments = newList(), span = decl.span), span = decl.span),
    imports = noImports,
    items = items,
    span = decl.span
  )
  anyExprInFile(
    f,
    { e: Expr -> match e.kind { case ECall(callee, _) -> calleeMethodName(callee, names); case _ -> false } }
  )
}

func specUsesEquality(decl: in FunctionDecl): Bool {
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noImports: List[ImportDecl] = newList()
  val items: List[Item] = newList()
  items.add(funcItem(decl))
  val f = SourceFile(
    moduleDoc = noDocs,
    files = newList(),
    fileAnnotations = noAnns,
    packageDecl = PackageDecl(path = ModulePath(segments = newList(), span = decl.span), span = decl.span),
    imports = noImports,
    items = items,
    span = decl.span
  )
  anyExprInFile(
    f,
    { e: Expr ->
      match e.kind {
        case EBinop(op, _, _) -> match op { case BEq -> true; case BNeq -> true; case _ -> false }
        case _ -> false
      }
    }
  )
}

// True when `decl`'s body may stringify a value (D282): a specialisation that
// binds a type parameter to a record, collection or the like is checked again
// so the stringified operands of that type are rendered structurally.
func specMayRender(decl: in FunctionDecl): Bool {
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noImports: List[ImportDecl] = newList()
  val items: List[Item] = newList()
  items.add(funcItem(decl))
  val f = SourceFile(
    files = newList(),
    moduleDoc = noDocs,
    fileAnnotations = noAnns,
    packageDecl = PackageDecl(path = ModulePath(segments = newList(), span = decl.span), span = decl.span),
    imports = noImports,
    items = items,
    span = decl.span
  )
  anyExprInFile(f, { e: Expr -> mayRenderStructure(e) })
}

func calleeMethodName(callee: in Expr, names: in Map[String, Bool]): Bool {
  match callee.kind {
    case EParen(inner) -> calleeMethodName(inner, names)
    case ETypeApp(inner, _) -> calleeMethodName(inner, names)
    case EMember(_, name) -> names.containsKey(name)
    case EPath(path) -> path.segments.count == 1 and names.containsKey(path.segments[0])
    case _ -> false
  }
}

func recheckSpecRound(
  round: in List[UnsignedSpecRequest],
  origin: in String,
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  monoGenFuncs: in List[FunctionDecl],
  native: in Bool,
  diags: in List[Diagnostic],
  acc: in Map[String, Map[String, ArgConversionSite]],
  known: in Option[SymbolTable],
  arrAcc: in Map[String, SpecArraySites],
): Unit {
  val checkDecls: List[FunctionDecl] = newList()
  val items: List[Item] = newList()
  var imports: List[ImportDecl] = newList()
  var pkgDecl = file0.packageDecl
  val checkPkgs: List[ImportedPackage] = newList()
  if origin == "" {
    for it in file0.items {
      items.add(signatureOnlyItem(it))
    }
    imports = file0.imports
    for ip in importedPkgs {
      checkPkgs.add(ip)
    }
    for sp in round {
      checkDecls.add(
        match rawGenericDecl(file0.items, sp.specDecl.span) {
          case Some(raw) -> specializeFuncDecl(raw, sp.specName, sp.subst, sp.valueSubst)
          case None -> sp.specDecl
        }
      )
    }
  } else {
    if not addOriginScope(origin, file0, importedPkgs, monoGenFuncs, items, imports, checkPkgs) {
      for sp in round {
        diags.add(
          errorDiagnostic(
            "M0007",
            "cannot specialise '" + sp.specName + "': package '" + origin +
              "', which declares the generic, is not available to type-check the specialisation, so its operations on UInt/ULong values cannot be made unsigned",
            sp.callSpan
          )
        )
      }
      return
    }
    pkgDecl = PackageDecl(path = ModulePath(segments = dottedSegments(origin), span = file0.span), span = file0.span)
    addConsumerTypes(file0, items)
    for sp in round {
      checkDecls.add(sp.specDecl)
    }
  }
  for cd in checkDecls {
    items.add(funcItem(cd))
  }
  val checkFile = SourceFile(
    moduleDoc = file0.moduleDoc,
    files = file0.files,
    fileAnnotations = file0.fileAnnotations,
    packageDecl = pkgDecl,
    imports = imports,
    items = items,
    span = file0.span
  )
  val res = if native {
    checkWithImportedPackagesForNative(checkFile, checkPkgs)
  } else {
    checkWithImportedPackages(checkFile, checkPkgs)
  }
  var ri = 0
  while ri < round.count {
    val sp = round[ri]
    val cd = checkDecls[ri]
    val lo = bodySpanOffset(cd, true)
    val hi = bodySpanOffset(cd, false)
    var firstError = ""
    for d in res.diagnostics {
      if d.severity == DiagError and d.span.startPos.offset >= lo and d.span.endPos.offset <= hi and firstError == "" {
        firstError = d.code + " " + d.message
      }
    }
    if firstError != "" {
      diags.add(
        errorDiagnostic(
          "M0007",
          "cannot specialise '" + sp.specName + "': with its type arguments substituted the body does not type-check (" +
            firstError +
            "), so its operations on UInt/ULong, array or structured values cannot be lowered",
          sp.callSpan
        )
      )
    } else {
      val sites: Map[String, ArgConversionSite] = newMap()
      for k in mapKeys(res.symbols.argConversionSites) {
        match mapGet(res.symbols.argConversionSites, k) {
          case Some(site) -> if site.startOffset >= lo and site.startOffset < hi { sites.add(k, site) }
          case None -> ()
        }
      }
      acc.add(sp.specName, sites)
      // Only the generic's own file is lowered before monomorphisation, so
      // only there is a site the generic's check recorded already handled.
      val prior = if origin == "" { known } else { None }
      val sa = specArraySitesOf(
        res.symbols,
        prior,
        lo,
        hi,
        cd.span.startPos.offset,
        cd.span.endPos.offset,
        not isStdOrigin(origin)
      )
      if specArraySitesNonEmpty(sa) {
        arrAcc.add(sp.specName, sa)
      }
    }
    ri = ri + 1
  }
}

// The standard library's arithmetic always wraps (D163).
func isStdOrigin(origin: in String): Bool = origin == "Std" or Str.startsWith(origin, "Std.")

func specArraySitesNonEmpty(sa: in SpecArraySites): Bool {
  sa.arrays.index.count > 0 or sa.arrays.len.count > 0 or sa.arrays.slice.count > 0 or sa.arrays.forIter.count > 0 or
    sa.arrays.copy.count > 0 or
    sa.arrays.zero.count > 0 or
    sa.arrays.literal.count > 0 or
    sa.arrays.pointerClosures.count > 0 or
    sa.arrayEq.count > 0 or
    sa.recordEq.count > 0 or
    sa.wrapEq.count > 0 or
    sa.lens.count > 0 or
    sa.valueCtors.count > 0 or
    sa.valueUnionCtors.count > 0 or
    sa.distinctOps.count > 0 or
    sa.distinctCompound.count > 0 or
    sa.recordArith.count > 0 or
    sa.show.count > 0 or
    sa.overflow.count > 0
}

func specArraySitesOf(
  syms: in SymbolTable,
  prior: in Option[SymbolTable],
  lo: in Int,
  hi: in Int,
  fnLo: in Int,
  fnHi: in Int,
  withOverflow: in Bool,
): SpecArraySites {
  val none = newSymbolTable()
  val p = match prior { case Some(t) -> t; case None -> none }
  val usePrior = match prior { case Some(_) -> true; case None -> false }
  SpecArraySites(
    arrays = ArraySites(
      index = siteSlice(syms.arrayIndexSites, p.arrayIndexSites, usePrior, lo, hi),
      len = siteSlice(syms.arrayLenSites, p.arrayLenSites, usePrior, lo, hi),
      slice = siteSlice(syms.arraySliceSites, p.arraySliceSites, usePrior, lo, hi),
      forIter = siteSlice(syms.arrayForSites, p.arrayForSites, usePrior, lo, hi),
      copy = siteSlice(syms.arrayCopySites, p.arrayCopySites, usePrior, lo, hi),
      zero = siteSlice(syms.arrayZeroSites, p.arrayZeroSites, usePrior, lo, hi),
      ctorZero = siteSlice(syms.arrayCtorZeroArgs, p.arrayCtorZeroArgs, usePrior, lo, hi),
      literal = siteSlice(syms.arrayLiteralSites, p.arrayLiteralSites, usePrior, lo, hi),
      pointerClosures = siteSlice(syms.bufferPointerSites, p.bufferPointerSites, usePrior, lo, hi)
    ),
    arrayEq = siteSlice(syms.arrayEqSites, p.arrayEqSites, usePrior, lo, hi),
    recordEq = siteSlice(syms.recordEqSites, p.recordEqSites, usePrior, lo, hi),
    wrapEq = siteSlice(syms.wrapEqSites, p.wrapEqSites, usePrior, lo, hi),
    lens = siteSlice(syms.arrayTypeLens, p.arrayTypeLens, usePrior, fnLo, fnHi),
    valueCtors = siteSlice(syms.valueRecordCtorSites, p.valueRecordCtorSites, usePrior, lo, hi),
    valueUnionCtors = siteSlice(syms.valueUnionCtorSites, p.valueUnionCtorSites, usePrior, lo, hi),
    distinctOps = siteSlice(syms.distinctOpSites, p.distinctOpSites, usePrior, lo, hi),
    distinctCompound = siteSlice(syms.distinctCompoundSites, p.distinctCompoundSites, usePrior, lo, hi),
    recordArith = siteSlice(syms.recordArithSites, p.recordArithSites, usePrior, lo, hi),
    overflow = if withOverflow { siteSlice(syms.overflowSites, p.overflowSites, usePrior, lo, hi) } else { newMap() },
    overflowTemps = if withOverflow {
      siteSlice(syms.overflowCompoundTemps, p.overflowCompoundTemps, usePrior, lo, hi)
    } else {
      newMap()
    },
    show = siteSlice(syms.showSites, p.showSites, usePrior, lo, hi),
    showHelpers = syms.showHelpers
  )
}

// The entries of `m` whose span starts in `lo ..< hi`, less those `prior`
// holds when `usePrior`.
func siteSlice[V](
  m: in Map[String, V], prior: in Map[String, V], usePrior: in Bool, lo: in Int, hi: in Int
): Map[String, V] {
  val picked: Map[String, V] = newMap()
  for k in mapKeys(m) {
    val st = siteKeyStart(k)
    if st >= lo and st < hi and not (usePrior and prior.containsKey(k)) {
      match mapGet(m, k) {
        case Some(v) -> picked.add(k, v)
        case None -> ()
      }
    }
  }
  picked
}

// The start offset of a `recordCopySiteKey` (`"<start>:<end>"`).
func siteKeyStart(key: in String): Int {
  var n = 0
  var i = 0
  while i < key.length {
    val ch = Str.substring(key, i, 1)
    if ch == ":" {
      return n
    }
    match Str.indexOf("0123456789", ch) {
      case Some(d) -> {
        n = n * 10 + d
      }
      case None -> {
        return n
      }
    }
    i = i + 1
  }
  n
}

// `file` with each `array[N, T]` type expression whose length the checker
// resolved (`lens`, keyed by the type expression's span) written with that
// length as a literal, so a backend never resolves a name (D167).
func withArrayLens(file: in SourceFile, lens: in Map[String, Int]): SourceFile {
  if lens.count == 0 {
    return file
  }
  val marker: Map[String, TypeExpr] = newMap()
  for k in mapKeys(lens) {
    match mapGet(lens, k) {
      case Some(n) -> {
        val lit = Expr(kind = ELiteral(lit = LInt(value = n.toLong(), suffix = I32, raw = "")), span = file.span)
        marker.add(
          arrayLenMarkerPrefix() + k,
          TypeExpr(
            kind = TArray(size = TAValue(expr = lit), element = TypeExpr(kind = TUnit, span = file.span)),
            span = file.span
          )
        )
      }
      case None -> ()
    }
  }
  TypeAliasResolve.resolveAliasesInFile(marker, file)
}

// Lowers the array sites a specialisation recorded on that specialised
// function's body: each function is lowered on its own, because the
// specialisations of one generic share its source spans.
func lowerSpecArrays(
  file: in SourceFile,
  specArrays: in Map[String, SpecArraySites],
  primitiveArrays: in Bool,
  unionPerLength: in Bool,
  checkedArith: in Bool,
): SourceFile {
  if specArrays.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  val shownHelpers: Map[String, Bool] = newMap()
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> if Str.startsWith(fd.name, "__lyric_str_") { shownHelpers.add(fd.name, true) }
      case _ -> ()
    }
  }
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> match mapGet(specArrays, fd.name) {
        case Some(sa) -> {
          val one: List[Item] = newList()
          one.add(it)
          val oneFile = SourceFile(
            moduleDoc = file.moduleDoc,
            files = file.files,
            fileAnnotations = file.fileAnnotations,
            packageDecl = file.packageDecl,
            imports = file.imports,
            items = one,
            span = file.span
          )
          val arraySites = (if primitiveArrays { sa.arrays } else { sa.arrays.copy(literal = newMap()) }).copy(
            bufferHandles = not unionPerLength
          )
          val operatorsLowered = lowerRecordArith(
            lowerDistinctOps(oneFile, sa.distinctOps, sa.distinctCompound),
            sa.recordArith
          )
          val arraysDone = lowerArrays(
            lowerRecordEq(
              markValueUnionCtors(
                markValueRecordCtors(withArrayLens(operatorsLowered, sa.lens), sa.valueCtors),
                if unionPerLength { sa.valueUnionCtors } else { noUnionCtorSites() }
              ),
              sa.recordEq,
              sa.arrayEq,
              sa.wrapEq
            ),
            arraySites
          )
          val overflowDone = lowerOverflowChecks(arraysDone, sa.overflow, sa.overflowTemps, checkedArith)
          val lowered = lowerShowSpec(overflowDone, sa.show, sa.showHelpers, shownHelpers)
          for li in lowered.items {
            items.add(li)
          }
        }
        case None -> items.add(it)
      }
      case _ -> items.add(it)
    }
  }
  SourceFile(
    moduleDoc = file.moduleDoc,
    files = file.files,
    fileAnnotations = file.fileAnnotations,
    packageDecl = file.packageDecl,
    imports = file.imports,
    items = items,
    span = file.span
  )
}

// A generic call with a lambda argument is written with the type arguments
// the type checker inferred for it (`wrap[Int](41, { n: Int -> n + 1 })`).
// The native backend types a lambda from its parameter's function type under
// the type arguments the other arguments bind, so a type parameter only the
// lambda's own result determines would otherwise be uninferable.  Only a
// call whose every type argument is closed and unambiguous was recorded.
func spellLambdaGenericCallTypeArgs(file: in SourceFile, sites: in Map[String, GenericCallTypeArgsSite]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapExprsInFile(
    file,
    { e: Expr ->
      match e.kind {
        case ECall(fn, args) -> match fn.kind {
          case EPath(_) -> {
            var hasLambda = false
            for a in args {
              match a {
                case CAPositional(ex) -> if isLambdaArg(ex) { hasLambda = true }
                case CANamed(_, value, _) -> if isLambdaArg(value) { hasLambda = true }
              }
            }
            if not hasLambda {
              e
            } else {
              match mapGet(sites, recordCopySiteKey(fn.span)) {
                case Some(site) -> {
                  if site.conflicting or site.typeArgs.count == 0 {
                    e
                  } else {
                    val targs: List[TypeArg] = newList()
                    for te in site.typeArgs {
                      targs.add(TAType(ty = te))
                    }
                    Expr(kind = ECall(fn = Expr(kind = ETypeApp(fn = fn, args = targs), span = fn.span), args = args), span = e.span)
                  }
                }
                case None -> e
              }
            }
          }
          case _ -> e
        }
        case _ -> e
      }
    }
  )
}

func isLambdaArg(e: in Expr): Bool {
  match e.kind {
    case ELambda(_, _) -> true
    case EParen(inner) -> isLambdaArg(inner)
    case _ -> false
  }
}

// A call to a generic dot-named function written as a method call
// (`b.get()`) or through its type (`Box.get(b)`) becomes a plain call of the
// function (`Box.get(b)`, one path segment), which `Lyric.Mono` specialises
// like any generic call (#8173).  The callee keeps its span, under which the
// checker recorded the call's type and value arguments.
func rewriteDottedGenericCalls(file: in SourceFile, sites: in Map[String, DottedGenericCall]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapExprsInFile(
    file,
    { e: Expr ->
      match e.kind {
        case ECall(fn, args) -> match mapGet(sites, recordCopySiteKey(fn.span)) {
          case Some(site) -> {
            // Another package's function is called through that package
            // (#8179): `Lyric.Mono` specialises it from there, never a
            // same-named function of this package.
            val segs: List[String] = newList()
            if site.originPkg.length > 0 {
              for seg in dottedSegments(site.originPkg) {
                segs.add(seg)
              }
            }
            segs.add(site.name)
            val target = Expr(kind = EPath(path = ModulePath(segments = segs, span = fn.span)), span = fn.span)
            if site.receiverFirst {
              match fn.kind {
                case EMember(recv, _) -> {
                  val fullArgs: List[CallArg] = newList()
                  fullArgs.add(CAPositional(expr = recv))
                  for a in args {
                    fullArgs.add(a)
                  }
                  Expr(kind = ECall(fn = target, args = fullArgs), span = e.span)
                }
                case _ -> e
              }
            } else {
              Expr(kind = ECall(fn = target, args = args), span = e.span)
            }
          }
          case None -> e
        }
        case _ -> e
      }
    }
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Value-generic records (D169).
// ─────────────────────────────────────────────────────────────────────────────
// On a target with one union per length (native), each construction of a
// case of a union with value generic parameters, and each reference to a
// case with no fields, is spelled with its union and lengths before
// monomorphisation (`Shape.Poly[3](pts = a)`); `specialiseValueRecords` makes
// it a construction of the specialisation's case (`Shape__V3.Poly(pts = a)`),
// since every specialisation has the same case names (#8149).
func markValueUnionCtors(file: in SourceFile, sites: in Map[String, ValueUnionCtorSite]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapExprsInFile(
    file,
    { e: Expr ->
      match mapGet(sites, recordCopySiteKey(e.span)) {
        case Some(site) -> match e.kind {
          case ECall(fn, args) -> match valueUnionCaseRef(fn, site) {
            case Some(m) -> Expr(
              kind = ECall(fn = m, args = args),
              span = e.span
            )
            case None -> e
          }
          case EPath(_) -> match valueUnionCaseRef(e, site) { case Some(m) -> m; case None -> e }
          case EMember(_, _) -> match valueUnionCaseRef(e, site) { case Some(m) -> m; case None -> e }
          case _ -> e
        }
        case None -> e
      }
    }
  )
}

func valueUnionCaseRef(fn: in Expr, site: in ValueUnionCtorSite): Option[Expr] {
  val caseName = match fn.kind {
    case EPath(p) -> p.segments[p.segments.count - 1]
    case EMember(_, m) -> m
    case _ -> return None
  }
  val segs: List[String] = newList()
  segs.add(site.unionName)
  segs.add(caseName)
  val path = Expr(kind = EPath(path = ModulePath(segments = segs, span = fn.span)), span = fn.span)
  Some(value = Expr(kind = ETypeApp(fn = path, args = site.lengths), span = fn.span))
}

func noUnionCtorSites(): Map[String, ValueUnionCtorSite] {
  newMap()
}

// Before monomorphisation each construction of a value-generic record is
// spelled with its instance's lengths (`Ints[3](data = a)`, or `Ints[N]()`
// inside a value-generic body, which `Lyric.Mono` makes concrete in each
// specialisation).  After it, `specialiseValueRecords` gives each instance
// the program names its own record (`Ints__V3`), with the lengths
// substituted in its fields and methods, and renames every reference.
func markValueRecordCtors(file: in SourceFile, sites: in Map[String, List[TypeArg]]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapExprsInFile(
    file,
    { e: Expr ->
      match e.kind {
        case ECall(fn, args) -> match mapGet(sites, recordCopySiteKey(e.span)) {
          case Some(vargs) -> match fn.kind {
            case EPath(_) -> Expr(
              kind = ECall(
                fn = Expr(
                  kind = ETypeApp(
                    fn = fn,
                    args = vargs
                  ),
                  span = fn.span
                ),
                args = args
              ),
              span = e.span
            )
            case _ -> e
          }
          case None -> e
        }
        case _ -> e
      }
    }
  )
}

/// A record, exposed record, opaque type or union with value generic
/// parameters, as a record: an opaque type's fields and invariants are a
/// record's, a union's case fields are its fields in order, and
/// `recordItemLike` puts a specialised or erased one back as what it was
/// (#8149).
pub func valueGenericRecordDecl(it: in Item): Option[RecordDecl] {
  val dOpt = match it.kind {
    case IRecord(d) -> Some(value = d)
    case IExposedRec(d) -> Some(value = d)
    case IOpaque(od) -> if od.hasBody { Some(value = opaqueAsRecord(od)) } else { None }
    case IUnion(ud) -> Some(value = unionAsRecord(ud))
    case IProtected(pd) -> Some(value = protectedAsRecord(pd))
    case _ -> None
  }
  match dOpt {
    case Some(d) -> match d.generics {
      case Some(g) -> if genericParamsHaveValue(g.params) { Some(value = d) } else { None }
      case None -> None
    }
    case None -> None
  }
}

/// `valueGenericRecordDecl`, or only a protected type's when `protectedOnly`:
/// on a target that erases value parameters a protected type is still
/// specialised per length, as its members read the lengths by name (#8149).
func valueGenericDeclFor(it: in Item, protectedOnly: in Bool): Option[RecordDecl] {
  if protectedOnly {
    match it.kind {
      case IProtected(_) -> valueGenericRecordDecl(it)
      case _ -> None
    }
  } else {
    valueGenericRecordDecl(it)
  }
}

func valueRecordMarkers(items: in List[Item], constArgs: in Map[String, Int], sp: in Span): Map[String, TypeExpr] {
  val markers: Map[String, TypeExpr] = newMap()
  for it in items {
    match valueGenericRecordDecl(it) {
      case Some(d) -> match d.generics {
        case Some(g) -> {
          val kinds: List[TypeArg] = newList()
          for gp in g.params {
            match gp {
              case GPValue(_, _, gsp) -> kinds.add(TAValue(expr = Expr(kind = ELiteral(lit = LBool(value = true)), span = gsp)))
              case GPType(_, gsp) -> kinds.add(TAType(ty = TypeExpr(kind = TUnit, span = gsp)))
            }
          }
          val segs: List[String] = newList()
          segs.add(d.name)
          markers.add(
            valueRecordMarkerPrefix() + d.name,
            TypeExpr(kind = TGenericApp(head = ModulePath(segments = segs, span = d.span), args = kinds), span = d.span)
          )
        }
        case None -> ()
      }
      case None -> ()
    }
  }
  for k in mapKeys(constArgs) {
    match mapGet(constArgs, k) {
      case Some(n) -> markers.add(
        valueArgMarkerPrefix() + k,
        TypeExpr(
          kind = TArray(
            size = TAValue(
              expr = Expr(
                kind = ELiteral(
                  lit = LInt(value = n.toLong(), suffix = I32, raw = "")
                ),
                span = sp
              )
            ),
            element = TypeExpr(kind = TUnit, span = sp)
          ),
          span = sp
        )
      )
      case None -> ()
    }
  }
  markers
}

// One specialisation of a value-generic record: `spec` is `recordName` with
// its value parameters bound as in `valueSubst`.
record ValueRecordSpec {
  spec: String
  recordName: String
  valueSubst: Map[String, Expr]
}

// The specialisations `markers` recorded under `valueRecordUsePrefix()` that
// are not yet in `done`, with their value substitutions.
func newValueRecordSpecs(
  markers: in Map[String, TypeExpr], decls: in Map[String, RecordDecl], done: in List[String]
): List[ValueRecordSpec] {
  val specs: List[ValueRecordSpec] = newList()
  val prefix = valueRecordUsePrefix()
  for k in mapKeys(markers) {
    if k.startsWith(prefix) {
      val spec = k.substring(prefix.length, k.length - prefix.length)
      if not done.contains(spec) {
        match mapGet(markers, k) {
          case Some(useTe) -> match useTe.kind {
            case TGenericApp(head, largs) -> match mapGet(decls, head.segments[0]) {
              case Some(d) -> {
                val vs: Map[String, Expr] = newMap()
                var li = 0
                match d.generics {
                  case Some(g) -> {
                    for gp in g.params {
                      match gp {
                        case GPValue(nm, _, _) -> {
                          match largs[li] {
                            case TAValue(le) -> vs.add(nm, le)
                            case TAType(_) -> ()
                          }
                          li = li + 1
                        }
                        case GPType(_, _) -> ()
                      }
                    }
                  }
                  case None -> ()
                }
                specs.add(ValueRecordSpec(spec = spec, recordName = head.segments[0], valueSubst = vs))
              }
              case None -> ()
            }
            case _ -> ()
          }
          case None -> ()
        }
      }
    }
  }
  specs
}

// A record item with its methods as signatures, so checking a file that
// holds it records nothing inside them.
func recordSignatureOnly(it: in Item): Item {
  val decl = match it.kind {
    case IRecord(d) -> d
    case IExposedRec(d) -> d
    case IProtected(pd) -> protectedAsRecord(pd)
    case _ -> return it
  }
  val members: List[RecordMember] = newList()
  for m in decl.members {
    match m {
      case RMFunc(fn) -> members.add(RMFunc(fn = stripBody(fn)))
      case _ -> members.add(m)
    }
  }
  recordItemLike(it, decl.copy(members = members))
}

func oneItemFile(file: in SourceFile, it: in Item): SourceFile {
  val one: List[Item] = newList()
  one.add(it)
  file.copy(items = one)
}

func recordItemLike(it: in Item, d: in RecordDecl): Item {
  match it.kind {
    case IExposedRec(_) -> it.copy(kind = IExposedRec(decl = d), span = it.span)
    case IOpaque(od) -> it.copy(kind = IOpaque(decl = recordAsOpaque(od, d)), span = it.span)
    case IUnion(ud) -> it.copy(kind = IUnion(decl = recordAsUnion(ud, d)), span = it.span)
    case IProtected(pd) -> it.copy(kind = IProtected(decl = recordAsProtected(pd, d)), span = it.span)
    case _ -> it.copy(kind = IRecord(decl = d), span = it.span)
  }
}

// A union's case fields, in order, as a record's fields: specialising or
// erasing a union changes only its name, generic parameters and field types.
func unionAsRecord(ud: in UnionDecl): RecordDecl {
  val members: List[RecordMember] = newList()
  val noAnnotations: List[Annotation] = newList()
  val noDocs: List[DocComment] = newList()
  for c in ud.cases {
    var i = 0
    for f in c.fields {
      val ty = match f { case UFNamed(_, t, _) -> t; case UFPos(t, _) -> t }
      val sp = match f { case UFNamed(_, _, fsp) -> fsp; case UFPos(_, fsp) -> fsp }
      members.add(
        RMField(
          field = FieldDecl(
            docComments = noDocs,
            annotations = noAnnotations,
            visibility = None,
            isMutable = false,
            name = c.name + "." + toString(i),
            ty = ty,
            dflt = None,
            span = sp
          )
        )
      )
      i = i + 1
    }
  }
  RecordDecl(name = ud.name, generics = ud.generics, whereClause = ud.whereClause, members = members, span = ud.span)
}

// `like` with the name, generic parameters and field types of `d`, a record
// view of it (`unionAsRecord`) that has been specialised or erased.
func recordAsUnion(like: in UnionDecl, d: in RecordDecl): UnionDecl {
  val tys: List[TypeExpr] = newList()
  for m in d.members {
    match m {
      case RMField(f) -> tys.add(f.ty)
      case _ -> ()
    }
  }
  val cases: List[UnionCase] = newList()
  var k = 0
  for c in like.cases {
    val fields: List[UnionField] = newList()
    for f in c.fields {
      fields.add(
        match f {
          case UFNamed(nm, _, fsp) -> UFNamed(name = nm, ty = tys[k], span = fsp)
          case UFPos(_, fsp) -> UFPos(ty = tys[k], span = fsp)
        }
      )
      k = k + 1
    }
    cases.add(c.copy(fields = fields))
  }
  like.copy(name = d.name, generics = d.generics, whereClause = d.whereClause, cases = cases)
}

// A protected type as a record, so the value-generic record passes specialise
// it (#8149): its fields are the record's, its invariants too, and each entry
// or func is a method of the record (an entry is told by a marker annotation
// so `recordAsProtected` can put it back).  A protected type's members keep
// their bare field names and their lock, so unlike a record's methods they
// are not hoisted: the type is specialised whole, per length, on every
// target.
func protectedMarker(name: in String, sp: in Span): Annotation {
  val segs: List[String] = newList()
  segs.add(name)
  val noArgs: List[AnnotationArg] = newList()
  Annotation(name = ModulePath(segments = segs, span = sp), args = noArgs, span = sp)
}

func protectedAsRecord(pd: in ProtectedTypeDecl): RecordDecl {
  val members: List[RecordMember] = newList()
  for m in pd.members {
    match m {
      case PMField(pf) -> match pf {
        case PFVar(name, ty, init, docs, anns, sp) -> {
          val tagged: List[Annotation] = newList()
          for a in anns {
            tagged.add(a)
          }
          tagged.add(protectedMarker("__pf_var", sp))
          members.add(
            RMField(
              field = FieldDecl(
                docComments = docs,
                annotations = tagged,
                visibility = None,
                isMutable = true,
                name = name,
                ty = ty,
                dflt = init,
                span = sp
              )
            )
          )
        }
        case PFLet(name, ty, init, docs, anns, sp) -> {
          val tagged: List[Annotation] = newList()
          for a in anns {
            tagged.add(a)
          }
          tagged.add(protectedMarker("__pf_let", sp))
          members.add(
            RMField(
              field = FieldDecl(
                docComments = docs,
                annotations = tagged,
                visibility = None,
                isMutable = false,
                name = name,
                ty = ty,
                dflt = init,
                span = sp
              )
            )
          )
        }
        case PFImmutable(fd) -> members.add(RMField(field = fd))
      }
      case PMInvariant(inv) -> members.add(RMInvariant(inv = inv))
      case PMEntry(ed) -> {
        val tagged: List[Annotation] = newList()
        for a in ed.annotations {
          tagged.add(a)
        }
        tagged.add(protectedMarker("__pm_entry", ed.span))
        members.add(
          RMFunc(
            fn = FunctionDecl(
              docComments = ed.docComments,
              annotations = tagged,
              visibility = ed.visibility,
              isAsync = false,
              name = ed.name,
              generics = None,
              params = ed.params,
              ret = ed.ret,
              whereClause = None,
              contracts = ed.contracts,
              body = Some(value = ed.body),
              span = ed.span
            )
          )
        )
      }
      case PMFunc(fn) -> members.add(RMFunc(fn = fn))
    }
  }
  RecordDecl(
    name = pd.name,
    generics = pd.generics,
    whereClause = pd.whereClause,
    members = members,
    span = pd.span,
    isRef = true
  )
}

func annotationsWithout(anns: in List[Annotation], name: in String): List[Annotation] {
  val kept: List[Annotation] = newList()
  for a in anns {
    if not (a.name.segments.count == 1 and a.name.segments[0] == name) {
      kept.add(a)
    }
  }
  kept
}

func hasAnnotationNamedPipe(anns: in List[Annotation], name: in String): Bool {
  for a in anns {
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return true
    }
  }
  false
}

// The body given an entry that has none, in the signature-only copy of a
// specialisation (`recordSignatureOnly`): `panic("")` type-checks against any
// return type and records no array operation.
func signatureOnlyEntryBody(sp: in Span): FunctionBody {
  val segs: List[String] = newList()
  segs.add("panic")
  val msg = Expr(kind = ELiteral(lit = LString(text = "")), span = sp)
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = msg))
  val call = Expr(
    kind = ECall(
      fn = Expr(kind = EPath(path = ModulePath(segments = segs, span = sp)), span = sp),
      args = args
    ),
    span = sp
  )
  val stmts: List[Statement] = newList()
  stmts.add(Statement(kind = SExpr(expr = call), span = sp))
  FBBlock(block = Block(statements = stmts, span = sp))
}

// `like` with the name, generic parameters and members of `d`, a record view
// of it (`protectedAsRecord`) that has been specialised.
func recordAsProtected(like: in ProtectedTypeDecl, d: in RecordDecl): ProtectedTypeDecl {
  val members: List[ProtectedMember] = newList()
  for m in d.members {
    match m {
      case RMField(fd) -> {
        if hasAnnotationNamedPipe(fd.annotations, "__pf_var") {
          members.add(
            PMField(
              field = PFVar(
                name = fd.name,
                ty = fd.ty,
                init = fd.dflt,
                docComments = fd.docComments,
                annotations = annotationsWithout(fd.annotations, "__pf_var"),
                span = fd.span
              )
            )
          )
        } else if hasAnnotationNamedPipe(fd.annotations, "__pf_let") {
          members.add(
            PMField(
              field = PFLet(
                name = fd.name,
                ty = fd.ty,
                init = fd.dflt,
                docComments = fd.docComments,
                annotations = annotationsWithout(fd.annotations, "__pf_let"),
                span = fd.span
              )
            )
          )
        } else {
          members.add(PMField(field = PFImmutable(field = fd)))
        }
      }
      case RMInvariant(inv) -> members.add(PMInvariant(inv = inv))
      case RMFunc(fn) -> {
        if hasAnnotationNamedPipe(fn.annotations, "__pm_entry") {
          val body = match fn.body { case Some(b) -> b; case None -> signatureOnlyEntryBody(fn.span) }
          members.add(
            PMEntry(
              entryDecl = EntryDecl(
                docComments = fn.docComments,
                annotations = annotationsWithout(fn.annotations, "__pm_entry"),
                visibility = fn.visibility,
                name = fn.name,
                params = fn.params,
                ret = fn.ret,
                contracts = fn.contracts,
                body = body,
                span = fn.span
              )
            )
          )
        } else {
          members.add(PMFunc(fn = fn))
        }
      }
    }
  }
  like.copy(name = d.name, generics = d.generics, whereClause = d.whereClause, members = members)
}

func opaqueAsRecord(od: in OpaqueTypeDecl): RecordDecl {
  val members: List[RecordMember] = newList()
  for m in od.members {
    match m {
      case OMField(f) -> members.add(RMField(field = f))
      case OMInvariant(inv) -> members.add(RMInvariant(inv = inv))
    }
  }
  RecordDecl(name = od.name, generics = od.generics, whereClause = od.whereClause, members = members, span = od.span)
}

// `like` with the name, generic parameters and members of `d`, a record view
// of it that has been specialised or erased.
func recordAsOpaque(like: in OpaqueTypeDecl, d: in RecordDecl): OpaqueTypeDecl {
  val members: List[OpaqueMember] = newList()
  for m in d.members {
    match m {
      case RMField(f) -> members.add(OMField(field = f))
      case RMInvariant(inv) -> members.add(OMInvariant(inv = inv))
      case RMFunc(_) -> ()
    }
  }
  like.copy(name = d.name, generics = d.generics, whereClause = d.whereClause, members = members)
}

// Every specialisation of the value-generic records in `file` (D169),
// replacing each record with its specialisations and every reference to an
// instance with a reference to its specialisation.  `specsOut` receives the
// specialisations made.
func specialiseValueRecords(
  file: in SourceFile,
  constArgs: in Map[String, Int],
  specsOut: in List[ValueRecordSpec],
  importedPkgs: in List[ImportedPackage],
  foreignOut: in List[ForeignValueRecord],
  protectedOnly: in Bool,
): SourceFile {
  val decls: Map[String, RecordDecl] = newMap()
  val declItems: Map[String, Item] = newMap()
  val markerItems: List[Item] = newList()
  for it in file.items {
    match valueGenericDeclFor(it, protectedOnly) {
      case Some(d) -> {
        decls.add(d.name, d)
        declItems.add(d.name, it)
        markerItems.add(it)
      }
      case None -> ()
    }
  }
  // Another package's records, by the package that declares them; the pool
  // also holds this package's own items, which are already above.
  val foreignPkg: Map[String, String] = newMap()
  val ownPkg = modulePathJoin(file.packageDecl.path.segments)
  for ip in importedPkgs {
    if ip.name != ownPkg {
      for it in ip.items {
        match valueGenericDeclFor(it, protectedOnly) {
          case Some(d) -> if not decls.containsKey(d.name) {
            decls.add(d.name, d)
            declItems.add(d.name, it)
            markerItems.add(it)
            foreignPkg.add(d.name, ip.name)
          }
          case None -> ()
        }
      }
    }
  }
  if decls.count == 0 {
    return file
  }
  val markers = valueRecordMarkers(markerItems, constArgs, file.span)
  val renamed = TypeAliasResolve.resolveAliasesInFile(markers, file)
  // A specialisation's fields and methods may name further instances, so
  // specialise until no new one appears.
  val done: List[String] = newList()
  val specItems: Map[String, List[Item]] = newMap()
  var pending = newValueRecordSpecs(markers, decls, done)
  while pending.count > 0 {
    for vs in pending {
      done.add(vs.spec)
      specsOut.add(vs)
      match mapGet(decls, vs.recordName) {
        case Some(d) -> match mapGet(declItems, vs.recordName) {
          case Some(srcItem) -> {
            val sd = specializeRecordValues(d, vs.spec, vs.valueSubst)
            val specFile = TypeAliasResolve.resolveAliasesInFile(markers, oneItemFile(file, recordItemLike(srcItem, sd)))
            if not specItems.containsKey(vs.recordName) {
              val fresh: List[Item] = newList()
              specItems.add(vs.recordName, fresh)
            }
            for si in specFile.items {
              specItems[vs.recordName].add(si)
            }
          }
          case None -> ()
        }
        case None -> ()
      }
    }
    pending = newValueRecordSpecs(markers, decls, done)
  }
  // Another package's specialisations belong to that package (D173 item 3).
  for name in mapKeys(foreignPkg) {
    match mapGet(foreignPkg, name) {
      case Some(pkg) -> match mapGet(specItems, name) {
        case Some(sis) -> {
          for si in sis {
            foreignOut.add(ForeignValueRecord(pkg = pkg, item = si))
          }
        }
        case None -> ()
      }
      case None -> ()
    }
  }
  // Each record is replaced, in place, by its specialisations.
  val items: List[Item] = newList()
  for it in renamed.items {
    match valueGenericDeclFor(it, protectedOnly) {
      case Some(d) -> match mapGet(specItems, d.name) {
        case Some(sis) -> {
          for si in sis {
            items.add(si)
          }
        }
        case None -> ()
      }
      case None -> items.add(it)
    }
  }
  renamed.copy(items = items)
}

// Lowers the array operations in each specialised record's methods (D169).
// A method of a value-generic record is checked once with its lengths
// symbolic, which records no array operation; each specialisation is
// checked again from the record's source with its lengths bound, as a
// value-generic function's specialisation is (`recheckSpecRound`), and its
// operations are lowered in the monomorphised record.
func lowerValueRecordSpecs(
  file: in SourceFile,
  file0: in SourceFile,
  specs: in List[ValueRecordSpec],
  constArgs: in Map[String, Int],
  importedPkgs: in List[ImportedPackage],
  known: in SymbolTable,
  opts: in MiddleEndOptions,
  diags: in List[Diagnostic],
  protectedOnly: in Bool,
): SourceFile {
  if specs.count == 0 {
    return file
  }
  val rawDecls: Map[String, Item] = newMap()
  for it in file0.items {
    match valueGenericRecordDecl(it) {
      case Some(d) -> rawDecls.add(d.name, it)
      case None -> ()
    }
  }
  val markedItems: List[Item] = newList()
  for it in file0.items {
    match valueGenericDeclFor(it, protectedOnly) {
      case Some(_) -> markedItems.add(it)
      case None -> ()
    }
  }
  val markers = valueRecordMarkers(markedItems, constArgs, file0.span)
  // Every specialisation, from the records' source, in full and as
  // signatures: a round checks some with their method bodies while the
  // others, which they may name, are signatures.
  val rawSpecItems: Map[String, Item] = newMap()
  for vs in specs {
    match mapGet(rawDecls, vs.recordName) {
      case Some(rawItem) -> match valueGenericRecordDecl(rawItem) {
        case Some(rawDecl) -> {
          val rawSpec = specializeRecordValues(rawDecl, vs.spec, vs.valueSubst)
          rawSpecItems.add(
            vs.spec,
            TypeAliasResolve.resolveAliasesInFile(markers, oneItemFile(file0, recordItemLike(rawItem, rawSpec))).items[0]
          )
        }
        case None -> ()
      }
      case None -> ()
    }
  }
  // One check per round: a round holds at most one specialisation of each
  // record, since those share the record's source spans, so every round
  // attributes each diagnostic and array site to one specialisation.  The
  // file's own items are signatures in every round, built once.
  val baseItems: List[Item] = newList()
  for it in file0.items {
    baseItems.add(signatureOnlyItem(it))
  }
  val sigSpecItems: Map[String, Item] = newMap()
  for k in mapKeys(rawSpecItems) {
    match mapGet(rawSpecItems, k) {
      case Some(it) -> sigSpecItems.add(k, recordSignatureOnly(it))
      case None -> ()
    }
  }
  val specArrays: Map[String, SpecArraySites] = newMap()
  var pending: List[ValueRecordSpec] = newList()
  for vs in specs {
    if rawSpecItems.containsKey(vs.spec) {
      pending.add(vs)
    }
  }
  while pending.count > 0 {
    val round: List[ValueRecordSpec] = newList()
    val rest: List[ValueRecordSpec] = newList()
    val roundRecords: List[String] = newList()
    for vs in pending {
      if roundRecords.contains(vs.recordName) {
        rest.add(vs)
      } else {
        round.add(vs)
        roundRecords.add(vs.recordName)
      }
    }
    pending = rest
    val roundSpecs: List[String] = newList()
    for vs in round {
      roundSpecs.add(vs.spec)
    }
    val items: List[Item] = newList()
    for it in baseItems {
      items.add(it)
    }
    for vs in specs {
      val src = if roundSpecs.contains(vs.spec) { rawSpecItems } else { sigSpecItems }
      match mapGet(src, vs.spec) {
        case Some(it) -> items.add(it)
        case None -> ()
      }
    }
    val checkFile = file0.copy(items = items)
    val res = if opts.nativeIntrinsics {
      checkWithImportedPackagesForNative(checkFile, importedPkgs)
    } else {
      checkWithImportedPackages(checkFile, importedPkgs)
    }
    for vs in round {
      match mapGet(rawSpecItems, vs.spec) {
        case Some(rawSpecItem) -> {
          val lo = rawSpecItem.span.startPos.offset
          val hi = rawSpecItem.span.endPos.offset
          var firstError = ""
          for d in res.diagnostics {
            if d.severity == DiagError and d.span.startPos.offset >= lo and d.span.endPos.offset <= hi and firstError == "" {
              firstError = d.code + " " + d.message
            }
          }
          if firstError != "" {
            diags.add(
              errorDiagnostic(
                "M0007",
                "cannot specialise '" + vs.recordName + "' as '" + vs.spec +
                  "': with its lengths substituted its methods do not type-check (" +
                  firstError +
                  ")",
                rawSpecItem.span
              )
            )
          } else {
            val sa = specArraySitesOf(res.symbols, Some(value = known), lo, hi, lo, hi, false)
            if specArraySitesNonEmpty(sa) {
              specArrays.add(vs.spec, sa)
            }
          }
        }
        case None -> ()
      }
    }
  }
  if specArrays.count == 0 {
    return file
  }
  val items: List[Item] = newList()
  for it in file.items {
    val name = match it.kind {
      case IRecord(d) -> d.name
      case IExposedRec(d) -> d.name
      case IProtected(d) -> d.name
      case _ -> ""
    }
    match mapGet(specArrays, name) {
      case Some(sa) -> {
        val arraySites = (if opts.primitiveArrays { sa.arrays } else { sa.arrays.copy(literal = newMap()) }).copy(
          bufferHandles = opts.arraysAsLists
        )
        val lowered = lowerArrays(
          lowerRecordEq(withArrayLens(oneItemFile(file, it), sa.lens), sa.recordEq, sa.arrayEq, sa.wrapEq),
          arraySites
        )
        for li in lowered.items {
          items.add(li)
        }
      }
      case None -> items.add(it)
    }
  }
  file.copy(items = items)
}

// On a target whose `array[N, T]` carries no length (dotnet and the JVM),
// a value-generic record or union is one runtime type with its value
// parameters erased (D173 item 1, #8149): the type declared here loses them,
// and every instance of it or of one imported, `Ints[3]` or `FixedVec[T, 3]`,
// names the erased type.  Its methods are already value-generic functions
// specialised per length (`hoistValueRecordMethods`).
func eraseValueRecords(file: in SourceFile, importedPkgs: in List[ImportedPackage]): SourceFile {
  // The pool of imported packages also holds this package's own items.
  val decls: List[Item] = newList()
  val names: Map[String, Bool] = newMap()
  for it in file.items {
    addValueRecordOnce(it, decls, names)
  }
  for ip in importedPkgs {
    for it in ip.items {
      addValueRecordOnce(it, decls, names)
    }
  }
  if decls.count == 0 {
    return file
  }
  val noConstArgs: Map[String, Int] = newMap()
  val markers = valueRecordMarkers(decls, noConstArgs, file.span)
  markers.add(valueRecordEraseKey(), TypeExpr(kind = TUnit, span = file.span))
  val renamed = TypeAliasResolve.resolveAliasesInFile(markers, file)
  val items: List[Item] = newList()
  for it in renamed.items {
    match it.kind {
      case IProtected(_) -> items.add(it)
      case _ -> match valueGenericRecordDecl(it) {
        case Some(d) -> items.add(recordItemLike(it, d.copy(generics = withoutValueGenerics(d.generics))))
        case None -> items.add(it)
      }
    }
  }
  renamed.copy(items = items)
}

func addValueRecordOnce(it: in Item, decls: in List[Item], names: in Map[String, Bool]): Unit {
  match it.kind {
    case IProtected(_) -> ()
    case _ -> match valueGenericRecordDecl(it) {
      case Some(d) -> if not names.containsKey(d.name) { names.add(d.name, true); decls.add(it) }
      case None -> ()
    }
  }
}

func withoutValueGenerics(g: in Option[GenericParams]): Option[GenericParams] {
  match g {
    case Some(gp) -> {
      val kept: List[GenericParam] = newList()
      for p in gp.params {
        match p {
          case GPType(_, _) -> kept.add(p)
          case GPValue(_, _, _) -> ()
        }
      }
      if kept.count == 0 {
        None
      } else {
        Some(value = gp.copy(params = kept))
      }
    }
    case None -> None
  }
}

// Specialises the value-generic records in the monomorphised `file` and
// lowers the array operations in their methods (D169).  `None` when a
// specialisation does not type-check.
func finishValueRecords(
  file: in SourceFile,
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  tcRes: in CheckResult,
  opts: in MiddleEndOptions,
): Option[SourceFile] {
  // A target that erases value parameters still specialises a protected type
  // per length (#8149), after the records are erased.
  val protectedOnly = opts.arraysAsLists
  val base = if protectedOnly { eraseValueRecords(file, importedPkgs) } else { file }
  val specs: List[ValueRecordSpec] = newList()
  val specialised = specialiseValueRecords(
    base,
    tcRes.symbols.valueTypeArgSites,
    specs,
    importedPkgs,
    opts.foreignValueRecordsOut,
    protectedOnly
  )
  val diags: List[Diagnostic] = newList()
  val lowered = lowerValueRecordSpecs(
    specialised,
    file0,
    specs,
    tcRes.symbols.valueTypeArgSites,
    importedPkgs,
    tcRes.symbols,
    opts,
    diags,
    protectedOnly
  )
  if gate(opts.pkgLabel, opts.filePaths, diags) {
    return None
  }
  Some(value = lowered)
}

func intListContainsPipe(xs: in List[Int], v: in Int): Bool {
  for x in xs {
    if x == v {
      return true
    }
  }
  false
}

// Where a function's body starts (`start`) or ends in its source; 0 for none.
func bodySpanOffset(fd: in FunctionDecl, start: in Bool): Int {
  match fd.body {
    case Some(b) -> match b {
      case FBBlock(blk) -> if start { blk.span.startPos.offset } else { blk.span.endPos.offset }
      case FBExpr(e) -> if start { e.span.startPos.offset } else { e.span.endPos.offset }
    }
    case None -> 0
  }
}

// The top-level generic function in `items` declared at `sp`.
func rawGenericDecl(items: in List[Item], sp: in Span): Option[FunctionDecl] {
  for it in items {
    match it.kind {
      case IFunc(fd) -> if fd.span.startPos.offset == sp.startPos.offset and fd.span.endPos.offset == sp.endPos.offset {
        match fd.generics {
          case Some(_) -> return Some(value = fd)
          case None -> ()
        }
      }
      case _ -> ()
    }
  }
  None
}

// ─── Unsigned operands in other packages' generics (#8019) ──────────────────
// True when the body or signature of `decl` spells `UInt`/`ULong`: a type
// annotation, a suffixed literal, a conversion method or a type argument.
func specMentionsUnsigned(decl: in FunctionDecl): Bool {
  for prm in decl.params {
    if typeExprMentionsUnsigned(prm.ty) {
      return true
    }
  }
  match decl.ret {
    case Some(rt) -> if typeExprMentionsUnsigned(rt) { return true }
    case None -> ()
  }
  val items: List[Item] = newList()
  items.add(funcItem(decl))
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  val noImports: List[ImportDecl] = newList()
  val f = SourceFile(
    files = newList(),
    moduleDoc = noDocs,
    fileAnnotations = noAnns,
    packageDecl = PackageDecl(path = ModulePath(segments = newList(), span = decl.span), span = decl.span),
    imports = noImports,
    items = items,
    span = decl.span
  )
  var typed = false
  mapStmtsInFile(
    f,
    { s: Statement ->
      match s.kind {
        case SLocal(b) -> match b {
          case LBVal(_, Some(t), _) -> if typeExprMentionsUnsigned(t) { typed = true }
          case LBVar(_, Some(t), _) -> if typeExprMentionsUnsigned(t) { typed = true }
          case LBLet(_, Some(t), _) -> if typeExprMentionsUnsigned(t) { typed = true }
          case _ -> ()
        }
        case _ -> ()
      }
      s
    }
  )
  if typed {
    return true
  }
  anyExprInFile(
    f,
    { e: Expr ->
      match e.kind {
        case ELiteral(lit) -> match lit {
          case LInt(_, sfx, _) -> match sfx { case U32 -> true; case U64 -> true; case _ -> false }
          case _ -> false
        }
        case EMember(_, name) -> name == "toUInt" or name == "toULong"
        case ETypeApp(_, targs) -> typeArgsMentionUnsigned(targs)
        case ELambda(lps, _) -> lambdaParamsMentionUnsigned(lps)
        case EPath(path) -> path.segments.count > 1 and (path.segments[0] == "UInt" or path.segments[0] == "ULong")
        case _ -> false
      }
    }
  )
}

func typeArgsMentionUnsigned(targs: in List[TypeArg]): Bool {
  for ta in targs {
    match ta {
      case TAType(t) -> if typeExprMentionsUnsigned(t) { return true }
      case TAValue(_) -> ()
    }
  }
  false
}

func lambdaParamsMentionUnsigned(lps: in List[LambdaParam]): Bool {
  for lp in lps {
    match lp.ty {
      case Some(t) -> if typeExprMentionsUnsigned(t) { return true }
      case None -> ()
    }
  }
  false
}

func typeExprMentionsUnsigned(te: in TypeExpr): Bool = teMentionsUnsignedMono(te)

// ─── The caller's types in another package's scope (#8530) ──────────────────
// Adds to `items`, the scope of the package declaring a generic, the types
// `file0` declares (as signatures) that the package does not already declare,
// so a specialisation bound to one of them type-checks there.
func addConsumerTypes(file0: in SourceFile, items: in List[Item]): Unit {
  val declared: Map[String, Bool] = newMap()
  for it in items {
    match typeItemName(it) {
      case Some(n) -> declared.add(n, true)
      case None -> ()
    }
  }
  for it in file0.items {
    match typeItemName(it) {
      case Some(n) -> if not declared.containsKey(n) { declared.add(n, true); items.add(it) }
      case None -> ()
    }
  }
}

func typeItemName(it: in Item): Option[String] {
  match it.kind {
    case ITypeAlias(d) -> Some(value = d.name)
    case IDistinctType(d) -> Some(value = d.name)
    case IRecord(d) -> Some(value = d.name)
    case IExposedRec(d) -> Some(value = d.name)
    case IUnion(d) -> Some(value = d.name)
    case IEnum(d) -> Some(value = d.name)
    case _ -> None
  }
}

func itemsDeclareFunc(items: in List[Item], fd: in FunctionDecl): Bool {
  for it in items {
    match it.kind {
      case IFunc(d) -> if d.name == fd.name and d.span.startPos.offset == fd.span.startPos.offset { return true }
      case _ -> ()
    }
  }
  false
}

func funcItem(fd: in FunctionDecl): Item {
  val noDocs: List[DocComment] = newList()
  val noAnns: List[Annotation] = newList()
  Item(docComments = noDocs, annotations = noAnns, visibility = fd.visibility, kind = IFunc(decl = fd), span = fd.span)
}

// `fd` as a signature: no body, and `@axiom`, which the type checker
// accepts without one.
func stripBody(fd: in FunctionDecl): FunctionDecl {
  val anns: List[Annotation] = newList()
  for a in fd.annotations {
    anns.add(a)
  }
  val noArgs: List[AnnotationArg] = newList()
  val axiomSegs: List[String] = newList()
  axiomSegs.add("axiom")
  anns.add(Annotation(name = ModulePath(segments = axiomSegs, span = fd.span), args = noArgs, span = fd.span))
  FunctionDecl(
    docComments = fd.docComments,
    annotations = anns,
    visibility = fd.visibility,
    isAsync = fd.isAsync,
    name = fd.name,
    generics = fd.generics,
    params = fd.params,
    ret = fd.ret,
    whereClause = fd.whereClause,
    contracts = fd.contracts,
    body = None,
    span = fd.span
  )
}

// `it` with its function bodies removed: a scope for checking one
// specialisation needs the signatures only.
func signatureOnlyItem(it: in Item): Item {
  match it.kind {
    case IFunc(fd) -> Item(
      docComments = it.docComments,
      annotations = it.annotations,
      visibility = it.visibility,
      kind = IFunc(decl = stripBody(fd)),
      span = it.span
    )
    case IImpl(decl) -> {
      val members: List[ImplMember] = newList()
      for m in decl.members {
        match m {
          case IMplFunc(fd) -> members.add(IMplFunc(fn = stripBody(fd)))
          case IMplAssoc(a) -> members.add(IMplAssoc(assoc = a))
        }
      }
      Item(
        docComments = it.docComments,
        annotations = it.annotations,
        visibility = it.visibility,
        kind = IImpl(
          decl = ImplDecl(
            generics = decl.generics,
            iface = decl.iface,
            target = decl.target,
            whereClause = decl.whereClause,
            members = members,
            span = decl.span
          )
        ),
        span = it.span
      )
    }
    case _ -> it
  }
}

func dottedSegments(name: in String): List[String] {
  val segs: List[String] = newList()
  var start = 0
  var i = 0
  while i < name.length {
    if name.substring(i, 1) == "." {
      segs.add(name.substring(start, i - start))
      start = i + 1
    }
    i = i + 1
  }
  if start < name.length {
    segs.add(name.substring(start))
  }
  segs
}

func wholeImportDecl(name: in String, sp: in Span): ImportDecl {
  ImportDecl(
    path = ModulePath(segments = dottedSegments(name), span = sp),
    selector = None,
    asAlias = None,
    isPubUse = false,
    isExtern = false,
    span = sp
  )
}

// `-<unsuffixed or signed-suffixed integer literal>` becomes one negative
// literal (#7346, #7847).  The type checker types `-2147483648` as `Int`,
// but its operand alone is too large for `Int`, and every backend sized the
// negation by the operand: the JVM pushed a long into an int slot
// (VerifyError) and MSIL emitted a long.  A signed suffix's minimum
// (`-2147483648i32`, `-128i8`) is the same shape.  A single literal lets
// each backend size the constant by its real value.  `Long.MinValue`'s
// magnitude is carried as its own pattern, so it negates to itself.  Runs
// after elaboration and mono, so contract asserts and specialised bodies are
// covered.
func foldNegatedIntLiteral(e: in Expr): Expr {
  match e.kind {
    case EPrefix(op, operand) -> match op {
      // The checker looks through parentheses under a negation
      // (`-(2147483648)` is an `Int`), so the fold does too (#7397).
      case PreNeg -> match stripExprParens(operand).kind {
        case ELiteral(lit) -> match lit {
          case LInt(v, sfx, raw) -> if isSignedIntSuffix(sfx) {
            Expr(
              kind = ELiteral(
                lit = LInt(value = if v == -9223372036854775808i64 { v } else { 0i64 - v }, suffix = sfx, raw = "-" + raw)
              ),
              span = e.span
            )
          } else {
            e
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

// An unsuffixed literal or one of the signed suffixes; unsigned literals
// are never folded under a negation.
func isSignedIntSuffix(sfx: in IntSuffix): Bool {
  match sfx {
    case NoIntSuffix -> true
    case I8 -> true
    case I16 -> true
    case I32 -> true
    case I64 -> true
    case _ -> false
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
///
/// `typeArgCallees` is the type checker's `typeArgCalleeSites` for `file`
/// (`MiddleEndOptions.typeArgCalleesOut`): callees under explicit type
/// arguments, which the await hoist leaves in their calls (#8279).
pub func pipeWeave(
  file: in SourceFile,
  templates: in Map[String, Weaver.CollectedTemplate],
  typeIndex: in Weaver.TypeOwnerIndex,
  pkgLabel: in String,
  files: in List[String],
  extraRecordDecls: in List[RecordDecl],
  typeArgCallees: in Map[String, Bool],
  contractsEnabled: in Bool = true,
  wovenGenerics: in List[FunctionDecl] = newList(),
): Option[SourceFile] {
  // @proof_required modules always enable contracts: proof obligations must not be user-disableable (#7732)
  val effectiveContractsEnabled = if ContractElaborator.isProofRequired(file.fileAnnotations) {
    true
  } else {
    contractsEnabled
  }
  val weaveRes = Weaver.weaveFileWithDiagsAndTemplates(file, templates, typeIndex, effectiveContractsEnabled)
  if gate(pkgLabel, files, weaveRes.diagnostics) {
    return None
  }
  // After weaving, so advice spliced in from another package is lowered too;
  // before the await hoist, which must see the tree codegen sees.
  val formatted = mapExprsInFile(weaveRes.file, lowerFormatBuiltin)
  val specialised = match specialiseWovenContracts(formatted, wovenGenerics, extraRecordDecls, pkgLabel, files) {
    case Some(f) -> f
    case None -> return None
  }
  Some(value = AwaitHoist.hoistAwaitsFileWithTypeArgCallees(specialised, extraRecordDecls, typeArgCallees))
}

/// The generics a woven wrapper's aspect contract can call (#7530): every
/// function visible to mono (`monoFuncs`, the list `pipeCheckAndMono` took)
/// plus the generic functions the file itself declared, which mono erased
/// from the file and recorded in `MiddleEndOptions.genericItemsOut`.
pub func pipeWovenGenerics(monoFuncs: in List[FunctionDecl], ownGenericItems: in List[Item]): List[FunctionDecl] {
  val all: List[FunctionDecl] = newList()
  for f in monoFuncs {
    all.add(f)
  }
  for gi in ownGenericItems {
    match gi.kind {
      case IFunc(fd) -> all.add(fd)
      case _ -> ()
    }
  }
  all
}

/// Aspect contracts exist only once the weaver has built a wrapper, after
/// `pipeCheckAndMono`, so a generic call in one (`ensures: isSome(result)`)
/// was never specialised and codegen found no function for it (T0123).  A
/// second mono run over the woven file specialises those calls, using the
/// wrapper's declared return type for `result`.  Specialisations the first run
/// already produced are not added twice.  A file the weaver did not wrap is
/// returned as it is.
func specialiseWovenContracts(
  woven: in SourceFile,
  generics: in List[FunctionDecl],
  extraRecordDecls: in List[RecordDecl],
  pkgLabel: in String,
  files: in List[String],
): Option[SourceFile] {
  if generics.count == 0 or not fileHasWovenWrapper(woven) {
    return Some(value = woven)
  }
  val noIfaces: List[InterfaceDecl] = newList()
  val noTypes: Map[String, TypeExpr] = newMap()
  val noCallTypes: Map[String, TypeExpr] = newMap()
  val noTypeArgSites: Map[String, GenericCallTypeArgsSite] = newMap()
  val noValueSites: Map[String, Map[String, Int]] = newMap()
  val noLambdaSites: Map[String, LambdaParamTypesSite] = newMap()
  val noSpecSites: Map[String, Map[String, ArgConversionSite]] = newMap()
  val res = monoFileWithLambdaTypes(
    woven,
    generics,
    noIfaces,
    extraRecordDecls,
    noTypes,
    noCallTypes,
    noTypeArgSites,
    noValueSites,
    noLambdaSites,
    noSpecSites
  )
  if gate(pkgLabel, files, res.diagnostics) {
    return None
  }
  // A specialisation the first run already made has the same name and arity
  // as the one made again; same-named functions of other arities are
  // overloads and stay.  Each key admits as many items as `woven` held, so
  // overloads that were already there are all kept.
  val allowed: Map[String, Int] = newMap()
  for it in woven.items {
    match it.kind {
      case IFunc(fd) -> bumpFuncKeyCount(allowed, funcKeyOf(fd))
      case _ -> ()
    }
  }
  val kept: Map[String, Int] = newMap()
  val items: List[Item] = newList()
  for it in res.file.items {
    match it.kind {
      case IFunc(fd) -> {
        val key = funcKeyOf(fd)
        val limit = match mapGet(allowed, key) { case Some(n) -> n; case None -> 1 }
        val have = match mapGet(kept, key) { case Some(n) -> n; case None -> 0 }
        if have >= limit {
          continue
        }
        bumpFuncKeyCount(kept, key)
      }
      case _ -> ()
    }
    items.add(it)
  }
  Some(
    value = SourceFile(
      fileAnnotations = res.file.fileAnnotations,
      moduleDoc = res.file.moduleDoc,
      packageDecl = res.file.packageDecl,
      imports = res.file.imports,
      items = items,
      span = res.file.span,
      files = res.file.files
    )
  )
}

func funcKeyOf(fd: in FunctionDecl): String {
  fd.name + "/" + toString(fd.params.count)
}

func bumpFuncKeyCount(counts: in Map[String, Int], key: in String): Unit {
  val n = match mapGet(counts, key) { case Some(c) -> c; case None -> 0 }
  if counts.containsKey(key) {
    counts.remove(key)
  }
  counts.add(key, n + 1)
}

// True when the weaver renamed a function to `<name>__aspect_target`.
func fileHasWovenWrapper(file: in SourceFile): Bool {
  for it in file.items {
    match it.kind {
      case IFunc(fd) -> {
        if Str.endsWith(fd.name, "__aspect_target") {
          return true
        }
      }
      case _ -> ()
    }
  }
  false
}

/// `formatN(template, a1, ..., aN)` becomes
/// `Std.String.formatArgs(template, [toString(a1), ..., toString(aN)])`
/// (#7840).  The placeholder grammar is implemented once, in Lyric, and every
/// argument is stringified exactly as `toString` stringifies it, so the
/// builtins agree on every target: a `UInt`/`ULong` argument the type checker
/// respelled as `.toUInt()`/`.toULong()` (#7812) renders unsigned, a `Double`
/// renders culture-invariant, and a `Byte` renders 0..255.  The template is
/// evaluated first and the arguments left to right, as before.  Every
/// synthesised node carries the call's own span: each is a `String`, as the
/// call is, so a span-keyed side table can never type one of them as the
/// argument it wraps.  A bundling backend links `Std.String` into any build
/// whose sources `pipeUsesFormatBuiltin`.
func lowerFormatBuiltin(e: in Expr): Expr {
  match e.kind {
    case ECall(fn, cargs) -> match fn.kind {
      case EPath(p) -> if p.segments.count == 1 {
        match formatBuiltinArity(p.segments[0]) {
          case Some(arity) -> if cargs.count == arity + 1 {
            val strs: List[Expr] = newList()
            var i = 1
            while i < cargs.count {
              strs.add(stringifiedFormatArg(callArgExprOf(cargs[i]), e.span))
              i = i + 1
            }
            val calleeSegs: List[String] = newList()
            calleeSegs.add("Std")
            calleeSegs.add("String")
            calleeSegs.add("formatArgs")
            val newArgs: List[CallArg] = newList()
            newArgs.add(CAPositional(expr = callArgExprOf(cargs[0])))
            newArgs.add(CAPositional(expr = Expr(kind = EList(exprs = strs), span = e.span)))
            Expr(
              kind = ECall(
                fn = Expr(kind = EPath(path = ModulePath(segments = calleeSegs, span = fn.span)), span = fn.span),
                args = newArgs
              ),
              span = e.span
            )
          } else {
            e
          }
          case None -> e
        }
      } else {
        e
      }
      case _ -> e
    }
    case _ -> e
  }
}

/// The target-independent rewrite of `format1`-`format4` calls, for a backend
/// that bundles stdlib packages without running them through `pipeWeave`
/// (native, #7984): a `Std.*` package that calls `formatN` must reach codegen
/// as the `Std.String.formatArgs` call every other build gives it.
pub func pipeLowerFormatBuiltins(file: in SourceFile): SourceFile {
  mapExprsInFile(file, lowerFormatBuiltin)
}

/// True when `file` calls a `format1`-`format4` builtin, before or after
/// `lowerFormatBuiltin` rewrote it: its build needs `Std.String`, which a
/// bundling backend (JVM, native) otherwise links only when some bundled
/// package imports it.
pub func pipeUsesFormatBuiltin(file: in SourceFile): Bool {
  anyExprInFile(file, { e: Expr -> isFormatCall(e) or mayRenderStructure(e) })
}

/// True for an expression that may stringify a record, union, tuple or
/// collection (D282): an interpolation, a `+` or `+=` (which concatenates when
/// an operand is a `String`), a `println`/`print`/`toString` call or a
/// `.toString()` call.  The rendering functions the type checker synthesizes
/// for such a stringification call `Std.String.showSeq`, `showMap` and
/// `showSet` and `Std.Collections`, but which operand types occur is known only
/// after the check, after a bundling backend has chosen the packages it links.
/// So these expressions are over-approximated to link `Std.String` too.
func mayRenderStructure(e: in Expr): Bool {
  match e.kind {
    case EInterpolated(_) -> true
    case EBinop(op, _, _) -> match op { case BAdd -> true; case _ -> false }
    case EAssign(_, op, _) -> match op { case AssPlus -> true; case _ -> false }
    case ECall(fn, _) -> match fn.kind {
      case EPath(p) -> p.segments.count == 1 and isStringifyingBuiltin(p.segments[0])
      case EMember(_, name) -> name == "toString"
      case _ -> false
    }
    case _ -> false
  }
}

func isFormatCall(e: in Expr): Bool {
  match e.kind {
    case ECall(fn, cargs) -> match fn.kind {
      case EPath(p) -> {
        val isBuiltin = p.segments.count == 1 and
          (
            match formatBuiltinArity(p.segments[0]) {
              case Some(arity) -> cargs.count == arity + 1
              case None -> false
            }
          )
        val isLowered = p.segments.count == 3 and p.segments[0] == "Std" and p.segments[1] == "String" and
          p.segments[2] == "formatArgs"
        isBuiltin or isLowered
      }
      case _ -> false
    }
    case _ -> false
  }
}

// `toString(arg)`; a string literal is already its own stringification.
func stringifiedFormatArg(arg: in Expr, span: in Span): Expr {
  match arg.kind {
    case ELiteral(lit) -> match lit { case LString(_) -> return arg; case _ -> () }
    case _ -> ()
  }
  val segs: List[String] = newList()
  segs.add("toString")
  val args: List[CallArg] = newList()
  args.add(CAPositional(expr = arg))
  Expr(
    kind = ECall(fn = Expr(kind = EPath(path = ModulePath(segments = segs, span = span)), span = span), args = args),
    span = span
  )
}

func callArgExprOf(arg: in CallArg): Expr {
  match arg {
    case CAPositional(x) -> x
    case CANamed(_, x, _) -> x
  }
}

/// `file0` with the rewrites its type check recorded made explicit
/// (`Lyric.Mono.desugarCheckedFile`): the first step after the check in
/// `pipeCheckAndMono`.
pub func pipeDesugarChecked(
  file0: in SourceFile,
  tcRes: in CheckResult,
  valueSites: in Map[String, FuncRefSite],
  listLiteralSites: in Map[String, ListLiteralTypeSite],
  hoistOperandSites: in Map[String, HoistOperandTypeSite],
): MonoResult {
  desugarCheckedFile(
    annotateModuleVals(file0, tcRes.symbols.moduleValTypes),
    tcRes.symbols.recordCopySites,
    valueSites,
    tcRes.symbols.argConversionSites,
    tcRes.symbols.localBindingTypeSites,
    tcRes.symbols.funcValueCallSites,
    tcRes.symbols.tuplePatternBindingSites,
    listLiteralSites,
    hoistOperandSites,
    tcRes.symbols.argOrderSites
  )
}

/// `file` with each value the type check recorded as flowing into a place of
/// the same generic type over a supertype of its type argument
/// (`SymbolTable.covariantSites`, `Result[English, E]` into
/// `Result[Greeter, E]`, D211) passed through the conversion function the
/// checker synthesized for it, which is added to the file.
func applyCovariantSites(file: in SourceFile, syms: in SymbolTable): SourceFile {
  val pending: Map[String, String] = newMap()
  for k in mapKeys(syms.covariantSites) {
    match mapGet(syms.covariantSites, k) {
      case Some(helper) -> pending.add(k, helper)
      case None -> ()
    }
  }
  val converted = mapExprsInFile(
    file,
    { e: Expr ->
      val key = recordCopySiteKey(e.span)
      match mapGet(pending, key) {
        case Some(helper) -> {
          pending.remove(key)
          val segs: List[String] = newList()
          segs.add(helper)
          val callee = Expr(kind = EPath(path = ModulePath(segments = segs, span = e.span)), span = e.span)
          val args: List[CallArg] = newList()
          args.add(CAPositional(expr = e))
          Expr(kind = ECall(fn = callee, args = args), span = e.span)
        }
        case None -> e
      }
    }
  )
  val items: List[Item] = newList()
  for it in converted.items {
    items.add(it)
  }
  for h in syms.covariantHelpers {
    items.add(funcItem(h))
  }
  SourceFile(
    moduleDoc = converted.moduleDoc,
    files = converted.files,
    fileAnnotations = converted.fileAnnotations,
    packageDecl = converted.packageDecl,
    imports = converted.imports,
    items = items,
    span = converted.span
  )
}

/// `file` with each stringified operand of a structured type
/// (`SymbolTable.showSites`, D282) passed through the function the checker
/// synthesized to render it, which is added to the file.  The wrapping call has
/// no source span: it is a `String`, and a span-keyed side table must never
/// type it as the operand it wraps.
pub func lowerShowSites(file: in SourceFile, syms: in SymbolTable): SourceFile {
  val have: Map[String, Bool] = newMap()
  lowerShowSpec(file, syms.showSites, syms.showHelpers, have)
}

/// `lowerShowSites` for explicit `sites` and `helpers`; a helper whose name is
/// in `have` is already in the file (the name identifies the rendered type, so
/// a re-checked specialisation names the same function the file's check did),
/// and each helper added is recorded there.
func lowerShowSpec(
  file: in SourceFile,
  sites: in Map[String, String],
  helpers: in List[FunctionDecl],
  have: in Map[String, Bool],
): SourceFile {
  if sites.count == 0 {
    return file
  }
  val pending: Map[String, String] = newMap()
  for k in mapKeys(sites) {
    match mapGet(sites, k) {
      case Some(helper) -> pending.add(k, helper)
      case None -> ()
    }
  }
  val wsp = noSourceSpan()
  val converted = mapExprsInFile(
    file,
    { e: Expr ->
      val key = recordCopySiteKey(e.span)
      match mapGet(pending, key) {
        case Some(helper) -> {
          pending.remove(key)
          val segs: List[String] = newList()
          segs.add(helper)
          val callee = Expr(kind = EPath(path = ModulePath(segments = segs, span = wsp)), span = wsp)
          val args: List[CallArg] = newList()
          args.add(CAPositional(expr = e))
          args.add(CAPositional(expr = Expr(kind = ELiteral(lit = LInt(value = 0, suffix = I32, raw = "")), span = wsp)))
          Expr(kind = ECall(fn = callee, args = args), span = wsp)
        }
        case None -> e
      }
    }
  )
  val items: List[Item] = newList()
  for it in converted.items {
    items.add(it)
  }
  for h in helpers {
    if not have.containsKey(h.name) {
      have.add(h.name, true)
      items.add(funcItem(h))
    }
  }
  SourceFile(
    files = converted.files,
    moduleDoc = converted.moduleDoc,
    fileAnnotations = converted.fileAnnotations,
    packageDecl = converted.packageDecl,
    imports = converted.imports,
    items = items,
    span = converted.span
  )
}

/// `sites` with each of `fallbacks` whose key it does not already hold.
func withPropagateFallbacks(
  sites: in Map[String, HoistOperandTypeSite], fallbacks: in Map[String, HoistOperandTypeSite]
): Map[String, HoistOperandTypeSite] {
  if fallbacks.count == 0 {
    return sites
  }
  val merged: Map[String, HoistOperandTypeSite] = newMap()
  for k in mapKeys(sites) {
    match mapGet(sites, k) {
      case Some(v) -> merged.add(k, v)
      case None -> ()
    }
  }
  for k in mapKeys(fallbacks) {
    match mapGet(fallbacks, k) {
      case Some(v) -> if not merged.containsKey(k) { merged.add(k, v) }
      case None -> ()
    }
  }
  merged
}

/// `file0`'s declarations with their defaults as the middle end will leave
/// them: a parameter or field default that widens gets its explicit
/// conversion (#7811).  For a backend that must know another package's
/// defaults before that package's own middle end has run (the JVM bundle
/// generates the entry package's code first).  The check's diagnostics are
/// dropped: the package's real middle end reports them.
pub func pipeCheckedDefaults(file0: in SourceFile, importedPkgs: in List[ImportedPackage]): SourceFile {
  val tcRes = checkWithImportedPackages(file0, importedPkgs)
  // Only the JVM bundle calls this, and the JVM binds only the list literals
  // whose shape their position alone fixes
  // (`MiddleEndOptions.bindListLiteralTypes`).
  pipeDesugarChecked(file0, tcRes, funcValueSites(tcRes.symbols), shapeRequiredListLiteralSites(tcRes.symbols.listLiteralTypeSites), tcRes.symbols.hoistOperandTypeSites).file
}

/// The sites of `sites` whose literal's position alone fixes its shape
/// (`ListLiteralTypeSite.shapeRequired`): a backend that binds no other list
/// literal to its checked type still binds these (#8192).
pub func shapeRequiredListLiteralSites(sites: in Map[String, ListLiteralTypeSite]): Map[String, ListLiteralTypeSite] {
  val kept: Map[String, ListLiteralTypeSite] = newMap()
  for k in mapKeys(sites) {
    match mapGet(sites, k) {
      case Some(v) -> if v.shapeRequired and not v.conflicting { kept.add(k, v) }
      case None -> ()
    }
  }
  kept
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
      opts.filePaths,
      monoRecordDecls,
      opts.typeArgCalleesOut,
      opts.contractsEnabled,
      pipeWovenGenerics(monoGenFuncs, opts.genericItemsOut)
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
    // A `pub extern func` is callable from another package (a bindgen kernel
    // package is nothing but externs, D191).
    case IExternFunc(_) -> match it.visibility { case Some(VisPub(_)) -> true; case _ -> false }
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
    case IExternFunc(_) -> match it.visibility { case Some(_) -> true; case None -> false }
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
    files = source.files,
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
/// `carryPlainHelpers` — with `requirePub` false, also copy the private
/// non-generic helpers the generics reach (a source dependency of a JVM
/// build); with `requirePub` true they are always copied.
/// `pkgImports` — the declaring package's imports (`pipeOriginImportsOf` /
/// `pipeOriginImportsFrom`), recorded on each collected decl
/// (`Lyric.Mono.withOriginImportsMono`) so Mono resolves a tie between
/// same-named candidates in a specialised body the way the type checker
/// resolved it in that package's scope.
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
  pkgImports: in List[String],
  requirePub: in Bool,
  excludeIntrinsics: in Bool,
  dest: in List[FunctionDecl],
  carryPlainHelpers: in Bool = false,
): Unit {
  if not requirePub and carryPlainHelpers {
    // Every generic is collected as it is; the private non-generic helpers they reach are copied
    // under package-unique names, since a specialised body cannot bind them in the package that
    // declares them (#8427).
    val carried = carryPlainHelpersOfGenerics(items, pkgName)
    for decl in carried.pubFuncs {
      val isIntrinsic = excludeIntrinsics and decl.name == "mapGet" and pkgName == "Std.Collections"
      if not isIntrinsic and not pipeAnnsBlockSpecialization(decl.annotations) {
        dest.add(withOriginImportsMono(withOriginPkgMono(decl, pkgName), pkgImports))
      }
    }
    for decl in carried.privateCopies {
      if not pipeAnnsBlockSpecialization(decl.annotations) {
        dest.add(withOriginImportsMono(withOriginPkgMono(decl, pkgName), pkgImports))
      }
    }
    return
  }
  if requirePub {
    // The private generics, and the private non-generic helpers, a `pub` generic reaches travel with
    // it under package-unique names (#8427).
    val carried = carryPrivateGenerics(items, pkgName)
    for decl in carried.pubFuncs {
      if not pipeAnnsBlockSpecialization(decl.annotations) {
        dest.add(withOriginImportsMono(withOriginPkgMono(decl, pkgName), pkgImports))
      }
    }
    for decl in carried.privateCopies {
      if not pipeAnnsBlockSpecialization(decl.annotations) {
        dest.add(withOriginImportsMono(withOriginPkgMono(decl, pkgName), pkgImports))
      }
    }
    return
  }
  var i = 0
  while i < items.count {
    match items[i].kind {
      case IFunc(decl) -> {
        val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
        val hasBody = match decl.body { case Some(_) -> true; case None -> false }
        val isIntrinsic = excludeIntrinsics and decl.name == "mapGet" and pkgName == "Std.Collections"
        if not isIntrinsic and isGeneric and hasBody and not pipeAnnsBlockSpecialization(decl.annotations) {
          dest.add(withOriginImportsMono(withOriginPkgMono(decl, pkgName), pkgImports))
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

/// The imports of a package in the form `pipeAddGenericFuncs` records: `P` for
/// a whole import of `P`, `P::f` for each name `f` imported selectively.  An
/// aliased whole import, or an aliased item, exposes no bare name and is left
/// out, as is an `import extern`.
pub func pipeOriginImportsOf(imports: in List[ImportDecl]): List[String] {
  val acc: List[String] = newList()
  for imp in imports {
    if not imp.isExtern {
      val pkg = Str.joinList(".", imp.path.segments)
      match imp.selector {
        case None -> match imp.asAlias { case None -> acc.add(pkg); case Some(_) -> () }
        case Some(sel) -> match sel {
          case ISSingle(item) -> match item.asAlias {
            case None -> acc.add(pkg + "::" + item.name)
            case Some(_) -> ()
          }
          case ISGroup(group) -> {
            for item in group {
              match item.asAlias {
                case None -> acc.add(pkg + "::" + item.name)
                case Some(_) -> ()
              }
            }
          }
        }
      }
    }
  }
  acc
}

/// `pipeOriginImportsOf` for a package known only by its recorded import
/// lists (a stdlib package, a restored artifact's contract): `whole` holds
/// whole imports, `selected` holds `P::f` entries.
pub func pipeOriginImportsFrom(whole: in List[String], selected: in List[String]): List[String] {
  val acc: List[String] = newList()
  for w in whole {
    acc.add(w)
  }
  for sel in selected {
    acc.add(sel)
  }
  acc
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
/// Lyric AST type system.  Each is tagged with its package (`pkgName`, the
/// same origin annotation `pipeAddGenericFuncs` applies) so Mono can tell
/// two same-named imports apart by which package the caller imports.
pub func pipeAddNonGenericFuncs(items: in List[Item], pkgName: in String, dest: in List[FunctionDecl]): Unit {
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
          dest.add(withOriginPkgMono(decl, pkgName))
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

/// True for a non-`pub`, non-generic function with a body: the private helper
/// a `pub` generic may reach (`Lyric.ContractElaborator.carryPrivateGenerics`).
pub func pipeIsPrivatePlainFunc(it: in Item): Bool {
  match it.kind {
    case IFunc(decl) -> {
      val isPub = match decl.visibility { case Some(VisPub(_)) -> true; case _ -> false }
      val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
      val hasBody = match decl.body { case Some(_) -> true; case None -> false }
      not isPub and not isGeneric and hasBody
    }
    case _ -> false
  }
}

/// The private non-generic functions of `items` as written, keyed `f:<name>/<arity>`.
/// The contract builders take them from the file as it stood before the middle end, since
/// a copy is specialised from its source in the package that calls the generic.
/// `Lyric.ContractElaborator.carryPrivateGenerics` copies no helper whose name is overloaded,
/// and this map leaves out a key two functions share, so the two agree on which helpers exist.
pub func pipePrivatePlainFuncItems(items: in List[Item]): Map[String, Item] {
  val byKey: Map[String, Item] = newMap()
  val repeated: Map[String, Bool] = newMap()
  for it in items {
    if pipeIsPrivatePlainFunc(it) {
      match it.kind {
        case IFunc(decl) -> {
          val key = "f:" + decl.name + "/" + toString(decl.params.count)
          if byKey.containsKey(key) {
            repeated[key] = true
          } else {
            byKey.add(key, it)
          }
        }
        case _ -> ()
      }
    }
  }
  // Two functions of one name and arity cannot be told apart by that key.
  for k in mapKeys(repeated) {
    byKey.remove(k)
  }
  byKey
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

func hasFileAnnotation(file: in SourceFile, name: in String): Bool {
  for a in file.fileAnnotations {
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return true
    }
  }
  false
}

func hasAnnotationNamed(anns: in List[Annotation], name: in String): Bool {
  for a in anns {
    if a.name.segments.count == 1 and a.name.segments[0] == name {
      return true
    }
  }
  false
}

// The spans of the functions and methods `file` marks `@io`: in a `@pure`
// package these are the places allowed to do I/O.
func ioFunctionSpans(file: in SourceFile): List[Span] {
  val spans: List[Span] = newList()
  for it in file.items {
    match it.kind {
      case IFunc(fn) -> {
        if hasAnnotationNamed(fn.annotations, "io") {
          spans.add(fn.span)
        }
      }
      case IRecord(decl) -> {
        for m in decl.members {
          match m {
            case RMFunc(fn) -> {
              if hasAnnotationNamed(fn.annotations, "io") {
                spans.add(fn.span)
              }
            }
            case _ -> ()
          }
        }
      }
      case IImpl(decl) -> {
        for m in decl.members {
          match m {
            case IMplFunc(fn) -> {
              if hasAnnotationNamed(fn.annotations, "io") {
                spans.add(fn.span)
              }
            }
            case _ -> ()
          }
        }
      }
      case _ -> ()
    }
  }
  spans
}

/// The layer diagnostics (D149) for a package that may not do I/O: a
/// package-level `@pure`, or a `[layers]` layer whose rule does not allow
/// `io` (`layerReason`, "" when none).  In a `@pure` package the functions
/// it marks `@io` are exempt from Y0003 and Y0008: they are the package's
/// declared I/O surface.  Y0007 applies to the whole package either way.
pub func effectDiagnostics(file: in SourceFile, symbols: in SymbolTable, layerReason: in String): List[Diagnostic] {
  val diags: List[Diagnostic] = newList()
  val isPure = hasFileAnnotation(file, "pure")
  if layerReason == "" and not isPure {
    return diags
  }
  val pkg = modulePathJoin(file.packageDecl.path.segments)
  val reason = if layerReason != "" { layerReason + " does not allow io" } else { "it is @pure" }
  val exempt: List[Span] = if layerReason == "" { ioFunctionSpans(file) } else { newList() }
  for key in mapKeys(symbols.effectCallSites) {
    match mapGet(symbols.effectCallSites, key) {
      case Some(site) -> {
        var allowed = false
        for sp in exempt {
          if spanWithin(site.span, sp) {
            allowed = true
          }
        }
        if not allowed {
          if site.isEntry {
            diags.add(
              errorDiagnostic(
                "Y0008",
                "package " + pkg + " calls protected entry " + site.callee + ", but " + reason +
                  "; move the shared state behind an effect",
                site.span
              )
            )
          } else {
            diags.add(
              errorDiagnostic(
                "Y0003",
                "package " + pkg + " calls @io function " + site.callee + ", but " + reason +
                  "; pass the value in, or perform the call in an effect",
                site.span
              )
            )
          }
        }
      }
      case None -> ()
    }
  }
  for v in symbols.mutableModuleVals {
    diags.add(
      errorDiagnostic(
        "Y0007",
        "module-level val " + v.name + " in package " + pkg + " holds " + v.what + ", shared mutable state, but " + reason,
        v.span
      )
    )
  }
  diags
}

// End the body of every lambda whose checked type returns `Unit`
// (`SymbolTable.lambdaUnitSites`) in `()` (#8299).  The lambda's value is
// `Unit` either way; the trailing `()` states it in the tree itself, so every
// backend, and every copy of the body a specialisation of its generic makes in
// this package or another, builds the lambda as the `Unit`-returning function
// its type is (an `Action` on .NET) however the type checker came to type it
// (no expected type, an unannotated `val`, an erased generic argument).
pub func endUnitLambdasInUnit(file: in SourceFile, sites: in Map[String, Bool]): SourceFile {
  if sites.count == 0 {
    return file
  }
  mapExprsInFile(
    file,
    { e: Expr ->
      match e.kind {
        case ELambda(ps, body) -> match mapGet(sites, recordCopySiteKey(e.span)) {
          case Some(isUnit) -> if isUnit {
            Expr(kind = ELambda(lambdaParams = ps, body = endBlockInUnit(body)), span = e.span)
          } else {
            e
          }
          case None -> e
        }
        case _ -> e
      }
    }
  )
}

// `body`, ending in `()`.  A body already ending in `()`, a `return` or a
// `throw` is left as it is.
func endBlockInUnit(body: in Block): Block {
  val n = body.statements.count
  if n > 0 {
    match body.statements[n - 1].kind {
      case SExpr(tail) -> match tail.kind {
        case ELiteral(lit) -> match lit { case LUnit -> return body; case _ -> () }
        case _ -> ()
      }
      case SReturn(_) -> return body
      case SThrow(_) -> return body
      case _ -> ()
    }
  }
  val stmts: List[Statement] = newList()
  for st in body.statements {
    stmts.add(st)
  }
  val unitSpan = Span(startPos = body.span.endPos, endPos = body.span.endPos)
  stmts.add(Statement(kind = SExpr(expr = Expr(kind = ELiteral(lit = LUnit), span = unitSpan)), span = unitSpan))
  Block(statements = stmts, span = body.span)
}
