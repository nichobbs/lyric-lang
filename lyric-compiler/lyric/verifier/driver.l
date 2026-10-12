//! verifier/driver.l — end-to-end verifier driver for self-hosted use.
//!
//! Orchestrates: parse → mode-check → stability-check → VC-gen → discharge.
//! Simplified vs the F# Driver.fs: no cross-package imports, no persistent
//! z3 session, no counterexample trace analysis, no SMT file writing.
//!
//! Mirrors compiler/src/Lyric.Verifier/Driver.fs (M4.1 subset).
package Lyric.Verifier

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Lyric.ModeChecker
import Lyric.Weaver
import Lyric.Cfg as Cfg
import Std.File as File
import Std.String as Str

// ─────────────────────────────────────────────────────────────────────────────
// §1. Result types.
// ─────────────────────────────────────────────────────────────────────────────
pub record ProofResult {
  pub goal: Goal
  pub outcome: SolverOutcome
  /// False when the goal could not be put into the proof logic faithfully
  /// (V0033): it has no SMT-LIB query, and was never sent to a solver.
  pub translated: Bool
  /// Who decided the goal and what the solver answered (`SolverExchange`;
  /// `lyric prove --verbose`, #8320).  Empty for a goal never decided.
  pub decidedBy: String
  pub response: String
}

pub record ProofSummary {
  pub level: VerificationLevel
  pub diagnostics: List[Diagnostic]
  /// The function's obligations: what `lyric prove` counts and lists.
  pub results: List[ProofResult]
  /// The checks that each `requires:` clause can be met (#8223).  They guard
  /// the obligations against vacuity and are not obligations themselves, so
  /// they are kept apart from `results`; a failed one is reported as V0035,
  /// an undecided one as V0036.
  pub vacuityChecks: List[ProofResult]
}

pub func summaryDischargedCount(s: in ProofSummary): Int {
  var n = 0
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Discharged -> {
        n = n + 1
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  n
}

pub func summaryTotalCount(s: in ProofSummary): Int {
  s.results.count
}

/// The obligations whose outcome is `unknown`: the solver could not decide
/// them, none was available, or they could not be translated.  The vacuity
/// checks are not obligations and are not counted (#8307).
pub func summaryUnknownCount(s: in ProofSummary): Int {
  var n = 0
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Unknown(_) -> {
        n = n + 1
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  n
}

/// The obligations the solver refuted with a counterexample (#8307).
pub func summaryCounterexampleCount(s: in ProofSummary): Int {
  var n = 0
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Counterexample(_) -> {
        n = n + 1
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  n
}

pub func summaryHasFailure(s: in ProofSummary): Bool {
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Discharged -> {
      }
      case _ -> {
        return true
      }
    }
    i = i + 1
  }
  false
}

pub func summaryHasCounterexample(s: in ProofSummary): Bool {
  var i = 0
  while i < s.results.count {
    match s.results[i].outcome {
      case Counterexample(_) -> {
        return true
      }
      case _ -> {
      }
    }
    i = i + 1
  }
  false
}

pub func summaryHasErrorDiag(s: in ProofSummary): Bool {
  var i = 0
  while i < s.diagnostics.count {
    if s.diagnostics[i].severity == DiagError {
      return true
    }
    i = i + 1
  }
  false
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Outcome → Diagnostic.
// ─────────────────────────────────────────────────────────────────────────────
// Discharged goals produce no diagnostic; counterexample → V0008 error;
// unknown → V0007 warning (or error if allowUnverified = false).
pub func outcomeToDiag(g: in Goal, outcome: in SolverOutcome, allowUnverified: in Bool): Option[Diagnostic] {
  match outcome {
    case Discharged -> None
    case Counterexample(model) -> {
      match g.kind {
        case GKPreconditionDomain(fn) -> {
          return Some(
            value = errorDiagnostic(
              "V0035",
              "this precondition of " + fn +
                " can never hold: no argument meets it, given the parameters' types and the clauses before it (its value is never true, or a side condition in it, such as a callee's requires: or a non-zero divisor, always fails), so no call can meet it and every proof of " +
                fn +
                " would hold vacuously",
              g.origin
            )
          )
        }
        case _ -> ()
      }
      val body = if model.length > 0 {
        val bindings = parseModel(model)
        if bindings.count == 0 {
          val rawLines = model.split("\n")
          val lines: List[String] = newList()
          for ln in rawLines {
            lines.add(ln)
          }
          val head: List[String] = newList()
          var i = 0
          while i < 6 and i < lines.count {
            head.add(lines[i])
            i = i + 1
          }
          "raw model:\n" + joinLines(head)
        } else {
          renderCounterexample(bindings)
        }
      } else {
        "(no model)"
      }
      Some(
        value = errorDiagnostic(
          "V0008",
          goalKindDisplay(g.kind) + " — proof failed (counterexample below)\n" + body,
          g.origin
        )
      )
    }
    case Unknown(reason) -> {
      // A query the solver rejected is a verifier bug: an error even with
      // --allow-unverified, the solver's text only a detail line (#8102).
      if reason.startsWith(solverRejectedMarker()) {
        val detail = reason.substring(solverRejectedMarker().length, reason.length - solverRejectedMarker().length)
        return Some(
          value = errorDiagnostic(
            "V0007",
            goalKindDisplay(g.kind) + " — internal verifier error: the proof query for goal '" + g.label +
              "' was malformed, so the goal is not proved; please report this\n  solver: " +
              detail,
            g.origin
          )
        )
      }
      // A precondition-domain goal guards against vacuity; it is not an
      // obligation of the function.  The solver not deciding it leaves the
      // function's own goals as they are, and is only a warning (#8223).
      match g.kind {
        case GKPreconditionDomain(fn) -> {
          return Some(
            value = warningDiagnostic(
              "V0036",
              "could not rule out that this precondition of " + fn +
                " can never hold: the solver could not decide whether some argument meets it (" +
                reason +
                "); if none does, every proof of " +
                fn +
                " holds vacuously",
              g.origin
            )
          )
        }
        case _ -> ()
      }
      if allowUnverified {
        Some(value = warningDiagnostic("V0007", goalKindDisplay(g.kind) + " — solver returned unknown: " + reason, g.origin))
      } else {
        Some(value = errorDiagnostic("V0007", goalKindDisplay(g.kind) + " — solver returned unknown: " + reason, g.origin))
      }
    }
  }
}

// A `GKPreconditionDomain` goal states that no argument meets a `requires:`
// clause; it holds when the solver refutes it, the refuting model being an
// argument that meets it.  Proved, it is the failure: no call can meet the
// clause (#8223).
func domainOutcome(g: in Goal, outcome: in SolverOutcome): SolverOutcome {
  match g.kind {
    case GKPreconditionDomain(_) -> match outcome {
      case Discharged -> Counterexample(model = "")
      case Counterexample(_) -> Discharged
      case Unknown(r) -> Unknown(reason = r)
    }
    case _ -> outcome
  }
}

// A precondition clause of a function whose earlier clause no call can meet
// holds vacuously under that clause: the earlier one is reported, not this
// one.  Records each function with a clause that cannot be met in
// `unmeetable`.
func afterUnmeetable(g: in Goal, outcome: in SolverOutcome, unmeetable: in List[String]): SolverOutcome {
  match g.kind {
    case GKPreconditionDomain(fn) -> match outcome {
      case Counterexample(_) -> {
        for f in unmeetable {
          if f == fn {
            return Discharged
          }
        }
        unmeetable.add(fn)
        outcome
      }
      case _ -> outcome
    }
    case _ -> outcome
  }
}

func isDomainGoal(g: in Goal): Bool {
  match g.kind {
    case GKPreconditionDomain(_) -> true
    case _ -> false
  }
}

func joinLines(lines: in List[String]): String {
  var output = ""
  var i = 0
  while i < lines.count {
    if i > 0 {
      output = output + "\n"
    }
    output = output + lines[i]
    i = i + 1
  }
  output
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Core prove pipeline.
// ─────────────────────────────────────────────────────────────────────────────
pub func proveSource(source: in String): ProofSummary {
  proveSourceWithOptions(source, false)
}

// The other files of the package being proved, as far as the verifier needs
// them: the top-level type names they declare (#8108).  `known` false means
// they could not all be seen, and every name is assumed declared there.
pub record PackageScope {
  pub known: Bool
  pub typeNames: List[String]
  /// What they declare that a proof of the file reads (#8230, #8231):
  /// interfaces an `impl` here inherits clauses from, union and enum cases a
  /// bare `match` pattern may name, and the packages they import.
  pub siblings: ScopeDecls
  /// The packages the verifier can read declarations of: the standard
  /// library's, and the other packages of the file's project.
  pub imports: ImportScope
}

/// The declarations of one or more files that a proof reads beyond the
/// proved file itself.
pub record ScopeDecls {
  pub interfaces: List[InterfaceDecl]
  pub unions: List[UnionDecl]
  /// The cases of every enum, by name.
  pub enumCases: List[String]
  /// The packages the files import (`import P`, not `import extern`).
  pub imports: List[String]
}

/// A package whose declarations the verifier read, by its dotted name.
pub record ResolvedPackage {
  pub name: String
  pub decls: ScopeDecls
}

/// The packages a proof can see the declarations of.  A package imported by
/// the proved package but not listed here is unresolved: a case it declares
/// may be named by a bare pattern, and an interface it declares has clauses
/// the verifier cannot read.
pub record ImportScope {
  pub packages: List[ResolvedPackage]
}

pub func emptyScopeDecls(): ScopeDecls {
  val noInterfaces: List[InterfaceDecl] = newList()
  val noUnions: List[UnionDecl] = newList()
  val none: List[String] = newList()
  val noImports: List[String] = newList()
  ScopeDecls(interfaces = noInterfaces, unions = noUnions, enumCases = none, imports = noImports)
}

pub func emptyImportScope(): ImportScope {
  val none: List[ResolvedPackage] = newList()
  ImportScope(packages = none)
}

/// The declarations of `file` a proof of another file reads.
pub func scopeDeclsOfFile(file: in SourceFile): ScopeDecls {
  val acc = emptyScopeDecls()
  appendScopeDecls(acc, file)
  acc
}

func appendScopeDecls(acc: in ScopeDecls, file: in SourceFile): Unit {
  for it in file.items {
    match it.kind {
      case IInterface(d) -> acc.interfaces.add(d)
      case IUnion(d) -> acc.unions.add(d)
      case IEnum(d) -> {
        for c in d.cases {
          acc.enumCases.add(c.name)
        }
      }
      case _ -> ()
    }
  }
  for imp in file.imports {
    if not imp.isExtern {
      val name = joinPathSegments(imp.path.segments)
      if not acc.imports.contains(name) {
        acc.imports.add(name)
      }
    }
  }
}

func mergeScopeDecls(acc: in ScopeDecls, more: in ScopeDecls): Unit {
  for d in more.interfaces {
    acc.interfaces.add(d)
  }
  for d in more.unions {
    acc.unions.add(d)
  }
  for c in more.enumCases {
    acc.enumCases.add(c)
  }
  for n in more.imports {
    if not acc.imports.contains(n) {
      acc.imports.add(n)
    }
  }
}

/// `scope` with the package `name`, built from `sources`, added: unchanged
/// when it already holds `name`, or when a source does not parse (the
/// package then stays unresolved).
pub func importScopeWithPackage(sc: in ImportScope, name: in String, sources: in List[String]): ImportScope {
  for p in sc.packages {
    if p.name == name {
      return sc
    }
  }
  val decls = emptyScopeDecls()
  for src in sources {
    val parsed = parse(src)
    if hasFatalDiag(parsed.diagnostics) {
      return sc
    }
    appendScopeDecls(decls, parsed.file)
  }
  val packages: List[ResolvedPackage] = newList()
  for p in sc.packages {
    packages.add(p)
  }
  packages.add(ResolvedPackage(name = name, decls = decls))
  ImportScope(packages = packages)
}

/// `scope` with every package of `sources` added, each source belonging to
/// the package its own `package` line names (the standard library's
/// layout).  A package one of whose sources does not parse stays
/// unresolved.
pub func importScopeWithSources(sc: in ImportScope, sources: in List[String]): ImportScope {
  val names: List[String] = newList()
  val grouped: List[List[String]] = newList()
  for src in sources {
    val name = headerPackageName(src)
    if name.length > 0 {
      var at = -1
      var i = 0
      while i < names.count {
        if names[i] == name {
          at = i
        }
        i = i + 1
      }
      if at < 0 {
        names.add(name)
        val one: List[String] = newList()
        one.add(src)
        grouped.add(one)
      } else {
        grouped[at].add(src)
      }
    }
  }
  var acc = sc
  var gi = 0
  while gi < names.count {
    acc = importScopeWithPackage(acc, names[gi], grouped[gi])
    gi = gi + 1
  }
  acc
}

pub func unknownPackageScope(): PackageScope {
  val none: List[String] = newList()
  PackageScope(known = false, typeNames = none, siblings = emptyScopeDecls(), imports = emptyImportScope())
}

/// A known scope of `typeNames` that declares nothing else.
pub func packageScopeOf(typeNames: in List[String]): PackageScope {
  PackageScope(known = true, typeNames = typeNames, siblings = emptyScopeDecls(), imports = emptyImportScope())
}

pub func packageScopeWith(typeNames: in List[String], siblings: in ScopeDecls): PackageScope {
  PackageScope(known = true, typeNames = typeNames, siblings = siblings, imports = emptyImportScope())
}

/// `scope` reading the declarations of the packages of `imports`.
pub func withImportScope(sc: in PackageScope, imports: in ImportScope): PackageScope {
  PackageScope(known = sc.known, typeNames = sc.typeNames, siblings = sc.siblings, imports = imports)
}

// A source file's package and the top-level type names it declares;
// `parsed` false when it does not parse.  `customGenerator` says it carries
// a custom `@generate(X.Y)`, whose generated code — appended before the
// build merges the package — may declare any type.
pub record PackageTypes {
  pub packageName: String
  pub typeNames: List[String]
  pub decls: ScopeDecls
  pub parsed: Bool
  pub customGenerator: Bool = false
}

pub func packageTypesOfSource(source: in String): PackageTypes {
  val parsed = parse(source)
  if hasFatalDiag(parsed.diagnostics) {
    val none: List[String] = newList()
    return PackageTypes(packageName = "", typeNames = none, decls = emptyScopeDecls(), parsed = false)
  }
  PackageTypes(
    packageName = joinPathSegments(parsed.file.packageDecl.path.segments),
    typeNames = declaredTypeNames(parsed.file),
    decls = scopeDeclsOfFile(parsed.file),
    parsed = true,
    customGenerator = hasCustomGenerator(parsed.file)
  )
}

// Whether an item carries `@generate(X.Y)`: a custom generator, run by the
// build (`Lyric.Generator`).  The built-in `@generate(Json)`-style derives
// add functions, never a type.
func hasCustomGenerator(file: in SourceFile): Bool {
  var i = 0
  while i < file.items.count {
    val anns = file.items[i].annotations
    var k = 0
    while k < anns.count {
      val ann = anns[k]
      if joinPathSegments(ann.name.segments) == "generate" {
        var ai = 0
        while ai < ann.args.count {
          match ann.args[ai] {
            case ABare(name, _) -> {
              if Str.contains(name, ".") {
                return true
              }
            }
            case _ -> ()
          }
          ai = ai + 1
        }
      }
      k = k + 1
    }
    i = i + 1
  }
  false
}

// The scope of a file of a package built from `packageFiles` (every file of
// it, normalized as `ownPath` is; the file itself is read from `ownSource`,
// not disk): the type names every file declares (`scopeOfSources`).  An
// unknown file set (`None`) or an own file that does not parse or carries a
// custom generator makes it unknown.  `fromManifest` says the set is a
// manifest entry's, whose build merges every file whatever its `package`
// line; otherwise it is the directory-tree fallback, whose own build is the
// file alone, and a file of another package that does not parse is no part
// of it.  `lyric prove <file>` and the LSP take the set from
// `Lyric.Discovery.packageFileSetForSource`, the build's own (#8108).
pub func scopeFromPackageFiles(
  packageFiles: in Option[List[String]],
  fromManifest: in Bool,
  ownPath: in String,
  ownSource: in String,
): PackageScope {
  val files = match packageFiles { case Some(fs) -> fs; case None -> { return unknownPackageScope() } }
  val own = packageTypesOfSource(ownSource)
  if not own.parsed or own.customGenerator {
    return unknownPackageScope()
  }
  scopeOfFilesIn(files, ownPath, if fromManifest { "" } else { own.packageName })
}

// The type names every file of `files` but `skipPath` declares, as
// `scopeOfSources` classifies them; unknown when one cannot be read.
pub func scopeOfFiles(files: in List[String], skipPath: in String): PackageScope {
  scopeOfFilesIn(files, skipPath, "")
}

func scopeOfFilesIn(files: in List[String], skipPath: in String, ownPackage: in String): PackageScope {
  val sources: List[String] = newList()
  var i = 0
  while i < files.count {
    if files[i] != skipPath {
      match File.readText(files[i]) {
        case Ok(t) -> sources.add(t)
        case Err(_) -> return unknownPackageScope()
      }
    }
    i = i + 1
  }
  scopeOfSources(sources, ownPackage)
}

// The type names the other files of a package declare, from their texts.
// A package build does not parse its files one by one: it strips each
// file's `package` and `import` lines, concatenates the bodies and parses
// the result (`Lyric.Emitter.mergePackageSources`), so a file with no
// `package` line is part of it and its declarations are live (#8214).  The
// per-file reading here equals that merge once the build merges at the AST
// level (#8234).  Each file is classified the way the build would treat it:
//   * one that parses contributes the types it declares;
//   * one with no `package` line that does not parse alone is parsed again
//     under a `package` line, as the build reads it, and contributes its
//     types, or makes the scope unknown when it still does not parse;
//   * when `ownPackage` is given (the directory-tree fallback, whose build
//     is the proved file alone), one whose `package` line names another
//     package and that does not parse is skipped;
//   * any other file that does not parse makes the scope unknown — in a
//     manifest entry (`ownPackage` "") every file is merged into the build,
//     whatever its `package` line.
// A custom generator anywhere makes it unknown: its generated code may
// declare any type.
pub func scopeOfSources(sources: in List[String], ownPackage: in String): PackageScope {
  val names: List[String] = newList()
  val siblings = emptyScopeDecls()
  var i = 0
  while i < sources.count {
    val src = sources[i]
    var pt = packageTypesOfSource(src)
    if not pt.parsed {
      val header = headerPackageName(src)
      if header.length == 0 {
        pt = packageTypesOfSource("package LyricSiblingWithoutHeader\n" + src)
        if not pt.parsed {
          return unknownPackageScope()
        }
      } else if ownPackage.length > 0 and header != ownPackage {
        i = i + 1
        continue
      } else {
        return unknownPackageScope()
      }
    }
    if pt.customGenerator {
      return unknownPackageScope()
    }
    var k = 0
    while k < pt.typeNames.count {
      names.add(pt.typeNames[k])
      k = k + 1
    }
    // In the directory-tree fallback a file of another package that parses
    // is no part of the build: its declarations are not in scope (#8231).
    // A file with no `package` line is merged into the build's package.
    if ownPackage.length == 0 or pt.packageName == ownPackage or headerPackageName(src).length == 0 {
      mergeScopeDecls(siblings, pt.decls)
    }
    i = i + 1
  }
  packageScopeWith(names, siblings)
}

/// A file of a manifest entry as its package build reads it (every file of
/// the entry is merged, whatever its `package` line): its types and
/// declarations, or None when it makes the scope unknown — it does not
/// parse even under a `package` line, or it carries a custom generator.
pub func classifyManifestSource(src: in String): Option[PackageTypes] {
  var pt = packageTypesOfSource(src)
  if not pt.parsed {
    if headerPackageName(src).length > 0 {
      return None
    }
    pt = packageTypesOfSource("package LyricSiblingWithoutHeader\n" + src)
    if not pt.parsed {
      return None
    }
  }
  if pt.customGenerator {
    return None
  }
  Some(value = pt)
}

/// The known scope the files `pts` (`classifyManifestSource`) make for
/// another file of the same package.
pub func scopeOfPackageTypes(pts: in List[PackageTypes]): PackageScope {
  val names: List[String] = newList()
  val siblings = emptyScopeDecls()
  for pt in pts {
    for n in pt.typeNames {
      names.add(n)
    }
    mergeScopeDecls(siblings, pt.decls)
  }
  packageScopeWith(names, siblings)
}

// The package a file's `package` line names, or "" when its header has
// none.  The header is what precedes the first item: blank lines,
// comments, file-level annotations and the `package` line itself.
pub func headerPackageName(source: in String): String {
  val lines = Str.split(source, "\n")
  var inBlock = false
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    if inBlock {
      if Str.contains(line, "*/") {
        inBlock = false
      }
    } else if Str.startsWith(line, "/*") {
      inBlock = not Str.contains(line, "*/")
    } else if Str.startsWith(line, "package ") {
      return Str.trim(line.substring(8, line.length - 8))
    } else if not (line.length == 0 or Str.startsWith(line, "//") or Str.startsWith(line, "@")) {
      return ""
    }
    i = i + 1
  }
  ""
}

// Without a scope, the package's other files are unknown.
pub func proveSourceWithOptions(source: in String, allowUnverified: in Bool): ProofSummary {
  proveSourceInScope(source, allowUnverified, unknownPackageScope())
}

/// The verification level `source` declares, as `proveSourceInScope` reads
/// it; `@runtime_checked` when the source does not parse.
pub func sourceVerificationLevel(source: in String): VerificationLevel {
  val parsed = parse(source)
  if hasFatalDiag(parsed.diagnostics) {
    return VLRuntimeChecked
  }
  fileLevelOf(parsed.file)
}

// The verification level `file` declares, read from its annotations alone:
// the full mode check keys items by name, and a file not yet `@cfg`-erased
// may declare one name twice (#8325).
func fileLevelOf(file: in SourceFile): VerificationLevel {
  val ignored: List[Diagnostic] = newList()
  levelOfFile(file, ignored)
}

/// The build a proof is of: what `@cfg` erasure keeps of a file, as
/// `Lyric.Pipeline.pipeParseAndErase` erases it for that build — its target
/// (`dotnet`, `jvm` or `native`), active features and the features its
/// manifest declares (empty for a file no manifest builds).
pub record ProveBuildConfig {
  pub targetName: String
  pub activeFeatures: List[String]
  pub declaredFeatures: List[String]
}

/// The build of a single file with no manifest: `--target dotnet`, no
/// features.
pub func defaultProveBuildConfig(): ProveBuildConfig {
  val none: List[String] = newList()
  ProveBuildConfig(targetName = "dotnet", activeFeatures = none, declaredFeatures = none)
}

/// `source` proved for each distinct build of `builds` (the default build
/// when there is none), the results of all of them together: a file that
/// builds compile under different targets or features is proved as each of
/// them compiles it, each of its goals labelled with its build
/// (`[target=jvm features=a] f$post`), so no count merges two builds'
/// obligations.  Identical diagnostics are reported once.
pub func proveSourceForBuilds(
  source: in String,
  allowUnverified: in Bool,
  pkgScope: in PackageScope,
  builds: in List[ProveBuildConfig],
): ProofSummary {
  val distinct = distinctProveBuilds(builds)
  val first = proveSourceForBuild(source, allowUnverified, pkgScope, distinct[0])
  if distinct.count == 1 {
    return first
  }
  val diags: List[Diagnostic] = newList()
  val results: List[ProofResult] = newList()
  val vacuity: List[ProofResult] = newList()
  var level = first.level
  var bi = 0
  while bi < distinct.count {
    val one = if bi == 0 { first } else { proveSourceForBuild(source, allowUnverified, pkgScope, distinct[bi]) }
    if bi > 0 and vlIsProofRequired(one.level) {
      level = one.level
    }
    val tag = "[" + proveBuildDisplay(distinct[bi]) + "] "
    // A goal's outcome is the build's: its line names the build.  A
    // diagnostic about the source alone is reported once.
    for d in one.diagnostics {
      if isGoalDiagnostic(d) {
        diags.add(Diagnostic(severity = d.severity, code = d.code, message = tag + d.message, span = d.span))
      } else {
        diags.add(d)
      }
    }
    for r in one.results {
      results.add(withBuildLabel(r, tag))
    }
    for r in one.vacuityChecks {
      vacuity.add(withBuildLabel(r, tag))
    }
    bi = bi + 1
  }
  ProofSummary(level = level, diagnostics = dedupeDiagnostics(diags), results = results, vacuityChecks = vacuity)
}

// Whether `d` reports the outcome of one goal: a refutation, an undecided
// or untranslatable goal, a precondition check, or a goal that depends on
// what the verifier does not model.
func isGoalDiagnostic(d: in Diagnostic): Bool {
  if d.code == "V0007" or d.code == "V0008" or d.code == "V0035" or d.code == "V0036" {
    return true
  }
  if d.code == "V0027" {
    return d.severity == DiagError
  }
  d.code == "V0033" and Str.contains(d.message, " — cannot translate the obligation into the proof logic faithfully")
}

func withBuildLabel(r: in ProofResult, tag: in String): ProofResult {
  val g = r.goal
  ProofResult(
    goal = Goal(
      hypotheses = g.hypotheses,
      conclusion = g.conclusion,
      symbols = g.symbols,
      origin = g.origin,
      kind = g.kind,
      label = tag + g.label
    ),
    outcome = r.outcome,
    translated = r.translated,
    decidedBy = r.decidedBy,
    response = r.response
  )
}

/// A build as goal labels name it: `target=jvm`, then `features=a,b` when
/// any are active.
pub func proveBuildDisplay(b: in ProveBuildConfig): String {
  if b.activeFeatures.count == 0 {
    "target=" + b.targetName
  } else {
    "target=" + b.targetName + " features=" + Str.joinList(",", b.activeFeatures)
  }
}

/// The items of a `@proof_required` source that `@cfg` erasure removes
/// under every build a proof is of, by name (`inactiveItemsForBuilds`).
pub record InactiveItems {
  /// Items no build compiles in any form: nothing of them is proved.
  pub unproved: List[String]
  /// Inactive variants of items another declaration of the same name
  /// stands for in a build, which is proved (`@cfg` twins).
  pub variants: List[String]
}

/// The items of a `@proof_required` `source` that `@cfg` erasure removes
/// under every build of `builds` (the default build when there is none).
/// Empty for a source that does not parse, is not `@proof_required`, or
/// erases nothing.
pub func inactiveItemsForBuilds(source: in String, builds: in List[ProveBuildConfig]): InactiveItems {
  val unproved: List[String] = newList()
  val variants: List[String] = newList()
  val parsed = parse(source)
  if hasFatalDiag(parsed.diagnostics) or not vlIsProofRequired(fileLevelOf(parsed.file)) {
    return InactiveItems(unproved = unproved, variants = variants)
  }
  val distinct = distinctProveBuilds(builds)
  val keptFiles: List[SourceFile] = newList()
  for b in distinct {
    keptFiles.add(
      Cfg.applyCfgErasure(Cfg.withTargetFeature(b.activeFeatures, b.targetName), b.declaredFeatures, parsed.file).file
    )
  }
  for item in parsed.file.items {
    var keptSomewhere = false
    var twinKept = false
    val name = itemDisplayName(item.kind)
    for kf in keptFiles {
      for k in kf.items {
        if k.span.startPos.offset == item.span.startPos.offset and k.span.endPos.offset == item.span.endPos.offset {
          keptSomewhere = true
        } else if itemDisplayName(k.kind) == name and name.length > 0 {
          twinKept = true
        }
      }
    }
    if not keptSomewhere and name.length > 0 {
      if twinKept {
        if not variants.contains(name) {
          variants.add(name)
        }
      } else {
        unproved.add(name)
      }
    }
  }
  InactiveItems(unproved = unproved, variants = variants)
}

func itemDisplayName(kind: in ItemKind): String {
  match kind {
    case IFunc(fn) -> fn.name
    case IRecord(d) -> d.name
    case IExposedRec(d) -> d.name
    case IUnion(d) -> d.name
    case IEnum(d) -> d.name
    case IProtected(d) -> d.name
    case IInterface(d) -> d.name
    case IImpl(d) -> "impl " + joinPathSegments(d.iface.head.segments) + " for " + implTargetName(d.target)
    case _ -> ""
  }
}

func distinctProveBuilds(builds: in List[ProveBuildConfig]): List[ProveBuildConfig] {
  val distinct: List[ProveBuildConfig] = newList()
  for b in builds {
    var seen = false
    for d in distinct {
      if sameProveBuild(d, b) {
        seen = true
      }
    }
    if not seen {
      distinct.add(b)
    }
  }
  if distinct.count == 0 {
    distinct.add(defaultProveBuildConfig())
  }
  distinct
}

// Whether two builds erase alike: one target, and the same active and
// declared feature sets.
func sameProveBuild(a: in ProveBuildConfig, b: in ProveBuildConfig): Bool {
  a.targetName == b.targetName and sameNameSet(a.activeFeatures, b.activeFeatures) and
    sameNameSet(a.declaredFeatures, b.declaredFeatures)
}

func sameNameSet(xs: in List[String], ys: in List[String]): Bool {
  for x in xs {
    if not ys.contains(x) {
      return false
    }
  }
  for y in ys {
    if not xs.contains(y) {
      return false
    }
  }
  true
}

/// `proveSourceForBuild` for the default build (`defaultProveBuildConfig`).
pub func proveSourceInScope(source: in String, allowUnverified: in Bool, pkgScope: in PackageScope): ProofSummary {
  proveSourceForBuild(source, allowUnverified, pkgScope, defaultProveBuildConfig())
}

/// Prove `source` as the build `build` compiles it: its items are what
/// `@cfg` erasure keeps for that build's target and features, before any
/// pass reads them, so two `@cfg`-gated declarations of one name are never
/// both seen (#8325).
pub func proveSourceForBuild(
  source: in String,
  allowUnverified: in Bool,
  pkgScope: in PackageScope,
  build: in ProveBuildConfig,
): ProofSummary {
  // 1. Parse.
  val parsedRaw = parse(source)
  val parseDiags: List[Diagnostic] = newList()
  appendDiags(parseDiags, parsedRaw.diagnostics)

  if hasFatalDiag(parseDiags) {
    val results: List[ProofResult] = newList()
    val noChecks: List[ProofResult] = newList()
    return ProofSummary(level = VLRuntimeChecked, diagnostics = parseDiags, results = results, vacuityChecks = noChecks)
  }

  // 1b. `@cfg` erasure for the build (#8325).  A malformed predicate or an
  //     undeclared feature (F0012/F0013) stops the proof, as it stops the
  //     build.
  val erased = Cfg.applyCfgErasure(
    Cfg.withTargetFeature(build.activeFeatures, build.targetName),
    build.declaredFeatures,
    parsedRaw.file
  )
  appendDiags(parseDiags, erased.diagnostics)
  if hasFatalDiag(erased.diagnostics) {
    val results: List[ProofResult] = newList()
    val noChecks: List[ProofResult] = newList()
    return ProofSummary(
      level = fileLevelOf(erased.file),
      diagnostics = parseDiags,
      results = results,
      vacuityChecks = noChecks
    )
  }
  val file = erased.file

  // 2. Mode-check (against the erased file — annotations and aspect decls
  //    still visible).
  val modeResult = checkFile(file)
  val level = modeResult.level
  val modeDiags = modeResult.diagnostics

  // 3. Stability-check.
  val stabilityDiags = checkStabilityFile(file)

  val allParseDiags: List[Diagnostic] = newList()
  appendDiags(allParseDiags, parseDiags)
  appendDiags(allParseDiags, modeDiags)
  appendDiags(allParseDiags, stabilityDiags)

  if not vlIsProofRequired(level) {
    val results: List[ProofResult] = newList()
    val noChecks: List[ProofResult] = newList()
    return ProofSummary(level = level, diagnostics = allParseDiags, results = results, vacuityChecks = noChecks)
  }

  // 4. Aspect weave (#336).  Replaces each matched IFunc with a renamed
  //    `__aspect_target` plus a wrapper carrying the composed contracts
  //    so the verifier sees the body the runtime executes.  Identity-op
  //    for files without any `aspect` block.  Uses the with-diagnostics
  //    variant so weave-time errors (A0042 args-mismatch on
  //    @inline_template aspects, A0043 unknown call.<field>, A0044
  //    config.<no-default>) surface in the proof summary instead of
  //    being silently dropped.
  val wovenResult = weaveFileWithDiags(file)
  val wovenFile = wovenResult.file
  val weaveDiags = wovenResult.diagnostics
  appendDiags(allParseDiags, weaveDiags)

  // Gate on fatal weave diagnostics before VC generation.  A0044 in
  // particular materialises a `panic(...)` stub into the woven body; VC
  // generation would then model the panic as an unconstrained value and may
  // discharge goals as Proved even though the program panics at runtime —
  // producing an unsound result.  Returning early here matches the build
  // path's `reportAndAbort(weaveRes.diagnostics)` guard.
  if hasFatalDiag(weaveDiags) {
    val results: List[ProofResult] = newList()
    val noChecks: List[ProofResult] = newList()
    return ProofSummary(level = level, diagnostics = allParseDiags, results = results, vacuityChecks = noChecks)
  }

  // 5. VC generation against the woven file.
  val (goals, vcDiags) = goalsForFileInScope(wovenFile, level, pkgScope)

  val modeFatal = hasFatalDiag(modeDiags)
  if modeFatal {
    val results: List[ProofResult] = newList()
    val allDiags: List[Diagnostic] = newList()
    appendDiags(allDiags, allParseDiags)
    appendDiags(allDiags, vcDiags)
    val noChecks: List[ProofResult] = newList()
    return ProofSummary(level = level, diagnostics = allDiags, results = results, vacuityChecks = noChecks)
  }

  // 5. Discharge each goal.
  // The functions with a `requires:` clause no call can meet (#8223).
  val unmeetable: List[String] = newList()
  val results: List[ProofResult] = newList()
  val vacuity: List[ProofResult] = newList()
  val resultDiags: List[Diagnostic] = newList()
  var i = 0
  while i < goals.count {
    val skippedUnfold = goalHasSkippedUnfold(goals[i])
    val g = if skippedUnfold { withoutSkippedUnfoldMarkers(goals[i]) } else { goals[i] }
    // Warn before discharging if the goal contains NaN or ±Infinity float
    // literals.  smtRenderFloat silently substitutes 0.0 for non-finite values
    // (no SMT-LIB representation exists for them), so the verification result
    // may be incorrect.  Surface this as V0013 so users know to review it.
    if goalHasNonFiniteFloat(g) {
      resultDiags.add(
        warningDiagnostic(
          "V0013",
          "goal '" + g.label + "' contains NaN or +/-Infinity float literal; " +
            "replaced with 0.0 in SMT-LIB output — verification result may be incorrect",
          g.origin
        )
      )
    }
    // Bring every integer/bitvector operand to one sort before discharge
    // (#7848).  A goal that cannot be reconciled means something other than
    // the source, so it fails closed as V0033 — neither the trivial
    // discharger nor the solver sees it.  A goal carrying a construct VC
    // generation already reported as V0033 fails the same way, without a
    // second report (#7874).
    val into = if isDomainGoal(g) { vacuity } else { results }
    if goalIsPoisoned(g) {
      // A goal that depends on the value of a `match` with an arm the
      // verifier does not model is not proved, and is reported here: the
      // arm itself is only a V0027 warning, since a match whose value no
      // obligation needs is harmless (#8230).
      val unmodelled = goalHasUnmodelledPattern(g)
      val reason = if unmodelled {
        "not translatable: depends on a match arm pattern the verifier does not model (V0027)"
      } else {
        "not translatable: a construct reported above (V0033)"
      }
      into.add(ProofResult(goal = g, outcome = Unknown(reason = reason), translated = false, decidedBy = "", response = ""))
      // A goal a V0033 construct already fails is not reported again.
      if unmodelled and not isDomainGoal(g) and not goalHasUntranslatable(g) {
        resultDiags.add(
          errorDiagnostic(
            "V0027",
            goalKindDisplay(g.kind) +
              " depends on the value of a match with an arm whose pattern the verifier does not model; not proved",
            g.origin
          )
        )
      }
    } else {
      match reconcileGoalSorts(g) {
        case Ok(rg) -> {
          val exchange = dischargeExchange(rg)
          val decided = afterUnmeetable(rg, domainOutcome(rg, exchange.outcome), unmeetable)
          // A goal not discharged without the body of a `@pure` callee the
          // verifier could not unfold may hold with it: not proved, and
          // reported as what it depends on (#8230).
          val needsBody = skippedUnfold and not isDomainGoal(rg) and
            (match decided { case Discharged -> false; case _ -> true })
          val outcome = if needsBody {
            Unknown(
              reason = "depends on a @pure callee whose body the verifier does not unfold: its value comes from a match arm pattern the verifier does not model (V0027)"
            )
          } else {
            decided
          }
          into.add(
            ProofResult(
              goal = rg,
              outcome = outcome,
              translated = true,
              decidedBy = exchange.decidedBy,
              response = exchange.response
            )
          )
          if needsBody {
            // A model the solver found without the body may not be one
            // with it: shown, but as what the goal may depend on.
            val detail = match decided {
              case Counterexample(_) -> match outcomeToDiag(rg, decided, allowUnverified) {
                case Some(d) -> match Str.indexOf(d.message, "\n") {
                  case Some(nl) -> " (counterexample without the body below)" +
                    d.message.substring(
                      nl,
                      d.message.length - nl
                    )
                  case None -> ""
                }
                case None -> ""
              }
              case _ -> ""
            }
            resultDiags.add(
              errorDiagnostic(
                "V0027",
                goalKindDisplay(rg.kind) +
                  " may be false; depends on a @pure callee whose body was not unfolded, since its value comes from a match with an arm whose pattern the verifier does not model; not proved" +
                  detail,
                rg.origin
              )
            )
          } else {
            match outcomeToDiag(rg, outcome, allowUnverified) {
              case Some(d) -> resultDiags.add(d)
              case None -> {
              }
            }
          }
        }
        case Err(reason) -> {
          into.add(
            ProofResult(
              goal = g,
              outcome = Unknown(reason = "not translatable: " + reason),
              translated = false,
              decidedBy = "",
              response = ""
            )
          )
          // A precondition clause that cannot be translated is a hypothesis
          // of every other goal of its function, which reports it.
          if not isDomainGoal(g) {
            resultDiags.add(
              errorDiagnostic(
                "V0033",
                goalKindDisplay(g.kind) + " — cannot translate the obligation into the proof logic faithfully: " + reason,
                g.origin
              )
            )
          }
        }
      }
    }
    i = i + 1
  }

  val finalDiags: List[Diagnostic] = newList()
  appendDiags(finalDiags, allParseDiags)
  appendDiags(finalDiags, vcDiags)
  appendDiags(finalDiags, resultDiags)
  ProofSummary(level = level, diagnostics = finalDiags, results = results, vacuityChecks = vacuity)
}

// Reconcile the integer/bitvector sorts of every hypothesis and the
// conclusion of `g` (`reconcileTermSorts`).
pub func reconcileGoalSorts(g: in Goal): Result[Goal, String] {
  val hyps: List[Term] = newList()
  var i = 0
  while i < g.hypotheses.count {
    match reconcileTermSorts(g.hypotheses[i]) {
      case Ok(h) -> hyps.add(h)
      case Err(r) -> return Err(error = r)
    }
    i = i + 1
  }
  match reconcileTermSorts(g.conclusion) {
    case Ok(c) -> {
      // A value the verifier does not model has a sort of its own; one
      // compared with or used as a value of another sort makes the query
      // ill-sorted, which the solver would reject.  Fail closed here with
      // what went wrong instead (#8102).
      var hi = 0
      while hi < hyps.count {
        val hp = sortProblem(hyps[hi], SBool)
        if hp.length > 0 {
          return Err(error = hp)
        }
        hi = hi + 1
      }
      val cp = sortProblem(c, SBool)
      if cp.length > 0 {
        return Err(error = cp)
      }
      Ok(
        value = Goal(
          hypotheses = hyps,
          conclusion = c,
          symbols = g.symbols,
          origin = g.origin,
          kind = g.kind,
          label = g.label
        )
      )
    }
    case Err(r) -> Err(error = r)
  }
}

// "" when `t` is well-sorted and of sort `expected`; otherwise what is
// wrong with it.
func sortProblem(t: in Term, expected: in Sort): String {
  val own = sortOf(t)
  // Sorts the solver sees as one (`Float` and `Double` are both `Real`)
  // are the same here.
  if smtRenderSort(own) != smtRenderSort(expected) {
    return "a value the verifier does not model (sort " + sortDisplay(own) + ") is used where a " + sortDisplay(expected) +
      " is needed"
  }
  innerSortProblem(t)
}

func innerSortProblem(t: in Term): String {
  match t {
    case TVar(_, _) -> ""
    case TLit(_, _) -> ""
    case TBuiltin(op, args) -> {
      if isSortUnifyingBuiltin(op) and args.count == 2 {
        val p0 = innerSortProblem(args[0])
        if p0.length > 0 {
          return p0
        }
        sortProblem(args[1], sortOf(args[0]))
      } else {
        val boolArgs = match op { case BOpAnd | BOpOr | BOpNot | BOpImplies | BOpIff | BOpXor -> true; case _ -> false }
        var i = 0
        while i < args.count {
          val p = if boolArgs { sortProblem(args[i], SBool) } else { innerSortProblem(args[i]) }
          if p.length > 0 {
            return p
          }
          i = i + 1
        }
        ""
      }
    }
    case TApp(_, args, _) -> {
      var i = 0
      while i < args.count {
        val p = innerSortProblem(args[i])
        if p.length > 0 {
          return p
        }
        i = i + 1
      }
      ""
    }
    case TLet(bindings, body) -> {
      var i = 0
      while i < bindings.count {
        val p = innerSortProblem(bindings[i].term)
        if p.length > 0 {
          return p
        }
        i = i + 1
      }
      innerSortProblem(body)
    }
    case TIte(c, a, b) -> {
      val pc = sortProblem(c, SBool)
      if pc.length > 0 {
        return pc
      }
      val pa = innerSortProblem(a)
      if pa.length > 0 {
        return pa
      }
      sortProblem(b, sortOf(a))
    }
    case TForall(_, _, body) -> sortProblem(body, SBool)
    case TExists(_, body) -> sortProblem(body, SBool)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Helpers.
// ─────────────────────────────────────────────────────────────────────────────
func hasFatalDiag(diags: in List[Diagnostic]): Bool {
  var i = 0
  while i < diags.count {
    if diags[i].severity == DiagError {
      return true
    }
    i = i + 1
  }
  false
}

func appendDiags(dst: in List[Diagnostic], src: in List[Diagnostic]): Unit {
  var i = 0
  while i < src.count {
    dst.add(src[i])
    i = i + 1
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Non-finite float detection.
// ─────────────────────────────────────────────────────────────────────────────
// True when a Lit is a NaN or ±Infinity float, which smtRenderFloat silently
// replaces with "0.0" because SMT-LIB Real has no non-finite values.
func litIsNonFiniteFloat(lit: in Lit): Bool {
  match lit {
    case VLFloat(f) -> {
      val s = doubleToString(f)
      s == "NaN" or s == "Infinity" or s == "-Infinity"
    }
    case _ -> false
  }
}

// True when any subterm of `t` is a non-finite float literal.
func termHasNonFiniteFloat(t: in Term): Bool {
  match t {
    case TLit(value, _) -> litIsNonFiniteFloat(value)
    case TVar(_, _) -> false
    case TBuiltin(_, args) -> argsHaveNonFiniteFloat(args)
    case TApp(_, args, _) -> argsHaveNonFiniteFloat(args)
    case TLet(bindings, body) -> {
      var i = 0
      while i < bindings.count {
        if termHasNonFiniteFloat(bindings[i].term) {
          return true
        }
        i = i + 1
      }
      termHasNonFiniteFloat(body)
    }
    case TIte(cond, thenT, elseT) -> termHasNonFiniteFloat(cond) or termHasNonFiniteFloat(thenT) or
      termHasNonFiniteFloat(elseT)
    case TForall(_, triggers, body) -> {
      var i = 0
      while i < triggers.count {
        if argsHaveNonFiniteFloat(triggers[i]) {
          return true
        }
        i = i + 1
      }
      termHasNonFiniteFloat(body)
    }
    case TExists(_, body) -> termHasNonFiniteFloat(body)
  }
}

func argsHaveNonFiniteFloat(args: in List[Term]): Bool {
  var i = 0
  while i < args.count {
    if termHasNonFiniteFloat(args[i]) {
      return true
    }
    i = i + 1
  }
  false
}

// True when any hypothesis or the conclusion of `g` contains a non-finite float.
func goalHasNonFiniteFloat(g: in Goal): Bool {
  var i = 0
  while i < g.hypotheses.count {
    if termHasNonFiniteFloat(g.hypotheses[i]) {
      return true
    }
    i = i + 1
  }
  termHasNonFiniteFloat(g.conclusion)
}
