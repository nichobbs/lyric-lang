//! jvm/bridge.l — Self-hosted JVM compilation pipeline (Phase R4).
//!
//! Public entry point that chains the self-hosted Lyric pipeline to produce a
//! JAR file from Lyric source text.  Calls parse → typecheck → modecheck →
//! elaborate → mono → codegen → lower → write.
package Jvm.Bridge

import Std.Core
import Std.Collections
import Std.String as Str
import Std.Console as Console
import Std.Encoding as Encoding
import Lyric.BuildDefines as BD
import Lyric.ContractMeta as Meta
import Lyric.Lexer
import Lyric.Parser
import Lyric.TypeChecker
import Lyric.ModeChecker
import Lyric.ContractElaborator
import Lyric.Propagate
import Lyric.AliasRewriter as Aliases
import Lyric.BareFuncRef as BFR
import Lyric.TypeAliasResolve as TAR
import Lyric.Weaver as Weaver
import Lyric.WireExpand as WireExpand
import Lyric.DiagnosticUtil as DiagUtil
import Lyric.Mono
import Lyric.Derives
import Lyric.Pipeline
import Lyric.ContractMeta as Meta
import Lyric.RestoredPackages
import Jvm.Kernel
import Jvm.Classfile
import Jvm.Lowering
import Jvm.AutoFfi
import Jvm.Codegen
import Jvm.Driver

// Returns Some(typeName) if func main() has a 2-slot return type (Long or Double);
// None otherwise.  These types require POP2 to discard, but the JVM main wrapper
// only emits a single-slot POP — so they must be rejected before codegen rather
// than panicking inside codegenPackage.
func mainReturns2SlotType(file: in SourceFile): Option[String] {
  var i = 0
  while i < file.items.count {
    val item = file.items[i]
    match item.kind {
      case IFunc(decl) -> {
        if decl.name == "main" {
          match decl.ret {
            case Some(te) -> {
              match te.kind {
                case TRef(path) -> {
                  if path.segments.count > 0 {
                    val last = path.segments[path.segments.count - 1]
                    if last == "Long" or last == "Double" {
                      return Some(last)
                    }
                  }
                }
                case _ -> ()
              }
            }
            case None -> ()
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  return None
}

// `Std.Encoding.encodeUtf8` returns `slice[Byte]`; `Jvm.Zip.ZipEntry.data`
// wants `List[Byte]` (it accumulates entries alongside compiled class-file
// byte lists). Plain copy, no re-encoding.
func utf8SliceToByteList(bs: in slice[Byte]): List[Byte] {
  val result: List[Byte] = newList()
  var i = 0
  while i < bs.length {
    result.add(bs[i])
    i = i + 1
  }
  result
}

// Re-attach same-file pub generic `func`s the monomorphizer stripped, so the
// embedded contract's declaration list still carries them (#4994 review
// finding). `Lyric.Mono` (shared `pipeCheckAndMono`, target-agnostic) drops
// a generic `pub func` from a file's item list once every call site in that
// SAME compilation unit has been specialised into a concrete copy — correct
// for codegen (nothing calls the generic original directly any more) but
// wrong for a contract meant to describe the package's public API to
// EXTERNAL consumers, who need the generic declaration itself (its own
// call sites live in a DIFFERENT file, so `Lyric.Mono` never sees them and
// they will fail to resolve without it). `Msil.Bridge` hit this exact
// failure mode building `Lyric.Contract.<Pkg>` resources for its own
// project-as-DLL bundles and fixed it with `withGenericFuncsForContract`;
// this mirrors that verbatim (same merge rule: keep every `postMono` item,
// then walk `preMono` adding back any `pub`+generic `IFunc` whose name
// isn't already present post-mono).
func withGenericFuncsForContract(preMono: in SourceFile, postMono: in SourceFile): SourceFile {
  val items: List[Item] = newList()
  val postFuncNames: Map[String, Bool] = newMap()
  var pi = 0
  while pi < postMono.items.count {
    val it = postMono.items[pi]
    match it.kind {
      case IFunc(decl) -> {
        if not postFuncNames.containsKey(decl.name) {
          postFuncNames.add(decl.name, true)
        }
      }
      case _ -> ()
    }
    items.add(it)
    pi = pi + 1
  }
  var gi = 0
  while gi < preMono.items.count {
    val it = preMono.items[gi]
    match it.kind {
      case IFunc(decl) -> {
        val isPub = match it.visibility { case Some(VisPub(_)) -> true; case _ -> false }
        val isGeneric = match decl.generics { case Some(_) -> true; case None -> false }
        if isPub and isGeneric and not postFuncNames.containsKey(decl.name) {
          items.add(it)
        }
      }
      case _ -> ()
    }
    gi = gi + 1
  }
  SourceFile(
    moduleDoc = postMono.moduleDoc,
    fileAnnotations = postMono.fileAnnotations,
    packageDecl = postMono.packageDecl,
    imports = postMono.imports,
    items = items,
    span = postMono.span
  )
}

// Build this package's `Lyric.Contract.<Pkg>` JAR resource entry (#4994) as
// a (name, bytes) pair: mirrors `Msil.Bridge`'s `embedLyricContract` for a
// project-as-DLL bundle, except the payload lands as a plain named ZIP entry
// (no CLI/PE manifest-resource table on the JVM side) rather than a
// `ManifestResource` row. `Lyric.ContractMeta.buildContractFromFile` /
// `contractToJson` are already target-agnostic (pure structural walk over
// the parsed `SourceFile` plus a JSON string writer) — the only
// JVM-specific piece is where the bytes end up. Read back by
// `Lyric.ContractMeta.readAllContractsFromJarFile`.
//
// `preMono` is the file as it stood just before `runMiddleEnd` (which calls
// `pipeCheckAndMono` internally); `postMono` is the file `runMiddleEnd`
// returned. Both are needed only for `withGenericFuncsForContract`'s
// re-attachment merge, above.
//
// Returns a plain `(String, List[Byte])` pair rather than a
// `Jvm.Zip.ZipEntry` — see `Jvm.Driver.writeJarFromClassesWithResources`'s
// doc comment for why threading that record through this file didn't work.
//
// Always suffixed (`Lyric.Contract.<Pkg>`), never the bare legacy
// `Lyric.Contract` name the MSIL bridge uses for a genuinely single-package
// assembly: every JVM build — including a one-file program — routes through
// THIS multi-package bridge (`compileToJarBundledWithFeatures` forwards a
// single source into a one-element `pkgSrcs` list), so there is no separate
// single-package JVM emission path to give the bare name meaning, and the
// reader scans for either form regardless.
func contractZipEntry(
  preMono: in SourceFile, postMono: in SourceFile, pkgName: in String, version: in String
): (String, List[Byte]) {
  val withGenerics = withGenericFuncsForContract(preMono, postMono)
  val contract = Meta.buildContractFromFile(withGenerics, version)
  val json = Meta.contractToJson(contract);
  ("Lyric.Contract." + pkgName, utf8SliceToByteList(Encoding.encodeUtf8(json)))
}

/// Compile `source` to a JAR at `outputPath`.
///
/// Returns true on success; false if the source contains parse errors or the
/// JAR write fails.  `packageName` is the Lyric package identifier the F# CLI
/// derives from the source filename — it is used as the `Lyric-Package`
/// manifest attribute.  The JVM `Main-Class` attribute is derived from the
/// source's actual `package` declaration so a Lyric program saved as
/// `hello_jvm.l` but declaring `package Hello` still produces a runnable
/// `java -jar` artefact.
/// Band 6: accept pre-read stdlib source texts and use them as imported items
/// for cross-package type resolution.  Callers (F# shims) read the stdlib .l
/// files from disk and pass them here; this function parses them and feeds the
/// resulting items to checkWithImports so that stdlib names like `List`, `Option`,
/// `Result`, and `Map` resolve correctly rather than raising T0010 / T0014.
pub func compileToJar(
  source: in String,
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
  packageVersion: in String,
): Bool {
  // Parse + `@cfg` erasure with an empty active set (plus the `target.jvm`
  // pseudo-feature, D-N-013) — the same semantics a manifest build with no
  // `--features` applies via `compileProjectToJarBundledWithFeatures`
  // (docs/59 §5.4; the declared set stays empty so the F0013 typo guard is
  // off, matching a manifest with no `[features]` table).
  val noFeatures: List[String] = newList()
  val jvmDefines = BD.decodeDefines(newList())
  val cfgFile = match pipeParseAndErase(source, "jvm", noFeatures, noFeatures, jvmDefines) {
    case Some(f) -> f
    case None -> return false
  }

  // Reject func main(): Long/Double before codegen: the JVM main wrapper emits
  // a single-slot POP to discard the return value, which would corrupt the operand
  // stack for 2-slot types (VerifyError at class load).  Surface the error here
  // as a clean compiler diagnostic rather than a panic inside codegenPackage.
  match mainReturns2SlotType(cfgFile) {
    case Some(ty) -> {
      Console.error("error[J001]: `func main(): " + ty + "` is not supported on the JVM target")
      Console.error("  hint: use `func main(): Int` (exit code) or `func main(): Unit`")
      return false
    }
    case None -> ()
  }

  // ── Middle-end (Band 1 + Band 6 of docs/41 §9) ─────────────────────────
  // Run the self-hosted type checker with stdlib imports, mode checker, and
  // contract elaborator before codegen.
  //
  // Band 6: collect each stdlib source's type declarations (functions are
  // skipped — many share a name, e.g. toString), grouped by declaring package
  // so same-named cross-package types (Std.Regex/Std.RegexSafe RegexError)
  // resolve against their own package rather than colliding.
  val importedPkgs: List[ImportedPackage] = newList()
  // Parsed stdlib source files, retained so `collectStdlibGenericFuncsJvm`
  // can feed the stdlib's pure-Lyric generic `pub func`s to the
  // monomorphizer (M-5 cross-package specialisation; parity with the
  // MSIL bridge's `collectStdlibGenericFuncs`).
  val stdlibFiles: List[SourceFile] = newList()
  var si = 0
  while si < stdlibSources.count {
    val stdPr = parse(stdlibSources[si])
    // Surface stdlib parse diagnostics — advisory, not fatal (#914).
    // See the matching block in `lyric-compiler/msil/bridge.l` for the
    // rationale: self-hosted `Lyric.Parser` has known gaps vs. the
    // stdlib source files, so promoting these to fatal would break
    // every user build until the parser reaches stdlib parity.
    DiagUtil.diagReport(stdPr.diagnostics)
    val pkgItems: List[Item] = newList()
    var ii = 0
    while ii < stdPr.file.items.count {
      val it = stdPr.file.items[ii]
      if pipeIsCrossPackageItem(it) {
        pkgItems.add(it)
      }
      ii = ii + 1
    }
    importedPkgs.add(
      ImportedPackage(
        name = dottedPath(stdPr.file.packageDecl.path),
        items = pkgItems,
        imports = collectImportNames(stdPr.file.imports)
      )
    )
    stdlibFiles.add(stdPr.file)
    si = si + 1
  }

  // Pre-typecheck rewrite chain (`Lyric.Pipeline` owns the order): docs/58
  // wire-template expansion, alias rewrite, `@stubbable` synthesis, then
  // `injectWeaveImports` (JVM-only: ensures `import Std.Time` is present
  // before any import-driven resolution when an aspect references
  // `call.elapsed`, #1298 — the weave itself runs inside `pipeMiddleEnd`).
  val weWires: Map[String, CollectedWireTemplate] = newMap()
  val weConfigs: Map[String, CollectedConfigTemplate] = newMap()
  WireExpand.collectWireTemplates(cfgFile.items, dottedPath(cfgFile.packageDecl.path), weWires, weConfigs)
  val file0 = resolveTypeAliases(
    match pipeExpandAndRewrite(cfgFile, weWires, weConfigs, true, true, true) {
      case Some(f) -> f
      case None -> return false
    }
  )

  // Middle end.  Type-check errors on the user's own file gate fatally,
  // matching the MSIL bridge — a build that prints error[T00xx] and still
  // reports "built" ships a miscompiled program (#5609 item 1).  Mode
  // check, `?`-propagation, mono, and weave gate as before.  Mono is fed
  // the stdlib's pure-Lyric generic `pub func`s plus the imported
  // interface / record decls (#3813).  This legacy path derives without
  // imported items (`deriveImports` empty), matching its historical
  // `deriveFile` call.
  val stdlibGenFuncs = collectStdlibGenericFuncsJvm(stdlibFiles)
  val importedItems = flattenImportedItems(importedPkgs)
  val noDeriveImports: List[Item] = newList()
  val noTemplates: Map[String, CollectedTemplate] = newMap()
  val opts = MiddleEndOptions(tcFatal = true, tcReport = false, pkgLabel = "")
  val file = match pipeMiddleEnd(file0, importedPkgs, noDeriveImports, stdlibGenFuncs, pipeInterfaceDecls(importedItems), pipeRecordDecls(importedItems), noTemplates, opts) {
    case Some(f) -> f
    case None -> return false
  }

  val pkg = codegenPackage(file)
  val pool = poolNew()
  val classFiles = lowerPackage(pkg, pool)

  val classes: List[BuiltClass] = newList()
  var j = 0
  while j < classFiles.count {
    val cf = classFiles[j]
    classes.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
    j = j + 1
  }

  // Derive the JVM `Main-Class` from the source's `package` declaration.
  // ModulePath segments are joined with "." (JVM manifest convention).
  // Falls back to the F#-supplied packageName when the file has no package
  // declaration (only the synthetic stdlib bootstrap can hit that path).
  // Use the post-mono `file` rather than the raw parse tree so that
  // future package-renaming passes in the middle-end stay authoritative.
  val segs = file.packageDecl.path.segments
  var mainClassName: String = packageName
  if segs.count > 0 {
    var k = 0
    var acc = ""
    while k < segs.count {
      if k > 0 {
        acc = acc + "."
      }
      acc = acc + segs[k]
      k = k + 1
    }
    mainClassName = acc
  }

  // Empty `packageVersion` (ad-hoc compiles with no manifest in scope, e.g.
  // the internal self-tests) falls back to the JVM path's legacy "0.1.0"
  // default, kept for backward compatibility with existing no-manifest
  // callers. Note `Msil.Bridge` uses "0.0.0" for the same situation — the
  // placeholder values intentionally differ per target (#5834).
  val jarVersion = if packageVersion.length == 0 { "0.1.0" } else { packageVersion }
  val req = BuildRequest(
    packageName = packageName,
    mainClass = mainClassName,
    version = jarVersion,
    outPath = outputPath,
    classpathJars = newList()
  )

  writeJarFromClasses(req, classes)
}

// ─────────────────────────────────────────────────────────────────────────────
// Multi-package JAR compilation (#1611).
//
// `compileToJar` above bundles only the user's own package, so a program that
// imports `Std.Testing` (or any stdlib package whose *functions* it calls)
// links but then faults at runtime — the callee's bytecode is absent.
// `compileToJarBundled` closes that gap: it compiles the user package plus the
// transitive closure of its stdlib imports into a single runnable JAR, and
// builds one cross-package call registry (JvmFuncSig) so every call site
// resolves its callee's host class + descriptor regardless of declaring package.
//
// Each package is lowered with its *own* constant pool.  Every package that
// reaches the bundling loop is in the user program's transitive import closure
// — i.e. it is *referenced* by the build — so a codegen failure for it is a
// real bug in a package the program depends on and is **fatal at compile time**
// (J1 B-6, #2664).  Mirrors the MSIL bridge, where the per-package codegen loop
// (`compileProjectToMsil`) likewise lets a codegen failure propagate rather than
// swallowing it.  Packages that are *not* in the closure are never added to the
// bundle list (the closure walk's `case None ->` arm), so they cannot mask a
// failure: their bytecode is simply absent, and a genuinely-unreached reference
// resolves lazily at a call that never happens.
// ─────────────────────────────────────────────────────────────────────────────
// Join a ModulePath's segments with "." (the Lyric package-name spelling).
func dottedPath(path: in ModulePath): String {
  pipeDottedPath(path)
}

// Run the middle-end (type check → mode check → contract elaborate →
// `?`-propagation lower → derive → monomorphise → weave) on one parsed file.
// Returns the post-weave file, or None if a fatal type-check (user-owned
// packages only, see `tcFatalUserPkg` below) / mode-check / propagate /
// mono / weave diagnostic was raised.
//
// Mirrors the MSIL bridge's per-package pass order (`?`-propagation after the
// elaborator, `monoFileWithImports` fed the stdlib's generic `pub func`s, then
// `Weaver.weaveFileWithDiagsAndTemplates` before codegen) so the JVM target
// weaves aspects (including cross-package from-instance aspects, #3414) and
// specialises cross-package generics with the same semantics (J2 / docs/44 §5,
// #2665).
//
// `templates` is the aspect-template map built from all packages in the
// bundle before the weave loop; `weaveFileWithDiagsAndTemplates` resolves
// from-instance aspects against it.  Pass an empty map for single-file builds.
//
// `stdlibGenFuncs` supplies the stdlib's pure-Lyric generic `pub func`s to the
// monomorphizer so cross-package generic calls specialise into this bundle.
//
// `tcFatalUserPkg` selects the type-check gating policy.  The user's own
// packages (the main file and sibling project packages) pass `true`:
// error-severity type diagnostics fail the build, exactly as on the MSIL
// target (#5609 item 1 — the JVM build previously printed error[T00xx]
// and still reported "built").  Bundled stdlib packages pass `false`:
// their type check stays advisory AND suppressed — the self-hosted
// checker lacks full builtin coverage on stdlib source, and echoing that
// noise would leak onto every *successful* build's output.  Real errors
// still gate on the mode-check / propagate / mono / weave passes for
// every package.  Thin wrapper over `Lyric.Pipeline.pipeMiddleEnd`,
// which owns the pass order; this bridge's per-target choices are the
// derive-with-imports project semantics and the stdlib-advisory type
// check.
func runMiddleEnd(
  file0: in SourceFile,
  importedPkgs: in List[ImportedPackage],
  stdlibGenFuncs: in List[FunctionDecl],
  templates: in Map[String, CollectedTemplate],
  tcFatalUserPkg: in Bool,
  pkgLabel: in String,
): Option[SourceFile] {
  val importedItems = flattenImportedItems(importedPkgs)
  val opts = MiddleEndOptions(tcFatal = tcFatalUserPkg, tcReport = false, pkgLabel = pkgLabel)
  pipeMiddleEnd(
    file0,
    importedPkgs,
    importedItems,
    stdlibGenFuncs,
    pipeInterfaceDecls(importedItems),
    pipeRecordDecls(importedItems),
    templates,
    opts
  )
}

// #6404: resolve `alias X = ...` references in `file` to their underlying
// `TypeExpr`, structurally, once. Must run BEFORE ANY signature/case/ctor
// registration reads the file — `compileProjectToJarBundledWithFeatures`
// pre-registers the user package's own signatures/cases/ctors (bundle-wide,
// first-wins registries) from the raw parsed file, well before its own
// `runMiddleEnd` call, so resolving any later (post-middle-end, or only
// inside `codegenPackageInto`) is too late: those registries would already
// have cached the unresolved alias name and every consumer — including the
// package's OWN later, correctly-resolved codegen — loses to the stale
// first-wins entry. Resolving here, right after parse + wire-expand +
// import-alias-rewrite and before type-check, is also harmless to
// type-check diagnostics: `alias` is fully transparent (language reference),
// so the type checker already treats an alias and its target as the same
// type — this can only change diagnostic WORDING (`Meters` vs `Long`), never
// pass/fail. See `Lyric.TypeAliasResolve`'s module doc for the full design
// rationale. STALE CLAIM CORRECTED (#6413): this pass was originally JVM-only
// on the belief MSIL's `cctx.aliasTargets` (#3673) covered MSIL universally —
// the #6410/#6411 review round found a shape it didn't (`alias L = List`
// used as a generic-application head) and wired this SAME pass into
// `Msil.Bridge` too (D-progress-748). Both bridges now run it.
func resolveTypeAliases(file: in SourceFile): SourceFile {
  TAR.resolveAliasesInFile(BFR.collectFuncAliasTargets(file), file)
}

// Collect every pure-Lyric generic `pub func` from the parsed stdlib source
// files so the monomorphizer can specialise cross-package generic call sites —
// e.g. `mapGet(m, "k")` -> a concrete `mapGet__String__String` copy emitted
// into the bundle — instead of leaving the generic return erased.  Same
// filter as `Msil.Bridge.collectStdlibGenericFuncs` (shared in
// `Lyric.Pipeline.pipeAddGenericFuncs`), operating directly on the
// already-parsed `SourceFile`s this bridge holds.  No `requirePub` — all
// stdlib items are implicitly public; `excludeIntrinsics` keeps `mapGet`
// with its codegen intrinsic.
func collectStdlibGenericFuncsJvm(files: in List[SourceFile]): List[FunctionDecl] {
  val genFuncs: List[FunctionDecl] = newList()
  var fi = 0
  while fi < files.count {
    val f = files[fi]
    pipeAddGenericFuncs(f.items, dottedPath(f.packageDecl.path), false, true, genFuncs)
    fi = fi + 1
  }
  // `mapGet`'s inference-only stub (`Lyric.Pipeline.pipeAddInferenceOnlyIntrinsicFuncs`),
  // appended LAST.  This JVM path has no separate in-bundle collector of
  // `Std.Collections`'s real `mapGet` to lose the first-wins merge to
  // (unlike the MSIL bridge's stdlib self-build, #6377), so ordering here is
  // purely for consistency with `Msil.Bridge.collectStdlibGenericFuncs`.
  var sfi = 0
  while sfi < files.count {
    val sf = files[sfi]
    pipeAddInferenceOnlyIntrinsicFuncs(sf.items, dottedPath(sf.packageDecl.path), genFuncs)
    sfi = sfi + 1
  }
  genFuncs
}

// Extern-type maps of every parsed package, keyed by dotted package name
// (parallel lists — a record-valued map trips the stage-0 bootstrap
// emitter).  `externSeedForFile` unions the maps of the packages `file`
// imports so signatures written against imported extern types (e.g.
// `Std.Time.now(): Instant` with `Instant` declared in `Std.TimeHost`)
// resolve to the real JVM class instead of `<pkg>/<Alias>`.
func externSeedForFile(
  file: in SourceFile, extPkgNames: in List[String], extPkgMaps: in List[Map[String, String]]
): Map[String, String] {
  val seed: Map[String, String] = newMap()
  // Build the file's import set once, then make a single pass over the
  // package list — O(imports + packages) instead of the previous
  // O(imports × packages) nested scan (#4667).
  val wanted: Map[String, Bool] = newMap()
  var ii = 0
  while ii < file.imports.count {
    val dn = dottedPath(file.imports[ii].path)
    if not wanted.containsKey(dn) {
      wanted.add(dn, true)
    }
    ii = ii + 1
  }
  var pi = 0
  while pi < extPkgNames.count {
    val isWanted = wanted.containsKey(extPkgNames[pi])
    for k in mapKeys(extPkgMaps[pi]) {
      match mapGet(extPkgMaps[pi], k) {
        case Some(v) -> {
          // Bare short-name key: only from packages `file` DIRECTLY imports
          // (own-package/import shadowing stays scoped to what `file` can
          // plausibly mean by an unqualified name — `ownAwareExternTypes`
          // (06_items.l) layers the caller's own colliding local type over
          // this, #5976).
          if isWanted {
            if not seed.containsKey(k) {
              seed.add(k, v)
            }
          }
          // Package-qualified key (`<owningPkgDotted>.<shortName>`) is seeded
          // BUNDLE-WIDE, regardless of `isWanted`: a multi-segment `TRef`/
          // `EPath` — the flattened form `Lyric.AliasRewriter` produces for
          // `import X as Y` + `Y.Type`, or the shape `eagerlyResolveGenericArg`
          // leaves untouched for a `retGenericArgs` entry whose head already
          // spells out its owning package — names its owning package
          // explicitly and can never legitimately mean a local type, so
          // scoping it to `file`'s own direct imports serves no shadowing
          // purpose and only creates blind spots. Without this, an extern
          // type reachable ONLY via an intermediate package's re-exported
          // function signature (`Std.RegexSafe.tryCompile(): Result[
          // Std.RegexHost.Regex, RegexError]`, consumed by a file that
          // imports `Std.RegexSafe` but never `Std.RegexHost` directly)
          // resolves through neither the bare key (not wanted) nor the
          // qualified key (also gated on wanted) at the match-bind site
          // (`resolveConcreteTypeExpr`/`typeExprToJvmExtern`), falling back
          // to "user type in my own package" — `NoClassDefFoundError` at
          // class-load (regex_safe_tests.l JVM, #5976 follow-up). Mirrors
          // `ctx.ctors`'s existing bundle-wide qualified-key registry for
          // plain declared types; extern types had no equivalent fallback.
          val qualKey = extPkgNames[pi] + "." + k
          if not seed.containsKey(qualKey) {
            seed.add(qualKey, v)
          }
        }
        case None -> ()
      }
    }
    pi = pi + 1
  }
  seed
}

// Import-aware view of the cross-package registry for one file: bare-name
// keys are re-pointed at the packages the file actually imports (its own
// package winning last), instead of the global first-registration winner.
// Two bundled packages exporting the same short name (`Std.Process` and
// `Std.ProcessCapture` both export `runCapture`) otherwise mis-resolve every
// unqualified call in every file to whichever package registered first —
// the #2535 collision class.  Qualified (`owner/name`) and instance
// (`class#method`) keys are copied unchanged.
func importAwareRegistry(file: in SourceFile, registry: in Map[String, JvmFuncSig]): Map[String, JvmFuncSig] {
  val owners: List[String] = newList()
  var ii = 0
  while ii < file.imports.count {
    if not file.imports[ii].isExtern {
      owners.add(pkgJvmOwner(file.imports[ii].path))
    }
    ii = ii + 1
  }
  // Own package last, so in-file definitions win over any import.
  owners.add(pkgJvmOwner(file.packageDecl.path))
  val overlay: Map[String, JvmFuncSig] = newMap()
  for k in mapKeys(registry) {
    match mapGet(registry, k) {
      case Some(sig) -> overlay.add(k, sig)
      case None -> ()
    }
  }
  var oi = 0
  while oi < owners.count {
    val pfx = owners[oi] + "/"
    for k2 in mapKeys(registry) {
      if Str.startsWith(k2, pfx) {
        val bare = k2.substring(pfx.length, k2.length - pfx.length)
        if bare.length > 0 and not Str.contains(bare, "/") and not Str.contains(bare, "#") and not Str.contains(bare, ".") {
          match mapGet(registry, k2) {
            case Some(sig2) -> {
              overlay.remove(bare)
              overlay.add(bare, sig2)
            }
            case None -> ()
          }
        }
      }
    }
    oi = oi + 1
  }
  overlay
}

// True when `acc` already carries a `BuiltClass` named `name` — used to
// deduplicate the shared cross-package `Lyric$Lambda` interface (see below).
func builtClassNameExists(acc: in List[BuiltClass], name: in String): Bool {
  var i = 0
  while i < acc.count {
    if acc[i].binaryName == name {
      return true
    }
    i = i + 1
  }
  false
}

// Codegen one (already middle-ended) file against `registry` and append its
// class files to `out`.  Uses an isolated constant pool per package.
func codegenPackageInto(
  file: in SourceFile,
  registry: in Map[String, JvmFuncSig],
  caseReg: in Map[String, List[JvmCaseField]],
  ctorReg: in Map[String, String],
  autoFfi: in AutoFfiCtx,
  allProjFqns: in Map[String, Bool],
  acc: in List[BuiltClass],
  externSeed: in Map[String, String],
): Unit {
  // `file` here already has its `alias X = ...` references resolved — see
  // `runMiddleEnd`'s #6404 comment; every caller of `codegenPackageInto`
  // passes `runMiddleEnd`'s result straight through.
  val pkg = codegenPackageWithSigsSeeded(
    file,
    importAwareRegistry(file, registry),
    caseReg,
    ctorReg,
    autoFfi,
    allProjFqns,
    externSeed
  )
  val pool = poolNew()
  val classFiles = lowerPackage(pkg, pool)
  // The shared `Lyric/Lyric$Lambda` functional interface (#5388/#5251,
  // `Jvm.Codegen.lambdaIfaceName`) is the SAME binary name for every package
  // in the bundle by design — cross-package closure invocation needs one
  // common interface to `checkcast`/`invokeinterface` against. Each
  // package's own codegen still decides independently whether it needs the
  // interface (`fileNeedsLambdaIface`/`closureAcc`), so several packages in
  // one bundle legitimately try to emit the identical class; keep only the
  // first copy so the JAR never carries duplicate entries for it.
  val sharedLambdaIface = lambdaIfaceName("")
  var j = 0
  while j < classFiles.count {
    val cf = classFiles[j]
    if cf.thisClass == sharedLambdaIface and builtClassNameExists(acc, cf.thisClass) {
      ()
    } else {
      acc.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
    }
    j = j + 1
  }
}

// ── Call-reachability (J1 B-6) ────────────────────────────────────────────
//
// The bundle list (`toBundle`) follows the *import* graph, which over-
// approximates the bytecode actually reached: a package can be imported only
// for its types (or be a dead import, like `Std.Testing`'s `import Std.File`)
// while none of its functions are ever invoked.  A codegen failure in such an
// import-only package must not fail the build — its bytecode is never reached.
//
// Reachability is computed at *function* granularity (matching the JVM's lazy
// per-method linking): a function is reachable when it is called transitively
// from one of the user package's own functions (the program entry points).  We
// resolve each call site to the callee's canonical registry key (`owner/name`)
// using the same two-stage lookup the codegen uses.  A call whose target is not
// in the registry (an extern / auto-FFI call such as a kernel shim's
// `lyric.stdlib.jvm.FileHost.fileExists`) resolves to nothing, so it cannot
// drag a package in via a colliding short name.  A bundled package is then
// "referenced" iff it declares at least one reachable function; only those are
// fatal-on-codegen-failure.  A package whose functions are all unreachable —
// dead imports, type-only imports, or sibling functions never invoked — is
// skipped (advisory) if its codegen fails, because the JAR never links them.
// Canonical registry key (`owner/name`) a call target resolves to, or "" when
// the callee is not a registered Lyric function (extern / auto-FFI / unresolved).
// Mirrors `lowerCall`'s two-stage lookup.  Kept flat (no nested option match)
// to dodge the stage-0 bootstrap emitter's `Map[_, record]` value-threading gap.
func registryKeyOf(registry: in Map[String, JvmFuncSig], key: in String): String {
  match mapGet(registry, key) {
    case Some(sig) -> sig.owner + "/" + lastSegOfKey(key)
    case None -> ""
  }
}

// The substring of a registry key after the last "/", i.e. the function name.
func lastSegOfKey(key: in String): String {
  var lastSlash = -1
  var i = 0
  while i < key.length {
    if key[i] == '/' {
      lastSlash = i
    }
    i = i + 1
  }
  if lastSlash < 0 {
    key
  } else {
    key.substring(lastSlash + 1, key.length - lastSlash - 1)
  }
}

// A package's JVM-internal owner name (segments joined with "/"), matching
// `Jvm.Codegen.segmentsToJvmPath` so it agrees with `JvmFuncSig.owner`.
func pkgJvmOwner(path: in ModulePath): String {
  ownerOfSegments(path.segments, path.segments.count)
}

// Join the first `upTo` segments with "/".
func ownerOfSegments(segments: in List[String], upTo: in Int): String {
  var acc = ""
  var si = 0
  while si < upTo {
    if si > 0 {
      acc = acc + "/"
    }
    acc = acc + segments[si]
    si = si + 1
  }
  acc
}

// Resolve a call target expression `fn` to the callee's canonical registry key
// (`owner/name`), or "" when it is not a registered Lyric function.
func resolveCallKey(fn: in Expr, registry: in Map[String, JvmFuncSig]): String {
  // Peel ETypeApp so explicit generic calls (foo[T](…)) resolve via their inner
  // path rather than falling through to `case _ -> ""` (#2780).
  val inner = match fn.kind { case ETypeApp(f, _) -> f; case _ -> fn }
  match inner.kind {
    case EPath(path) -> {
      if path.segments.count == 0 {
        ""
      } else if path.segments.count > 1 {
        // Qualified call: only the explicit-owner key counts.  A qkey absent
        // from the registry is an extern / non-Lyric FQN, so we do *not* fall
        // back to the bare name (which could mis-resolve a colliding short name
        // such as a kernel shim's `fileExists`).
        val funcName = path.segments[path.segments.count - 1]
        val owner = ownerOfSegments(path.segments, path.segments.count - 1)
        registryKeyOf(registry, owner + "/" + funcName)
      } else {
        registryKeyOf(registry, path.segments[0])
      }
    }
    case EMember(recv, memberName) -> {
      match recv.kind {
        case EPath(rpath) -> registryKeyOf(registry, ownerOfSegments(rpath.segments, rpath.segments.count) + "/" + memberName)
        case _ -> ""
      }
    }
    case _ -> ""
  }
}

// Walk `e`, resolving every call site's owner package into `acc` and recursing.
func collectExprNames(e: in Expr, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  match e.kind {
    case EInterpolated(segs) -> {
      var i = 0
      while i < segs.count {
        match segs[i] {
          case ISExpr(ex) -> collectExprNames(ex, acc, registry)
          case ISText(_, _) -> ()
        }
        i = i + 1
      }
    }
    case EParen(inner) -> collectExprNames(inner, acc, registry)
    case ETuple(exprs) -> collectExprListNames(exprs, acc, registry)
    case EList(exprs) -> collectExprListNames(exprs, acc, registry)
    case EIf(cond, thenB, elseB, _) -> {
      collectExprNames(cond, acc, registry)
      collectExprOrBlockNames(thenB, acc, registry)
      match elseB {
        case Some(eb) -> collectExprOrBlockNames(eb, acc, registry)
        case None -> ()
      }
    }
    case EMatch(scrut, arms) -> {
      collectExprNames(scrut, acc, registry)
      var i = 0
      while i < arms.count {
        match arms[i].guard {
          case Some(g) -> collectExprNames(g, acc, registry)
          case None -> ()
        }
        collectExprOrBlockNames(arms[i].body, acc, registry)
        i = i + 1
      }
    }
    case EAwait(inner) -> collectExprNames(inner, acc, registry)
    case EYield(inner) -> collectExprNames(inner, acc, registry)
    case ESpawn(inner) -> collectExprNames(inner, acc, registry)
    case ETry(inner) -> collectExprNames(inner, acc, registry)
    case EOld(inner) -> collectExprNames(inner, acc, registry)
    case ELambda(_, body) -> collectBlockNames(body, acc, registry)
    case ECall(fn, args) -> {
      val callKey = resolveCallKey(fn, registry)
      if callKey.length > 0 {
        acc.add(callKey)
      }
      collectExprNames(fn, acc, registry)
      var i = 0
      while i < args.count {
        match args[i] {
          case CANamed(_, value, _) -> collectExprNames(value, acc, registry)
          case CAPositional(ex) -> collectExprNames(ex, acc, registry)
        }
        i = i + 1
      }
    }
    case ETypeApp(fn, _) -> collectExprNames(fn, acc, registry)
    case EIndex(receiver, indices) -> {
      collectExprNames(receiver, acc, registry)
      collectExprListNames(indices, acc, registry)
    }
    case EMember(recv, _) -> collectExprNames(recv, acc, registry)
    case EPropagate(inner) -> collectExprNames(inner, acc, registry)
    case EPrefix(_, operand) -> collectExprNames(operand, acc, registry)
    case EBinop(_, lhs, rhs) -> {
      collectExprNames(lhs, acc, registry)
      collectExprNames(rhs, acc, registry)
    }
    case EAssign(target, _, value) -> {
      collectExprNames(target, acc, registry)
      collectExprNames(value, acc, registry)
    }
    case EBlock(block) -> collectBlockNames(block, acc, registry)
    case EUnsafe(block) -> collectBlockNames(block, acc, registry)
    case _ -> ()
  }
}

func collectExprListNames(exprs: in List[Expr], acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  var i = 0
  while i < exprs.count {
    collectExprNames(exprs[i], acc, registry)
    i = i + 1
  }
}

func collectExprOrBlockNames(eob: in ExprOrBlock, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  match eob {
    case EOBExpr(ex) -> collectExprNames(ex, acc, registry)
    case EOBBlock(b) -> collectBlockNames(b, acc, registry)
  }
}

func collectStmtNames(s: in Statement, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  match s.kind {
    case SLocal(binding) -> {
      match binding {
        case LBVal(_, _, init) -> collectExprNames(init, acc, registry)
        case LBLet(_, _, init) -> collectExprNames(init, acc, registry)
        case LBVar(_, _, init) -> {
          match init {
            case Some(ie) -> collectExprNames(ie, acc, registry)
            case None -> ()
          }
        }
      }
    }
    case SAssign(target, _, value) -> {
      collectExprNames(target, acc, registry)
      collectExprNames(value, acc, registry)
    }
    case SReturn(value) -> match value { case Some(v) -> collectExprNames(v, acc, registry); case None -> () }
    case SThrow(ex) -> collectExprNames(ex, acc, registry)
    case STry(body, catches, finally_) -> {
      collectBlockNames(body, acc, registry)
      var i = 0
      while i < catches.count {
        collectBlockNames(catches[i].body, acc, registry)
        i = i + 1
      }
      match finally_ {
        case Some(fb) -> collectBlockNames(fb, acc, registry)
        case None -> ()
      }
    }
    case SDefer(body) -> collectBlockNames(body, acc, registry)
    case SScope(_, body) -> collectBlockNames(body, acc, registry)
    case SFor(_, _, iter, body) -> {
      collectExprNames(iter, acc, registry)
      collectBlockNames(body, acc, registry)
    }
    case SWhile(_, cond, body) -> {
      collectExprNames(cond, acc, registry)
      collectBlockNames(body, acc, registry)
    }
    case SLoop(_, body) -> collectBlockNames(body, acc, registry)
    case SInvariant(ex) -> collectExprNames(ex, acc, registry)
    case SExpr(ex) -> collectExprNames(ex, acc, registry)
    case SRule(lhs, rhs) -> {
      collectExprNames(lhs, acc, registry)
      collectExprNames(rhs, acc, registry)
    }
    case SItem(it) -> match it.kind {
      // A nested function's body calls count toward the enclosing function for
      // reachability (the JVM lowers them into the same class either way).
      case IFunc(decl) -> match decl.body { case Some(fb) -> match fb { case FBExpr(ex) -> collectExprNames(ex, acc, registry); case FBBlock(b) -> collectBlockNames(b, acc, registry) }; case None -> () }
      case _ -> ()
    }
    case _ -> ()
  }
}

func collectBlockNames(b: in Block, acc: in List[String], registry: in Map[String, JvmFuncSig]): Unit {
  var i = 0
  while i < b.statements.count {
    collectStmtNames(b.statements[i], acc, registry)
    i = i + 1
  }
}

// Canonical registry keys (`owner/name`) of every Lyric function `decl`'s
// body calls.
func collectFuncCallKeys(decl: in FunctionDecl, registry: in Map[String, JvmFuncSig]): List[String] {
  val acc: List[String] = newList()
  match decl.body {
    case Some(fb) -> match fb { case FBExpr(ex) -> collectExprNames(ex, acc, registry); case FBBlock(b) -> collectBlockNames(b, acc, registry) }
    case None -> ()
  }
  acc
}

// Detect a derive-synthesised free-function name: `deriveFile` emits names of
// the form `TypeName.method` (e.g. `Point.equals`, `Color.show`), which always
// contain a dot.  Bare names (e.g. `classify`, `main`) are not derive-free.
func isDeriveFreeName(name: in String): Bool {
  Str.contains(name, ".")
}

// Register IFunc items whose name contains a "." — the `TypeName.method` form
// that `deriveFile` synthesises for `@derive(Equals/Show/Hash/Ord)` free
// functions (e.g. `Point.equals`, `Color.show`).  Called after `runMiddleEnd`
// to patch the registry built from the pre-derive `userFile` (#3139).
// Only processes new keys (first-wins guard, same as `collectFileSigs`).
func collectDeriveFreeSigs(
  file: in SourceFile, into: in Map[String, JvmFuncSig], externSeed: in Map[String, String]
): Unit {
  val owner = pkgJvmOwner(file.packageDecl.path)
  val externTypes = ownAwareExternTypes(file, externSeed)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if isDeriveFreeName(decl.name) {
          val params: List[JvmType] = newList()
          val paramNames: List[String] = newList()
          var pi = 0
          while pi < decl.params.count {
            params.add(typeExprToJvmExtern(decl.params[pi].ty, owner, externTypes))
            paramNames.add(decl.params[pi].name)
            pi = pi + 1
          }
          val ret = match decl.ret { case Some(te) -> typeExprToJvmExtern(te, owner, externTypes); case None -> JVoid }
          // paramDefaults intentionally empty: derive-synthesized free functions have
          // no default values.  Using an empty list avoids the stage-0 bootstrap
          // List[Option[Expr]] miscompile on .add() (#3139).
          val sig = JvmFuncSig(
            owner = owner,
            params = params,
            ret = ret,
            paramNames = paramNames,
            paramDefaults = newList(),
            paramModes = newList(),
            isIface = false,
            retGenericArgs = returnTypeGenericArgs(decl.ret),
            // Derive-synthesized free functions (`Point.equals`, `Color.show`)
            // never return a closure by construction — nothing to recover.
            closureRetTy = None,
            recordRetClass = None,
            // Derive-synthesized free functions never return `Self`.
            retIsSelf = false
          )
          val qkey = owner + "/" + decl.name
          if not into.containsKey(qkey) {
            into.add(qkey, sig)
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Detect an aspect-weave-synthesised function name.  `Lyric.Weaver` renames a
// matched target to `<name>__aspect_target` and emits intermediate wrappers
// `<name>__aspect_<AspectName>` (the outermost wrapper keeps the original
// name).  All carry the `__aspect_` infix; the original name does not.
func isAspectWovenName(name: in String): Bool {
  Str.contains(name, "__aspect_")
}

// Shared body for `collectAspectWovenSigs` / `collectBModeWovenSigs`: both
// walk a POST-middle-end file, pick out `IFunc` items whose name matches a
// synthesis-specific predicate, and register their sigs under both the bare
// and the qualified `owner/name` key (the callee is invoked unqualified —
// `proceed(args)` for aspects, the shared specialised function for B'-mode —
// so both keys must resolve to the same descriptor).  First-wins guard,
// matching `collectFileSigs`.
func collectWovenSigsMatching(
  file: in SourceFile, into: in Map[String, JvmFuncSig], matchName: in (String) -> Bool
): Unit {
  val owner = pkgJvmOwner(file.packageDecl.path)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if matchName(decl.name) {
          val params: List[JvmType] = newList()
          val paramNames: List[String] = newList()
          var pi = 0
          while pi < decl.params.count {
            params.add(typeExprToJvm(decl.params[pi].ty, owner))
            paramNames.add(decl.params[pi].name)
            pi = pi + 1
          }
          val ret = match decl.ret { case Some(te) -> typeExprToJvm(te, owner); case None -> JVoid }
          val sig = JvmFuncSig(
            owner = owner,
            params = params,
            ret = ret,
            paramNames = paramNames,
            paramDefaults = newList(),
            paramModes = newList(),
            isIface = false,
            retGenericArgs = returnTypeGenericArgs(decl.ret),
            // No `externTypes` available in this shared woven-sig path (aspect
            // target/wrapper and B'-mode specialisations); a closure-returning
            // woven function keeps the pre-fix Object-erased invoke result.
            closureRetTy = None,
            recordRetClass = None,
            // Aspect/B'-mode-woven free functions: no Self-return
            // substitution support in this synthesized-sig path (#6431 scopes
            // the checkcast narrowing to `registerInstanceSigErased`'s
            // impl/record/protected methods only) — conservative `false`
            // leaves any such call erased, same as before this fix.
            retIsSelf = false
          )
          val qkey = owner + "/" + decl.name
          if not into.containsKey(qkey) {
            into.add(qkey, sig)
          }
          if not into.containsKey(decl.name) {
            into.add(decl.name, sig)
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Register the sigs of aspect-weave-synthesised functions (`__aspect_target`
// renamed targets + intermediate `__aspect_<Aspect>` wrappers) from the
// POST-weave file, patching the registry built from the pre-weave `userFile`.
// `proceed(args)` lowers to an UNQUALIFIED call to the inner target, so both
// the bare name and the qualified `owner/name` key are registered (unlike
// `collectDeriveFreeSigs`, whose derive functions are only called qualified).
// Without this, the proceed call falls through to the `(…)Object` guess and
// the JVM rejects the descriptor mismatch (NoSuchMethodError / VerifyError) —
// the JVM analogue of the MSIL #3402 weave breakage.  The synthesised target /
// wrappers keep the original function's params and return type, so an empty
// `paramDefaults` is correct (the proceed substitution forwards every
// parameter positionally) and avoids the stage-0 bootstrap
// `List[Option[Expr]]` `.add()` miscompile (same rationale as
// `collectDeriveFreeSigs`).
func collectAspectWovenSigs(file: in SourceFile, into: in Map[String, JvmFuncSig]): Unit {
  collectWovenSigsMatching(file, into, { name -> isAspectWovenName(name) })
}

// Detect a B'-mode shape-keyed specialised function name (docs/55 §3.2):
// `Lyric.Weaver.buildBModeSpecializedFunction` names the shared function
// `__lyric_bmode_<templateKey>__<shapeKey>`.  Distinct from
// `isAspectWovenName`'s `__aspect_` infix and `isMonoSpecializedName`'s
// bare-`__` mono copies (both explicitly exclude the `__lyric_` prefix).
func isBModeSpecializedName(name: in String): Bool {
  Str.startsWith(name, "__lyric_bmode_")
}

// Register the sigs of B'-mode shape-keyed specialised functions
// (`__lyric_bmode_<template>__<shape>`) from the POST-weave file, patching
// the registry built from the pre-weave `userFile` (#4600).  Without this,
// the per-match wrapper's call to the shared specialised function
// (`Lyric.Weaver.buildBModeCallSite`'s `return <spec>(...)`) falls through
// to the `(…)Object` guess — the B'-mode analogue of the `__aspect_*` fix
// `collectAspectWovenSigs` applies for #3402.  The specialised function is
// called by BARE name (unqualified, same-package), so both the bare and the
// qualified `owner/name` key are registered, mirroring `collectAspectWovenSigs`.
func collectBModeWovenSigs(file: in SourceFile, into: in Map[String, JvmFuncSig]): Unit {
  collectWovenSigsMatching(file, into, { name -> isBModeSpecializedName(name) })
}

// Detect a monomorphizer-specialised function name.  `Lyric.Mono` mangles a
// specialised copy as `<base>__<T1>__<T2>` (`specFuncName`), so the name
// carries a `__` infix.  Aspect-weave names (`__aspect_` infix) and
// test-synth names (`__lyric_` prefix) also contain `__` but are handled by
// their own collectors / the pre-middle-end registry pass; exclude them so
// this stays the mono-only patch.
func isMonoSpecializedName(name: in String): Bool {
  Str.contains(name, "__") and not Str.contains(name, "__aspect_") and not Str.startsWith(name, "__lyric_")
}

// Register the sigs of monomorphizer-specialised functions (`mapKeys__String__Int`,
// `unwrapOr__Int`, …) from the POST-mono file, patching the registry built from
// the pre-middle-end sources (#3229).  Mono runs inside `runMiddleEnd`, after
// the bundle-wide `collectFileSigsSeeded` pass, so without this the specialised
// copies are emitted but their call sites resolve through the `(…)Object`
// guess — a descriptor mismatch that fails at class load (the #3676
// map-iteration symptom).  Specialised copies are called by bare name (the
// mono call-site rewrite is unqualified), so both the bare and the qualified
// `owner/name` key are registered — same rationale as `collectAspectWovenSigs`.
// Param/return types resolve through the file's extern types unioned with the
// imported `externSeed` (a specialised stdlib sig references `Map[..]` /
// `List[..]`, whose extern aliases live in `Std.CollectionsHost`).  Empty
// `paramDefaults` avoids the stage-0 bootstrap `List[Option[Expr]]` `.add()`
// miscompile (same rationale as `collectDeriveFreeSigs`); mono forwards every
// argument positionally, so defaults are never consulted at these call sites.
func collectMonoSpecializedSigs(
  file: in SourceFile,
  into: in Map[String, JvmFuncSig],
  externSeed: in Map[String, String],
): Unit {
  val owner = pkgJvmOwner(file.packageDecl.path)
  val externTypes = ownAwareExternTypes(file, externSeed)
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if isMonoSpecializedName(decl.name) {
          // Mono specialisations are fully concrete post-monomorphization
          // (no type params of their own remain to erase), but an `out`/
          // `inout` parameter still needs the holder-array descriptor
          // (`Counter` -> `Counter[]`) `holderAwareParamTypes` already gives
          // every OTHER registration path (`collectFileSigsSeeded` /
          // `registerFileSigs`, 06_items.l) — this hand-rolled loop skipped
          // it and always recorded plain (non-array) types plus an EMPTY
          // `paramModes`, so a call site to a specialised function with an
          // `out`/`inout` param (`cdTryGetValue[K, V]` and any other generic
          // helper wrapping an `out` parameter) never wrapped its holder
          // argument, producing a MemberRef with the wrong (non-array)
          // descriptor — `NoSuchMethodError` at runtime against the real,
          // correctly holder-typed specialised method (#3432).
          val params: List[JvmType] = holderAwareParamTypes(decl.params, owner, false, newList(), externTypes)
          val paramNames: List[String] = newList()
          val paramModes: List[ParamMode] = newList()
          var pi = 0
          while pi < decl.params.count {
            paramNames.add(decl.params[pi].name)
            paramModes.add(decl.params[pi].mode)
            pi = pi + 1
          }
          val ret = match decl.ret { case Some(te) -> typeExprToJvmExtern(te, owner, externTypes); case None -> JVoid }
          val sig = JvmFuncSig(
            owner = owner,
            params = params,
            ret = ret,
            paramNames = paramNames,
            paramDefaults = newList(),
            paramModes = paramModes,
            isIface = false,
            retGenericArgs = returnTypeGenericArgs(decl.ret),
            closureRetTy = closureRetTypeOf(decl.ret, owner, newList(), externTypes),
            // Same "no local-record scan available here" rationale as the
            // woven-sig path above (#6399): a mono-specialised function
            // returning a generic record keeps the pre-fix Object-erased
            // call-result type rather than risk resolving against the wrong
            // file's record set.
            recordRetClass = None,
            // Mono-specialised functions are free functions (monomorphized
            // from a generic `func`), never impl/record methods — no `Self`
            // return possible.
            retIsSelf = false
          )
          val qkey = owner + "/" + decl.name
          if not into.containsKey(qkey) {
            into.add(qkey, sig)
          }
          if not into.containsKey(decl.name) {
            into.add(decl.name, sig)
          }
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
}

// Back-compat forwarder: no feature flags, so no `@cfg` erasure runs.  Callers
// that thread a manifest's `[features]` table (the in-process CLI path) use
// `compileToJarBundledWithFeatures`.
pub func compileToJarBundled(
  source: in String,
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
  packageVersion: in String,
): Bool {
  val noFeatures: List[String] = newList()
  val noDepTemplateSrcs: List[String] = newList()
  val noDefines: List[String] = newList()
  compileToJarBundledWithFeatures(
    source,
    outputPath,
    packageName,
    stdlibSources,
    noFeatures,
    noFeatures,
    noDepTemplateSrcs,
    noDefines,
    packageVersion
  )
}

/// Like `compileToJarBundled` but threads `activeFeatures` / `declaredFeatures`
/// through `Lyric.Cfg.applyCfgErasure` before type-check (M-4; parity with the
/// MSIL bridge's `compileProjectToMsilWithFeatures`).  Items in the user package
/// annotated `@cfg(feature = "X")` where `X` is absent from `activeFeatures`
/// are erased; an annotation naming a feature absent from `declaredFeatures`
/// (when the declared set is non-empty) raises an `F0013` typo warning.
/// `depTemplateSrcs` is a list of source strings from path-dependency packages;
/// each is parsed and its `pub aspect` templates are collected into the weave
/// map so that `from`-instance aspects can resolve cross-package templates
/// (parity with the MSIL bridge's `depTemplatePkgs`).
pub func compileToJarBundledWithFeatures(
  source: in String,
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  depTemplateSrcs: in List[String],
  defines: in List[String],
  packageVersion: in String,
): Bool {
  val noRestored: List[SynthesisedArtifact] = newList()
  compileToJarBundledWithRestored(
    source,
    outputPath,
    packageName,
    stdlibSources,
    activeFeatures,
    declaredFeatures,
    depTemplateSrcs,
    defines,
    packageVersion,
    noRestored
  )
}

/// Like `compileToJarBundledWithFeatures` but accepts a list of restored-
/// dependency `SynthesisedArtifact`s (#3094) — the JVM analog of the MSIL
/// bridge's `compileProjectToMsilWithRestored`.  Each restored artifact's
/// re-synthesised source (`Lyric.RestoredPackages.synthesiseArtifact`,
/// already loaded and preamble-checked by the caller — see
/// `Lyric.Emitter.emitProjectJvmInProcess`, which reads them from a JAR's
/// embedded `Lyric.Contract.<Pkg>` ZIP entries via
/// `Lyric.RestoredPackages.loadRestoredPackageJvm`) is registered into the
/// SAME cross-package signature/case/ctor registries a stdlib or sibling
/// project file feeds — see `compileProjectToJarBundledWithRestored` for
/// the registration design and why no codegen runs over it.
pub func compileToJarBundledWithRestored(
  source: in String,
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  depTemplateSrcs: in List[String],
  defines: in List[String],
  packageVersion: in String,
  restoredArtifacts: in List[SynthesisedArtifact],
): Bool {
  val one: List[String] = newList()
  one.add(source)
  compileProjectToJarBundledWithRestored(
    one,
    outputPath,
    packageName,
    stdlibSources,
    activeFeatures,
    declaredFeatures,
    depTemplateSrcs,
    defines,
    packageVersion,
    restoredArtifacts
  )
}

// True when the file declares a top-level `func main` — the project entry
// package marker for multi-package JVM builds.
func fileHasTopLevelMain(file: in SourceFile): Bool {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> {
        if decl.name == "main" {
          return true
        }
      }
      case _ -> ()
    }
    i = i + 1
  }
  false
}

/// Multi-package JVM project build (the manifest path, #2669 J6): compiles
/// every project package plus the transitive stdlib-import closure into one
/// runnable JAR, in process.  `pkgSrcs` carries one merged source per
/// project package; the entry package is the one declaring a top-level
/// `func main` (first package when none does — `lyric test` synthesises its
/// runner main into the test package).  Sibling packages ride the same
/// bundling machinery as stdlib packages — same registries, call-graph
/// reachability, middle end, and codegen — with two deliberate differences:
/// their parse / cfg / middle-end diagnostics are FATAL (they are the
/// user's own code, not advisory stdlib noise), and a codegen failure in
/// one is always a build error (never a J003 silent skip).
///
/// This retires the `--internal-project-build` subprocess hop for the JVM
/// target: the previous `emitProjectJvmViaSubprocess` path re-entered
/// `emitProject` in the child with the same multi-package request, which
/// re-spawned the subprocess — an unbounded process loop, masked only
/// because no multi-package JVM manifest build had been exercised
/// end-to-end before.
pub func compileProjectToJarBundledWithFeatures(
  pkgSrcs: in List[String],
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  depTemplateSrcs: in List[String],
  defines: in List[String],
  packageVersion: in String,
): Bool {
  val noRestored: List[SynthesisedArtifact] = newList()
  compileProjectToJarBundledWithRestored(
    pkgSrcs,
    outputPath,
    packageName,
    stdlibSources,
    activeFeatures,
    declaredFeatures,
    depTemplateSrcs,
    defines,
    packageVersion,
    noRestored
  )
}

/// Like `compileProjectToJarBundledWithFeatures` but accepts a list of
/// restored-dependency `SynthesisedArtifact`s (#3094): the consumer's `import
/// <RestoredPkg>` resolves generic (and non-generic) records, unions, and
/// functions declared by a pre-compiled Lyric-JVM producer JAR — the JVM
/// counterpart of #1496 / D097's MSIL restored-generics fix.
///
/// Design (JVM's type-erasure model makes this substantially simpler than
/// the MSIL side, which needs arity-suffixed TypeRefs and VAR-form generic
/// metadata maps): each restored artifact's re-synthesised `SourceFile`
/// (`Lyric.RestoredPackages.synthesiseArtifact`; its record/union/function
/// declarations are reconstructed, verbatim, from the producer's embedded
/// contract JSON) is fed through the SAME `collectFileSigsSeeded` /
/// `collectFileCasesExtern` / `collectFileCtors` / `collectFileProjectables`
/// registration calls a stdlib or sibling project file gets — a generic
/// record/union's fields already erase to `Object` uniformly (JVM has no
/// reified generics to preserve), so no separate arity-suffixed class-name
/// bookkeeping is needed the way MSIL's `genericTypeArity` /
/// `genericCtorParams` / `fieldSigBytes` / `fieldVarIndices` maps require.
///
/// Critically, a restored artifact's file is registered into `registry` /
/// `caseReg` / `ctorReg` / `allProjFqns` but is deliberately NEVER added to
/// `stdlibFiles` / `stdlibByPkg` / `toBundle`: its bytecode already exists in
/// the producer JAR, so codegen must never re-emit (and thus duplicate) it —
/// only its call-site SIGNATURES need to be known here.  The producer JAR's
/// own path is threaded onto the consumer's manifest `Class-Path:` (the same
/// mechanism `autoFfi.jarPaths` already uses for Maven/non-JDK JARs) so the
/// JVM classloader can actually find those classes at runtime.
pub func compileProjectToJarBundledWithRestored(
  pkgSrcs: in List[String],
  outputPath: in String,
  packageName: in String,
  stdlibSources: in List[String],
  activeFeatures: in List[String],
  declaredFeatures: in List[String],
  depTemplateSrcs: in List[String],
  defines: in List[String],
  packageVersion: in String,
  restoredArtifacts: in List[SynthesisedArtifact],
): Bool {
  if pkgSrcs.count == 0 {
    Console.error("error[J001]: JVM project build received no packages")
    return false
  }
  // Parse every project package (fatal diagnostics), then run the user
  // pre-passes on each: `@cfg` erasure, alias rewrite, `@stubbable`
  // synthesis, weave-import injection.  `injectWeaveImports` must run
  // before the transitive import-closure walk below so that an aspect
  // referencing `call.elapsed` (#1298) gets `Std.Time` bundled into the
  // JAR for the `monotonicNanos` calls the weave synthesises later in
  // `runMiddleEnd`.
  val userFiles: List[SourceFile] = newList()
  var mainIdx = 0
  var sawMain = false
  // Resolved `--define`s (docs/60), decoded once — hoisted out of the
  // per-package loop since it never varies (#5906). Populated for both
  // single-file and project JVM builds: `emitProjectJvmInProcess` threads
  // `req.defines` (merged beneath the well-known `version`) into this project
  // path, matching the single-file path (#5852).
  val jvmProjDefines = BD.decodeDefines(defines)
  var psi = 0
  while psi < pkgSrcs.count {
    val uf = match pipeParseAndErase(pkgSrcs[psi], "jvm", activeFeatures, declaredFeatures, jvmProjDefines) {
      case Some(f) -> f
      case None -> return false
    }
    if not sawMain and fileHasTopLevelMain(uf) {
      mainIdx = psi
      sawMain = true
    }
    userFiles.add(uf)
    psi = psi + 1
  }

  // docs/58 (D121): collect wire/config templates across every project
  // package and path-dependency source package, then expand each project
  // file before anything downstream indexes it — parity with the MSIL
  // bridge's project path.  Expansion runs BEFORE the alias/stubbable
  // rewrites so an include alias's qualified access (`Core.router`) is
  // consumed by the expander rather than collapsed by the import-alias
  // rewriter when the alias name matches an imported package's last
  // segment; the standard rewrite chain is applied to the expanded file.
  // #6505: collect from ALIAS-REWRITTEN copies (collection-only; the
  // rewritten file is discarded — see the MSIL bridge's note) so template bodies'
  // references through the SOURCE file's import aliases splice into
  // consumers fully qualified — see the MSIL bridge's matching comment
  // (rewriteWireDecl's #6316 include-alias exclusion makes this safe
  // against the expansion-first ordering concern).  The files EXPANDED
  // below stay the un-rewritten originals.
  val weWires: Map[String, CollectedWireTemplate] = newMap()
  val weConfigs: Map[String, CollectedConfigTemplate] = newMap()
  var wti = 0
  while wti < userFiles.count {
    WireExpand.collectWireTemplates(
      Aliases.rewriteFile(userFiles[wti]).items,
      dottedPath(userFiles[wti].packageDecl.path),
      weWires,
      weConfigs
    )
    wti = wti + 1
  }
  var wtd = 0
  while wtd < depTemplateSrcs.count {
    val wdtPr = parse(depTemplateSrcs[wtd])
    WireExpand.collectWireTemplates(
      Aliases.rewriteFile(wdtPr.file).items,
      dottedPath(wdtPr.file.packageDecl.path),
      weWires,
      weConfigs
    )
    wtd = wtd + 1
  }
  var wei = 0
  while wei < userFiles.count {
    val rewritten = match pipeExpandAndRewrite(userFiles[wei], weWires, weConfigs, true, true, true) {
      case Some(f) -> f
      case None -> return false
    }
    // #6404: resolve every project package's `alias X = ...` references
    // before ANYTHING (type-check, signature/case/ctor registration below,
    // codegen) reads the file — see `resolveTypeAliases`'s comment.
    userFiles[wei] = resolveTypeAliases(rewritten)
    wei = wei + 1
  }
  val userFile = userFiles[mainIdx]
  match mainReturns2SlotType(userFile) {
    case Some(ty) -> {
      Console.error("error[J001]: `func main(): " + ty + "` is not supported on the JVM target")
      Console.error("  hint: use `func main(): Int` (exit code) or `func main(): Unit`")
      return false
    }
    case None -> ()
  }

  // Parse every stdlib source once: collect its type items (for cross-package
  // type resolution) and index the whole file by dotted package name (for the
  // import-closure walk below).
  // Type items grouped by declaring package (see `compileToJar` for the
  // RegexError collision this scope-aware grouping fixes).
  val importedPkgs: List[ImportedPackage] = newList()
  // #6024: the entry package (`userFile`, `pkgSrcs[0]`) must ALSO contribute
  // its own cross-package items here, exactly like every stdlib file (below)
  // and every non-entry sibling package (further below) already does.
  // Before this, a sibling package importing the entry package's types
  // — e.g. a manifest declaring `"Web" = "src/web.l"` first and
  // `"Web.Kernel.Runtime" = [...]` second, where the kernel imports `Web`
  // for `Request`/`Response`/`Router` (a legitimate same-manifest import
  // cycle: `Web` imports the kernel back for `serve`) — saw the entry
  // package's public types as entirely unknown (`error[T0014] unknown
  // qualified type 'Web.Request'`), even though every OTHER project package
  // resolves fine and the single-file bundled JVM build (which folds the
  // whole transitive import closure into one flat registry, entry package
  // included) handles the identical cycle correctly. `--target dotnet` was
  // unaffected: `Msil.Bridge`'s `perPackageImportedPackages` walks each
  // package's own transitive in-bundle closure from a full `inBundleItems`
  // map that always includes the entry package. This mirrors that by
  // seeding the entry package into the SAME flat `importedPkgs` list this
  // bridge already unions across every other package — sufficient here
  // because every package's `runMiddleEnd` call below consults the full
  // flat list, not a per-package reachability walk.
  val userEntryPkgName = dottedPath(userFile.packageDecl.path)
  val userEntryItems: List[Item] = newList()
  var uei = 0
  while uei < userFile.items.count {
    if pipeIsCrossPackageItem(userFile.items[uei]) {
      userEntryItems.add(userFile.items[uei])
    }
    uei = uei + 1
  }
  importedPkgs.add(
    ImportedPackage(name = userEntryPkgName, items = userEntryItems, imports = collectImportNames(userFile.imports))
  )
  val stdlibFiles: List[SourceFile] = newList()
  val stdlibByPkg: Map[String, SourceFile] = newMap()
  var si = 0
  while si < stdlibSources.count {
    val pr = parse(stdlibSources[si])
    // Stdlib parse diagnostics are advisory and never gate the bundle (only the
    // user file's parse and the per-package codegen are fatal).  Echoing them
    // here leaked self-hosted-parser-gap noise (e.g. `spawn`/`var` keyword
    // P0051s from std/process.l) onto every successful JVM build's output;
    // suppress it so a clean build stays clean.
    //
    // The alias rewrite must run here — before registry collection, the
    // call-graph walk, and codegen all consume the file — so that a
    // stdlib package calling its kernel through an aliased import
    // (`import Std.CharHost as Host` → `Host.hostIsLetter(c)`) resolves
    // like an unaliased call.  Without it every such call fell through
    // to the instance-FFI guess and the whole package was silently
    // J003-skipped (Std.Char and Std.Parse — and with them every JVM
    // consumer of char classification and string→number parsing).
    val prFile = Aliases.rewriteFile(pr.file)
    val pkgItems: List[Item] = newList()
    var ii = 0
    while ii < prFile.items.count {
      if pipeIsCrossPackageItem(prFile.items[ii]) {
        pkgItems.add(prFile.items[ii])
      }
      ii = ii + 1
    }
    val pn = dottedPath(prFile.packageDecl.path)
    importedPkgs.add(ImportedPackage(name = pn, items = pkgItems, imports = collectImportNames(prFile.imports)))
    stdlibFiles.add(prFile)
    if pn.length > 0 and not stdlibByPkg.containsKey(pn) {
      stdlibByPkg.add(pn, prFile)
    }
    si = si + 1
  }

  // Sibling project packages join the same bundle structures as stdlib
  // files: the import-closure walk resolves `import <Sibling>` through
  // `stdlibByPkg`, and every downstream loop (extern seeds, registries,
  // generic-func collection, aspect templates, per-package codegen)
  // iterates `stdlibFiles`.  `projectOwners` marks their JVM owners so the
  // bundle loop treats them as the user's own code: middle-end diagnostics
  // and codegen failures are always fatal (never the stdlib J003 skip),
  // and their type-check advisories are echoed.
  val projectOwners: Map[String, Bool] = newMap()
  var svi = 0
  while svi < userFiles.count {
    if svi != mainIdx {
      val sf = userFiles[svi]
      val spn = dottedPath(sf.packageDecl.path)
      val sItems: List[Item] = newList()
      var sii = 0
      while sii < sf.items.count {
        if pipeIsCrossPackageItem(sf.items[sii]) {
          sItems.add(sf.items[sii])
        }
        sii = sii + 1
      }
      importedPkgs.add(ImportedPackage(name = spn, items = sItems, imports = collectImportNames(sf.imports)))
      stdlibFiles.add(sf)
      if spn.length > 0 and not stdlibByPkg.containsKey(spn) {
        stdlibByPkg.add(spn, sf)
      }
      projectOwners.add(pkgJvmOwner(sf.packageDecl.path), true)
    }
    svi = svi + 1
  }

  // Extern-type map per parsed package (parallel lists), so signatures and
  // descriptors written against an imported extern type resolve through
  // `externSeedForFile` (e.g. `Std.Time`'s `Instant` from `Std.TimeHost`).
  val extPkgNames: List[String] = newList()
  val extPkgMaps: List[Map[String, String]] = newList()
  extPkgNames.add(dottedPath(userFile.packageDecl.path))
  val userExtMap = collectExternTypesFromFile(userFile)
  // Also expose each package's non-generic declared Lyric types (dotted
  // FQNs, same value format) so importing files' descriptors name the real
  // class — extern declarations win on name collision (registered first).
  collectFileDeclaredTypeFqns(userFile, userExtMap)
  extPkgMaps.add(userExtMap)
  var xi = 0
  while xi < stdlibFiles.count {
    extPkgNames.add(dottedPath(stdlibFiles[xi].packageDecl.path))
    val xExtMap = collectExternTypesFromFile(stdlibFiles[xi])
    collectFileDeclaredTypeFqns(stdlibFiles[xi], xExtMap)
    extPkgMaps.add(xExtMap)
    xi = xi + 1
  }
  // #6668: a restored dependency (#3094) is a real OWNING package too — its
  // non-generic declared types (and any extern-type aliases its own kernel
  // declares) must join the SAME extPkgNames/extPkgMaps pair userFile and
  // every stdlib file feed above, BEFORE any `externSeedForFile` call runs
  // below.  Without this, a consumer function signature naming a restored
  // type (`func consume(x: RestoredPkg.SomeRecord)`) has no way to resolve
  // `SomeRecord`'s owning package: `externSeedForFile` finds no entry for
  // it in either the bare or `<pkg>.<name>`-qualified form, so the
  // descriptor falls back to the "declared in my own package" guess — a
  // wrong-owner descriptor that mismatches the producer JAR's real class at
  // the call boundary (`NoSuchMethodError` at runtime, never a build-time
  // failure).
  var rpi0 = 0
  while rpi0 < restoredArtifacts.count {
    val raFile = restoredArtifacts[rpi0].source
    extPkgNames.add(restoredArtifacts[rpi0].packageName)
    val raExtMap = collectExternTypesFromFile(raFile)
    collectFileDeclaredTypeFqns(raFile, raExtMap)
    extPkgMaps.add(raExtMap)
    rpi0 = rpi0 + 1
  }

  // Build the cross-package call registry across the user file and *every*
  // stdlib file (resolution is cheap and harmless for packages we don't bundle).
  val registry: Map[String, JvmFuncSig] = newMap()
  collectFileSigsSeeded(userFile, registry, externSeedForFile(userFile, extPkgNames, extPkgMaps))
  val caseReg: Map[String, List[JvmCaseField]] = newMap()
  // Field types resolve through own + imported extern types so a field like
  // `FileStat.modifiedAt: FileTime` registers the real JVM class.
  collectFileCasesExtern(
    userFile,
    caseReg,
    ownAwareExternTypes(userFile, externSeedForFile(userFile, extPkgNames, extPkgMaps))
  )
  val ctorReg: Map[String, String] = newMap()
  collectFileCtors(userFile, ctorReg)
  // #3044: complete @projectable pre-scan across the whole compilation, so
  // nested-view substitution / tryInto() eligibility see every projectable
  // regardless of declaration or package order (JVM counterpart of the MSIL
  // `prescanProjectableFqns`).
  val allProjFqns: Map[String, Bool] = newMap()
  collectFileProjectables(userFile, allProjFqns)
  var ri = 0
  while ri < stdlibFiles.count {
    collectFileSigsSeeded(stdlibFiles[ri], registry, externSeedForFile(stdlibFiles[ri], extPkgNames, extPkgMaps))
    collectFileCasesExtern(
      stdlibFiles[ri],
      caseReg,
      ownAwareExternTypes(stdlibFiles[ri], externSeedForFile(stdlibFiles[ri], extPkgNames, extPkgMaps))
    )
    collectFileCtors(stdlibFiles[ri], ctorReg)
    collectFileProjectables(stdlibFiles[ri], allProjFqns)
    ri = ri + 1
  }

  // ── Restored-dependency registration (#3094) ──────────────────────────
  // See `compileProjectToJarBundledWithRestored`'s doc comment for the full
  // design.  Each restored artifact's synthesised source registers into the
  // same registries the stdlib loop above just populated, AND joins
  // `importedPkgs` so the TYPE CHECKER (not just codegen) resolves
  // `import <RestoredPkg>` — a plain codegen-only registration still left
  // every restored type/function an "unknown name"/"unknown type name" at
  // type-check, since `Lyric.TypeChecker.checkFile` resolves imports purely
  // from `importedPkgs`.  The producer JAR's own path (deduplicated) rides
  // the manifest `Class-Path:` below alongside `autoFfi.jarPaths`, since the
  // restored classes are never re-emitted into THIS jar's bytecode.
  val restoredJarPathsSeen: Map[String, Bool] = newMap()
  val restoredJarPaths: List[String] = newList()
  var rai = 0
  while rai < restoredArtifacts.count {
    val synArt = restoredArtifacts[rai]
    val rf = synArt.source
    // #6668: seed through the SAME `extPkgNames`/`extPkgMaps` pair (now
    // including every restored artifact, registered above) that userFile
    // and every stdlib file use — an empty seed here left the restored
    // file's OWN signatures unable to resolve types from sibling restored
    // packages, extern kernels, or stdlib.
    collectFileSigsSeeded(rf, registry, externSeedForFile(rf, extPkgNames, extPkgMaps))
    collectFileCasesExtern(rf, caseReg, ownAwareExternTypes(rf, externSeedForFile(rf, extPkgNames, extPkgMaps)))
    collectFileCtors(rf, ctorReg)
    collectFileProjectables(rf, allProjFqns)
    val rPkgItems: List[Item] = newList()
    var rii = 0
    while rii < rf.items.count {
      if pipeIsCrossPackageItem(rf.items[rii]) {
        rPkgItems.add(rf.items[rii])
      }
      rii = rii + 1
    }
    importedPkgs.add(
      ImportedPackage(name = synArt.packageName, items = rPkgItems, imports = collectImportNames(rf.imports))
    )
    if not restoredJarPathsSeen.containsKey(synArt.dllPath) {
      restoredJarPathsSeen.add(synArt.dllPath, true)
      restoredJarPaths.add(synArt.dllPath)
    }
    rai = rai + 1
  }

  // View-twin registration must run after the pre-scan is complete (the
  // substituted view field types depend on the full projectable set).
  registerProjectableViews(userFile, allProjFqns, caseReg, registry)
  var rvi = 0
  while rvi < stdlibFiles.count {
    registerProjectableViews(stdlibFiles[rvi], allProjFqns, caseReg, registry)
    rvi = rvi + 1
  }

  // Transitive import closure: the stdlib packages whose bytecode must be
  // bundled because the user (directly or indirectly) imports them.
  val toBundle: List[SourceFile] = newList()
  val seen: Map[String, Bool] = newMap()
  val worklist: List[String] = newList()
  var ui = 0
  while ui < userFile.imports.count {
    worklist.add(dottedPath(userFile.imports[ui].path))
    ui = ui + 1
  }
  var wi = 0
  while wi < worklist.count {
    val pkg = worklist[wi]
    wi = wi + 1
    if not seen.containsKey(pkg) {
      seen.add(pkg, true)
      match mapGet(stdlibByPkg, pkg) {
        case Some(f) -> {
          toBundle.add(f)
          var fi = 0
          while fi < f.imports.count {
            worklist.add(dottedPath(f.imports[fi].path))
            fi = fi + 1
          }
        }
        case None -> ()
        // Genuinely unreached / unavailable: a builtin head (`Std.*`
        // resolved by the emitter, `Lyric.*` compiler packages) or a
        // package with no in-bundle source.  Nothing to bundle, so no
        // codegen runs for it and a failure can never be masked here.
        // This `None` arm is the only "skip" path; every package that
        // *does* have source is bundled and its codegen failure is fatal.
      }
    }
  }

  // ── Call-reachability fixpoint (J1 B-6, #2664) ──────────────────────────
  // Build a function-level call graph over the user package plus every bundled
  // package: each function's canonical key (`owner/name`) maps to the keys of
  // the functions it calls.  Mark every function in the *user* package as a
  // root (entry points — `main`, the synthesised `lyric test` runners) and
  // close the reachable set transitively.  A bundled package is "referenced"
  // iff at least one of its declared functions is reachable; only those are
  // fatal-on-codegen-failure.  This matches the JVM's lazy per-method linking:
  // a never-invoked sibling function (e.g. `Std.Hash.sha512OfFile` pulling in
  // `Std.FileHost` when only `sha512OfBytes` is called) does not make its
  // callee package "referenced".
  val callGraph: Map[String, List[String]] = newMap()
  val reachableFns: Map[String, Bool] = newMap()
  val fnWorklist: List[String] = newList()

  // User package: every top-level function is a root.  Aspect `around`
  // bodies are roots too: the call graph is built on the PRE-weave file,
  // but the weave inlines each advice body into user-package wrappers,
  // so its callees (e.g. the `Std.Time.monotonicNanos` calls the
  // `call.elapsed` instrumentation synthesises, #1298) execute from the
  // user package.  Without this, a stdlib package used only by woven
  // advice is bundled but never marked reachable, downgrading its
  // codegen failure to a silent skip and the build error to a runtime
  // NoClassDefFoundError.
  val userOwner = pkgJvmOwner(userFile.packageDecl.path)
  var gi = 0
  while gi < userFile.items.count {
    match userFile.items[gi].kind {
      case IFunc(decl) -> {
        val selfKey = userOwner + "/" + decl.name
        if not callGraph.containsKey(selfKey) {
          callGraph.add(selfKey, collectFuncCallKeys(decl, registry))
        }
        if not reachableFns.containsKey(selfKey) {
          reachableFns.add(selfKey, true)
          fnWorklist.add(selfKey)
        }
      }
      case IAspect(aspDecl) -> {
        match aspDecl.around {
          case Some(ar) -> {
            val adviceCallees: List[String] = newList()
            collectBlockNames(ar.body, adviceCallees, registry)
            var aci = 0
            while aci < adviceCallees.count {
              val callee = adviceCallees[aci]
              if not reachableFns.containsKey(callee) {
                reachableFns.add(callee, true)
                fnWorklist.add(callee)
              }
              aci = aci + 1
            }
          }
          case None -> ()
        }
      }
      case _ -> ()
    }
    gi = gi + 1
  }
  // `call.elapsed` instrumentation calls `Std.Time.monotonicNanos` from
  // the woven wrappers; the synthesised calls don't exist in the
  // pre-weave advice bodies, so seed the root explicitly when any
  // aspect references the field (#1298).
  if Weaver.weaveNeedsStdTime(userFile) {
    val monoKey = "Std/Time/monotonicNanos"
    if registry.containsKey(monoKey) and not reachableFns.containsKey(monoKey) {
      reachableFns.add(monoKey, true)
      fnWorklist.add(monoKey)
    }
  }

  // Bundled packages: index their functions' outgoing calls (not roots).
  var bgi = 0
  while bgi < toBundle.count {
    val bf = toBundle[bgi]
    val bOwner = pkgJvmOwner(bf.packageDecl.path)
    var bii = 0
    while bii < bf.items.count {
      match bf.items[bii].kind {
        case IFunc(decl) -> {
          val selfKey = bOwner + "/" + decl.name
          if not callGraph.containsKey(selfKey) {
            callGraph.add(selfKey, collectFuncCallKeys(decl, registry))
          }
        }
        case _ -> ()
      }
      bii = bii + 1
    }
    bgi = bgi + 1
  }

  // Transitive closure over the call graph.
  var wfi = 0
  while wfi < fnWorklist.count {
    val cur = fnWorklist[wfi]
    wfi = wfi + 1
    match mapGet(callGraph, cur) {
      case Some(callees) -> {
        var ci = 0
        while ci < callees.count {
          val callee = callees[ci]
          if not reachableFns.containsKey(callee) {
            reachableFns.add(callee, true)
            fnWorklist.add(callee)
          }
          ci = ci + 1
        }
      }
      case None -> ()
    }
  }

  // A bundled package is referenced iff one of its functions is reachable.
  val referencedPkgs: Map[String, Bool] = newMap()
  var rpi = 0
  while rpi < toBundle.count {
    val rf = toBundle[rpi]
    val rOwner = pkgJvmOwner(rf.packageDecl.path)
    if not referencedPkgs.containsKey(rOwner) {
      var rii = 0
      var anyReachable = false
      while rii < rf.items.count {
        match rf.items[rii].kind {
          case IFunc(decl) -> {
            if reachableFns.containsKey(rOwner + "/" + decl.name) {
              anyReachable = true
            }
          }
          case _ -> ()
        }
        rii = rii + 1
      }
      if anyReachable {
        referencedPkgs.add(rOwner, true)
      }
    }
    rpi = rpi + 1
  }

  val autoFfi = buildAutoFfiCtx()
  val allClasses: List[BuiltClass] = newList()
  // Every PROJECT package's `Lyric.Contract.<Pkg>` JAR resource (#4994) —
  // stdlib/dependency packages merely bundled for their bytecode are NOT
  // included, matching `Msil.Bridge`'s `embedLyricContract` scope (only
  // `perPkgFiles`, the project's own packages, ever get a contract
  // resource). For a stdlib-as-project build (`lyric build --manifest
  // lyric-stdlib/lyric.toml --target jvm`) every stdlib package IS a
  // project package, so this is exactly what produces `Lyric.Stdlib.Jvm.jar`'s
  // embedded metadata.
  val contractEntryNames: List[String] = newList()
  val contractEntryDatas: List[List[Byte]] = newList()
  // Hoisted above the codegen loops (rather than computed once right before
  // `writeJarFromClasses` at the very end, as `compileToJar` does) because
  // the contract-building calls below need it too. Empty `packageVersion`
  // falls back to the legacy "0.1.0" default (matches `compileToJar`, #5834).
  val jarVersion = if packageVersion.length == 0 { "0.1.0" } else { packageVersion }

  // Stdlib pure-Lyric generic `pub func`s, fed to each package's monomorphizer
  // so cross-package generic calls (`mapGet`, `unwrapOr`, …) specialise into
  // this bundle instead of erasing their generic return (M-5; parity with the
  // MSIL bridge's `collectStdlibGenericFuncs`).
  val stdlibGenFuncs = collectStdlibGenericFuncsJvm(stdlibFiles)

  // Collect cross-package aspect templates from every file in the bundle before
  // the weave loop so that from-instance aspects in any package can resolve
  // their template body (#3414; parity with the MSIL bridge).
  val allTemplates: Map[String, CollectedTemplate] = newMap()
  Weaver.collectAspectTemplates(userFile.items, dottedPath(userFile.packageDecl.path), allTemplates)
  var ati = 0
  while ati < toBundle.count {
    val tf = toBundle[ati]
    Weaver.collectAspectTemplates(tf.items, dottedPath(tf.packageDecl.path), allTemplates)
    ati = ati + 1
  }
  // Collect templates from path-dependency source files passed by the caller
  // (parity with the MSIL bridge's depTemplatePkgs loop).  For single-file
  // JVM builds (emitJvmInProcess) this list is empty; JVM project builds that
  // route through the self-hosted bridge will populate it when that path lands.
  var dti = 0
  while dti < depTemplateSrcs.count {
    val dtPr = parse(depTemplateSrcs[dti])
    // #6351/#6504: collapse import aliases (explicit `as` and implicit
    // tail-segment) to full package FQNs before collecting, so template
    // bodies spliced into consumer packages resolve without the
    // dependency's own imports — parity with the MSIL bridge's
    // depTemplatePkgs loop and with every in-bundle file (rewritten via
    // `pipeExpandAndRewrite` before collection).
    val dtRewritten = Aliases.rewriteFile(dtPr.file)
    Weaver.collectAspectTemplates(dtRewritten.items, dottedPath(dtRewritten.packageDecl.path), allTemplates)
    dti = dti + 1
  }

  // User package first (its codegen failing is always fatal).  Its type-check
  // errors gate fatally (they are about the program the user actually wrote).
  match runMiddleEnd(userFile, importedPkgs, stdlibGenFuncs, allTemplates, true, "") {
    case Some(f) -> {
      // Register sigs synthesised by `deriveFile` (inside `runMiddleEnd`) so
      // that call-site resolution in `codegenPackageInto` can find them.  The
      // `collectFileSigs(userFile, registry)` above ran on the pre-derive file
      // and therefore missed free functions like `Point.equals` / `Color.show`,
      // causing the call sites to fall through to the `invokevirtual Object`
      // guess — a NoSuchMethodError at runtime (#3139).
      // Use the narrow `collectDeriveFreeSigs` (only `.`-named items) rather
      // than the full `collectFileSigs` to avoid the stage-0 bootstrap
      // List[Option[Expr]] miscompile on paramDefaults.add().
      collectDeriveFreeSigs(f, registry, externSeedForFile(f, extPkgNames, extPkgMaps))
      // Register aspect-weave-synthesised targets / wrappers (`__aspect_*`)
      // from the post-weave file so the `proceed(args)` call resolves to the
      // real descriptor instead of the `(…)Object` guess (#3402, JVM analogue).
      collectAspectWovenSigs(f, registry)
      // Register B'-mode shape-keyed specialised functions (`__lyric_bmode_*`,
      // docs/55) from the post-weave file so a per-match wrapper's call to the
      // shared specialised function resolves to the real descriptor (#4600).
      collectBModeWovenSigs(f, registry)
      // Register monomorphizer-specialised copies (`mapKeys__String__Int`, …)
      // from the post-mono file so their call sites resolve to the real
      // descriptor (#3229; the #3676 map-iteration symptom).
      collectMonoSpecializedSigs(f, registry, externSeedForFile(f, extPkgNames, extPkgMaps))
      // Register weaver-synthesised record fields (`__LyricBModeCallContext`,
      // `__LyricBModeCfg_*`, `__LyricBModeArgs_*`, docs/55/56) from the
      // post-weave file: `caseReg` above was built from the pre-weave
      // `userFile`, so these types are absent and a `config.<field>` /
      // row-typed `args.<field>` read inside the shared specialised function
      // panics with "has no known field or member" (#4600).
      // `collectFileCasesExtern` first-wins-guards on `into.containsKey`, so
      // re-running it over the whole post-weave file is a safe additive scan.
      collectFileCasesExtern(f, caseReg, externSeedForFile(f, extPkgNames, extPkgMaps))
      // Register the SAME weaver-synthesised records as constructable types
      // (`new + invokespecial <init>` instead of the plain-function-call
      // guess) — `ctorReg` above was ALSO built from the pre-weave `userFile`
      // and misses `__LyricBModeCallContext(...)` construction at the B'-mode
      // call site, producing a NoSuchMethodError for a phantom static method
      // (#4600).  `collectFileCtors` first-wins-guards the same way.
      collectFileCtors(f, ctorReg)
      val (fContractName, fContractData) = contractZipEntry(userFile, f, dottedPath(f.packageDecl.path), jarVersion)
      contractEntryNames.add(fContractName)
      contractEntryDatas.add(fContractData)
      codegenPackageInto(
        f,
        registry,
        caseReg,
        ctorReg,
        autoFfi,
        allProjFqns,
        allClasses,
        externSeedForFile(f, extPkgNames, extPkgMaps)
      )
    }
    case None -> return false
  }

  // For every bundled package, a codegen failure is **fatal** when the package
  // is call-reachable — i.e. the program actually invokes one of its functions
  // — because the resulting JAR would otherwise throw NoSuchMethodError at
  // runtime instead of failing the build.  The catch surfaces the panic's
  // message, which names the failing symbol / declaration / construct (e.g.
  // "Jvm.Codegen: EForall not supported in JVM codegen"), so the build points at
  // the exact lowering gap.  A package that is imported only for its types (or
  // dead-imported) and never called is *not* call-reachable: its bytecode is
  // never invoked, so a codegen failure for it is skipped silently.  Bundled
  // packages pass `reportTcAdvisories = false`: their advisory type-check noise
  // (the self-hosted checker lacks full builtin coverage) is suppressed so a
  // successful build does not print self-hosted-coverage-gap noise from
  // unrelated stdlib code.  Real errors still surface — referenced-package
  // codegen panics are echoed via the fatal J002 path below.
  var bi = 0
  var skippedCount = 0
  val skippedNames: List[String] = newList()
  while bi < toBundle.count {
    val f = toBundle[bi]
    val pkgName = dottedPath(f.packageDecl.path)
    // A sibling project package is the user's own code: its failures are
    // always fatal (reachable or not) and its type-check errors gate
    // fatally, unlike bundled stdlib files.
    val isProjectPkg = projectOwners.containsKey(pkgJvmOwner(f.packageDecl.path))
    val reachable = referencedPkgs.containsKey(pkgJvmOwner(f.packageDecl.path)) or isProjectPkg
    val ok = try {
      match runMiddleEnd(f, importedPkgs, stdlibGenFuncs, allTemplates, isProjectPkg, pkgName) {
        case Some(ff) -> {
          collectAspectWovenSigs(ff, registry)
          collectBModeWovenSigs(ff, registry)
          collectMonoSpecializedSigs(ff, registry, externSeedForFile(ff, extPkgNames, extPkgMaps))
          collectFileCasesExtern(ff, caseReg, externSeedForFile(ff, extPkgNames, extPkgMaps))
          collectFileCtors(ff, ctorReg)
          // #4994: only the project's OWN packages get a contract resource —
          // a merely-referenced stdlib package (isProjectPkg == false) never
          // does, matching `Msil.Bridge`'s `embedLyricContract` scope.
          if isProjectPkg {
            val (ffContractName, ffContractData) = contractZipEntry(f, ff, pkgName, jarVersion)
            contractEntryNames.add(ffContractName)
            contractEntryDatas.add(ffContractData)
          }
          codegenPackageInto(
            ff,
            registry,
            caseReg,
            ctorReg,
            autoFfi,
            allProjFqns,
            allClasses,
            externSeedForFile(ff, extPkgNames, extPkgMaps)
          )
          true
        }
        // A fatal middle-end diagnostic (already reported) aborts the build only
        // when the package is actually called; an imported-only package whose
        // middle-end fails is skipped (its bytecode is never invoked).
        case None -> not reachable
      }
    } catch Bug as b {
      // Diagnostic code registry (J001-J003 are emitted directly in this file;
      // J004 lives in `codegen/05_stmts.l` (`lowerTryCatchExpr`) and J005 in
      // `codegen/04_calls.l` (`lowerAutoFfiConstructorCall`) — check both before
      // reusing the next number (#3322).
      if reachable {
        // A codegen panic already carrying its own `error[J00N]:` code (e.g.
        // J004/J005) is passed through untouched — re-prefixing it with J002
        // produced nested "error[J002]: error[J004]: ..." output (#3311).
        if b.message.startsWith("error[J0") {
          Console.error(b.message)
        } else {
          Console.error("error[J002]: JVM codegen failed for referenced package '" + pkgName + "': " + b.message)
        }
        Console.error(
          "  this package's functions are called by the program, so it must compile; " +
            "the failure above names the symbol or construct the JVM backend could not lower"
        )
        false
      } else {
        // Unreached package whose codegen failed: not a build error because its
        // bytecode is never invoked, but counted (with the package name and the
        // panic's own message) so the J003 note below names exactly what was
        // dropped and why instead of an anonymous count.
        skippedCount = skippedCount + 1
        skippedNames.add(pkgName + " (" + b.message + ")")
        true
      }
    }
    if not ok {
      return false
    }
    bi = bi + 1
  }
  if skippedCount > 0 {
    Console.error(
      "note[J003]: " + skippedCount.toString() + " stdlib package(s) could not be bundled (JVM backend gap); " +
        "runtime calls into them will fail with NoClassDefFoundError — " +
        "if that happens, please file an issue"
    )
    var sni = 0
    while sni < skippedNames.count {
      Console.error("note[J003]:   skipped: " + skippedNames[sni])
      sni = sni + 1
    }
  }

  // Main-Class from the user package declaration.
  val segs = userFile.packageDecl.path.segments
  var mainClassName: String = packageName
  if segs.count > 0 {
    mainClassName = dottedPath(userFile.packageDecl.path)
  }

  // `autoFfi.jarPaths` (LYRIC_FFI_JARS, itself injected from a restored
  // project's `target/restore/jvm-classpath.txt` by `cli_build.l`) is
  // embedded as a manifest `Class-Path:` so `java -jar` — used by both
  // `lyric run --target jvm` and `lyric test --target jvm`, neither of
  // which passes `-cp` — can actually load Maven dependency classes at
  // runtime instead of throwing NoClassDefFoundError the moment a `[maven]`
  // dependency (e.g. Quartz) is actually used.  Restored Lyric-package JARs
  // (#3094) ride the same `Class-Path:` mechanism, appended after the Maven
  // entries, for the identical reason: their classes are registered above
  // but never re-emitted into THIS jar.
  // (`jarVersion` was hoisted above the codegen loops — see its declaration.)
  val mergedClasspathJars: List[String] = newList()
  var mcpi = 0
  while mcpi < autoFfi.jarPaths.count {
    mergedClasspathJars.add(autoFfi.jarPaths[mcpi])
    mcpi = mcpi + 1
  }
  var mrji = 0
  while mrji < restoredJarPaths.count {
    mergedClasspathJars.add(restoredJarPaths[mrji])
    mrji = mrji + 1
  }

  // This build's own package(s) are already embedded as `Lyric.Contract.<Pkg>`
  // ZIP entries by the `contractZipEntry` calls above (#4994), so a
  // DOWNSTREAM consumer can later restore THIS jar as a dependency
  // (`Lyric.ContractMeta.readAllContractsFromJarFile` /
  // `Lyric.RestoredPackages.loadRestoredPackageJvm`, #3094) — no separate
  // contract-collection pass is needed here; that
  // hoisted `contractEntryNames`/`contractEntryDatas` pair (built from the
  // POST-middle-end `userFile`/`toBundle` pairs, reconciled via
  // `withGenericFuncsForContract` for generic-function-body fidelity) is
  // passed straight through to `writeJarFromClassesWithResources` below.
  val req = BuildRequest(
    packageName = packageName,
    mainClass = mainClassName,
    version = jarVersion,
    outPath = outputPath,
    classpathJars = mergedClasspathJars
  )
  writeJarFromClassesWithResources(req, allClasses, contractEntryNames, contractEntryDatas)
}
