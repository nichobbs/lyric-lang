//! release.l — `lyric build --release` native-binary pipeline.
//!
//! Produces a self-contained, optimized, standalone native executable from a
//! compiled Lyric program — no managed runtime required on the target machine.
//! Plain `lyric build` keeps emitting the fast framework-dependent DLL (the
//! inner loop); `--release` is the deployable-artifact path.
//!
//! `--shape standalone` (DotnetStandalone, JvmStandalone) is the middle point
//! of the deployment spectrum: the managed program is bundled with a runtime
//! but is still JIT-compiled (.NET) or interpreted (JVM), so reflection and
//! dynamic loading keep working and no trimming rules apply.  The .NET arm
//! assembles a self-contained directory (patched apphost, the installed shared
//! runtime, the program and its references); the JVM arm builds a `jlink`
//! runtime image and a launcher script beside the program JARs.
//!
//! .NET target (DotnetAot): drives `ilc` (the .NET IL-to-native compiler) and
//! the platform linker (`clang` on Unix) directly from Lyric — no generated C#,
//! no `dotnet publish`.  The Lyric MSIL emitter already sets `EntryPointToken`
//! in the PE metadata to the program's `main()` method; `ilc` roots from this
//! token and produces a native object file.  A one-time `dotnet restore` on a
//! minimal probe `.csproj` seeds the NuGet cache and lets us discover the ILC
//! toolchain version via `project.assets.json`.
//!
//! JVM target (JvmNativeImage): drives GraalVM `native-image` over the bundled
//! JAR the JVM backend already produces (user package + transitive `Std.*`
//! import closure + sibling project packages, entry class named by the JAR
//! manifest's `Main-Class`).  `--no-fallback` makes a JVM-requiring fallback
//! image a hard error rather than a silent downgrade, so `--release` either
//! yields a standalone binary or fails.
package Lyric.Release

import Std.Core
import Std.Collections
import Std.Errors
import Std.Console as Console
import Std.String as Str
import Std.Parse as Parse
// before Path so Path.join/2 wins over Str.join (overload resolution)
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.ProcessCapture as PC
import Std.Environment as Environment
import Std.Encoding as Enc
import Std.Zip as Zip
import Jvm.NativeImage as NI
import Lyric.PackageMerge as PM

// Release target selector.  `buildRelease` is target-agnostic; each arm owns
// its toolchain invocation so adding the GraalVM path later does not touch the
// dispatcher or the .NET path.
pub union ReleaseTarget {
  case DotnetAot
  case JvmNativeImage
  case DotnetStandalone
  case JvmStandalone
}

// Discovered paths to the ILC toolchain packages.
record IlcPaths {
  ilcBin: String         // absolute path to the `ilc` binary
  sdkPath: String        // nativeaot runtime pack native/ dir
  frameworkPath: String  // nativeaot runtime pack lib/<tfm>/ dir
}

func releaseErr(message: in String): Unit {
  Console.error("release: " + message)
}

/// The package `source` declares, read from its header with comments and
/// annotations skipped (`Lyric.PackageMerge.scanHeader`).  Returns "" if
/// absent.
pub func packageNameOf(source: in String): String {
  PM.scanHeader(source).packageName
}

// Whether `source` declares a zero-argument `main` — the only form the
// emitter treats as a program entry point (`isMainFuncMsil`: name == "main",
// no params).  Used to pick the entry package in a multi-package project.
//
// This is a text scan, not a parse: lines inside triple-quoted ("""...""")
// string literals are skipped so embedded documentation containing a bare
// `func main()` line does not misidentify a library as an entry package
// (#3215), and a `"""` in a `//` line-comment tail does not flip the
// in-string state (#3248).  Raw-string edge cases (a raw literal that itself
// contains `"""`) and `//` inside ordinary one-line string literals remain
// best-effort — the scan is a pre-build package picker, not a parser.
//
// A `@plugin(...)` record (D207) counts: `Lyric.PluginExpand` generates the
// package's `func main(): Int`, and K0012 forbids writing one.
pub func declaresEntryMain(source: in String): Bool {
  val lines = Str.split(source, "\n")
  var inTripleString = false
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    // Match `func main()` / `pub func main()` with an empty parameter list,
    // tolerating whitespace before the `(`.
    if not inTripleString and Str.startsWith(line, "@plugin(") {
      return true
    }
    if not inTripleString and (Str.startsWith(line, "func main") or Str.startsWith(line, "pub func main")) {
      val afterMain = afterToken(line, "main")
      val trimmed = Str.trim(afterMain)
      if Str.startsWith(trimmed, "()") {
        return true
      }
    }
    inTripleString = advanceTripleState(lines[i], inTripleString)
    i += 1
  }
  false
}

// Advance the triple-quoted-string state across one raw source line.
func advanceTripleState(line: in String, inTriple: in Bool): Bool {
  var state = inTriple
  var i = 0
  val n = Str.length(line)
  while i < n {
    // A `//` outside a triple-quoted span starts a line comment that swallows
    // the rest of the line — including any `"""` in its tail (#3248).
    if not state and i + 1 < n and Str.substring(line, i, 2) == "//" {
      return state
    }
    if i + 3 <= n and Str.substring(line, i, 3) == "\"\"\"" {
      state = not state
      i += 3
    } else {
      i += 1
    }
  }
  state
}

/// Error message for a local path dependency whose output DLL is missing.
pub func localDepNotBuiltMessage(depName: in String, probedDll: in String, depToml: in String): String {
  "local dep '" + depName + "' not built: no DLL at '" + probedDll + "'. Run `lyric build --manifest " + depToml +
    "` first. Note: dependencies built with a custom --out path are not discovered; rebuild without --out so the DLL lands in the dependency's bin/ directory."
}

// Return the substring of `line` immediately following the first occurrence of
// `token`, or "" if `token` is absent.
func afterToken(line: in String, token: in String): String {
  match Str.indexOf(line, token) {
    case None -> ""
    case Some(idx) -> {
      val start = idx + Str.length(token)
      Str.substring(line, start, Str.length(line) - start)
    }
  }
}

// Locate the stdlib bundle (`Lyric.Stdlib.dll`).
func locateStdlib(programDllDir: in String): Option[String] {
  val appBase = Environment.appBaseDirectory()
  val candidates: List[String] = newList()
  candidates.add(Path.join(programDllDir, "Lyric.Stdlib.dll"))
  candidates.add(Path.join(Path.join(programDllDir, "lib"), "Lyric.Stdlib.dll"))
  candidates.add(Path.join(appBase, "Lyric.Stdlib.dll"))
  candidates.add(Path.join(Path.join(appBase, "lib"), "Lyric.Stdlib.dll"))
  var i = 0
  while i < candidates.count {
    if File.fileExists(candidates[i]) {
      return Some(value = candidates[i])
    }
    i += 1
  }
  None
}

// Resolve `p` to an absolute path against the process working directory.
func absPath(p: in String): String {
  if Path.isAbsolute(p) {
    p
  } else {
    Path.join(Environment.currentDirectory(), p)
  }
}

/// Locate `name` in the directories listed in `$PATH`, returning the first hit.
///
/// Done by scanning `$PATH` rather than by spawning the tool with `--version`:
/// `Std.ProcessCapture` surfaces a failed *launch* as a thrown host exception,
/// not as a non-zero exit code, so probing a tool that is absent would abort
/// the build with a raw .NET stack trace instead of an actionable diagnostic.
/// That stdlib seam is the real defect and is tracked in #6261; this routes
/// around it for the three tools the release paths probe, and does not fix it
/// for any other caller.
pub func findOnPath(name: in String, pathVar: in String, os: in String): Option[String] {
  if pathVar == "" {
    return None
  }
  val dirs = Str.split(pathVar, classpathSeparator(os))
  var i = 0
  while i < dirs.length {
    val dir = Str.trim(dirs[i])
    if dir != "" {
      val candidate = Path.join(dir, name)
      if File.fileExists(candidate) {
        return Some(value = candidate)
      }
    }
    i += 1
  }
  None
}

// Whether `name` is runnable from `$PATH` on this host.
func isOnPath(name: in String, os: in String): Bool {
  match findOnPath(name, Environment.getVarOrDefault("PATH", ""), os) {
    case Some(_) -> true
    case None -> false
  }
}

// ─── ILC toolchain discovery ─────────────────────────────────────────────────
// Probe `.csproj` content for a given RID.  No C# source files are included;
// `dotnet restore` pulls the ILC packages and writes `project.assets.json` so
// we can read the NuGet cache location and ILC version without driving
// `dotnet publish` or generating any C#.
// The probe TFM must match the .NET SDK version we target. Native AOT via ILC
// requires net8.0 minimum; we lock to net10.0 because that is the minimum SDK
// version Lyric requires (see docs/05-implementation-plan.md §Prerequisites).
func probeProjectContent(rid: in String): String {
  "<Project Sdk=\"Microsoft.NET.Sdk\">\n" + "  <PropertyGroup>\n" + "    <OutputType>Exe</OutputType>\n" +
    "    <TargetFramework>net10.0</TargetFramework>\n" +
    "    <PublishAot>true</PublishAot>\n" +
    "    <RuntimeIdentifier>" +
    rid +
    "</RuntimeIdentifier>\n" +
    "    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>\n" +
    "  </PropertyGroup>\n" +
    "</Project>\n"
}

// Extract the value of a `"key": "value"` JSON string field.
// Finds the first occurrence of `"<key>":` anywhere in the document.
// Safe for `project.assets.json` because `packagesPath` appears exactly once,
// inside `project.restore.packagesPath` — no library entry uses this key.
// Only handles simple string values (no nested objects).
pub func jsonStringField(json: in String, key: in String): Option[String] {
  val tag = "\"" + key + "\":"
  match Str.indexOf(json, tag) {
    case None -> None
    case Some(tagIdx) -> {
      val afterColon = Str.trim(Str.substring(json, tagIdx + Str.length(tag), Str.length(json) - tagIdx - Str.length(tag)))
      if not Str.startsWith(afterColon, "\"") {
        return None
      }
      // Skip opening quote
      val inner = Str.substring(afterColon, 1, Str.length(afterColon) - 1)
      // Find closing quote (not preceded by backslash — simple case)
      match Str.indexOf(inner, "\"") {
        case None -> None
        case Some(closeIdx) -> {
          val raw = Str.substring(inner, 0, closeIdx)
          // Minimal JSON string unescape: \\ → \ for Windows NuGet cache paths.
          // Full Unicode/surrogate-pair decoding, and \" unescaping, are not
          // needed here — only the packagesPath value is consumed, and a
          // filesystem path cannot contain a double-quote character on
          // Windows or Linux, so the closing-quote scan above never needs to
          // skip an escaped one.
          Some(value = Str.replace(raw, "\\\\", "\\"))
        }
      }
    }
  }
}

// Extract the ILC version from the `libraries` section of `project.assets.json`.
// The key has the form `"runtime.<RID>.Microsoft.DotNet.ILCompiler/<version>"`.
pub func parseIlcVersion(assetsJson: in String, rid: in String): Option[String] {
  val prefix = "\"runtime." + rid + ".Microsoft.DotNet.ILCompiler/"
  match Str.indexOf(assetsJson, prefix) {
    case Some(i) -> {
      val start = i + Str.length(prefix)
      val rest = Str.substring(assetsJson, start, Str.length(assetsJson) - start)
      match Str.indexOf(rest, "\"") {
        case None -> None
        case Some(endIdx) -> Some(value = Str.substring(rest, 0, endIdx))
      }
    }
    case None -> {
      // Fallback: search for the core/main ILCompiler package version
      val fallbackPrefix = "\"Microsoft.DotNet.ILCompiler/"
      match Str.indexOf(assetsJson, fallbackPrefix) {
        case None -> None
        case Some(i) -> {
          val start = i + Str.length(fallbackPrefix)
          val rest = Str.substring(assetsJson, start, Str.length(assetsJson) - start)
          match Str.indexOf(rest, "\"") {
            case None -> None
            case Some(endIdx) -> Some(value = Str.substring(rest, 0, endIdx))
          }
        }
      }
    }
  }
}

// Major version number from a semver string like "10.0.7" → 10.
pub func semverMajor(version: in String): Int {
  match Str.indexOf(version, ".") {
    case None -> 0
    case Some(dot) -> match Parse.tryParseInt(Str.substring(version, 0, dot)) { case Ok(n) -> n; case Err(_) -> 0 }
  }
}

// Extract the SDK packs directory from runtimeIdentifierGraphPath in project.assets.json.
//
// Uses `lastIndexOf` (not `indexOf`) to find the "/sdk/" separator between
// the dotnet install root and the version folder.  The standard SDK layout
// places exactly one "/sdk/" segment on this path
// (`<dotnet-root>/sdk/<version>/RuntimeIdentifierGraph.json`), so both
// functions agree there — but a custom or Homebrew-managed install whose
// root directory itself happens to contain the substring "/sdk/" earlier
// in the path (e.g. a user directory or DOTNET_ROOT named with "sdk" in it)
// would make `indexOf` cut at that spurious earlier occurrence and compute
// the wrong packs directory. `lastIndexOf` always lands on the "/sdk/" that
// actually separates the install root from the version folder, which is the
// rightmost one by construction (#4550).
func parseSdkPacksDir(assetsJson: in String): Option[String] {
  match jsonStringField(assetsJson, "runtimeIdentifierGraphPath") {
    case None -> None
    case Some(graphPath) -> {
      match Str.lastIndexOf(graphPath, "/sdk/") {
        case Some(idx) -> Some(value = Str.substring(graphPath, 0, idx) + "/packs")
        case None -> match Str.lastIndexOf(graphPath, "\\sdk\\") {
          case Some(idx) -> Some(value = Str.substring(graphPath, 0, idx) + "\\packs")
          case None -> None
        }
      }
    }
  }
}

// Fallback text for a diagnostic path variable that was never computed
// (the branch that would have populated it was skipped, e.g. `packsOpt`
// was `None` so the SDK-pack candidates were never probed).  Keeps the
// "was this path ever attempted?" distinction explicit in error messages
// rather than relying on an implicit empty-string convention (#4463).
func optPathOrNotAttempted(o: in Option[String]): String {
  match o {
    case Some(v) -> v
    case None -> "(not attempted)"
  }
}

// Explanation appended to a "packs directory" diagnostic when `packsOpt` is
// `None` — i.e. `parseSdkPacksDir` could not find a `/sdk/` (or `\sdk\`)
// segment in `runtimeIdentifierGraphPath`.  This can happen with
// non-standard .NET SDK install layouts; the NuGet cache probe above is
// still attempted independently, so this only blocks the SDK-pack fallback
// (#4464).
func packsNotFoundHint(): String {
  "  - SDK packs directory: not found (runtimeIdentifierGraphPath in project.assets.json was absent or " +
    "contained no '/sdk/' segment — check for a non-standard .NET SDK install layout or set DOTNET_ROOT " +
    "to the SDK install root)"
}

// Helper to search both local NuGet cache and SDK packs for ILC and NativeAOT runtime.
func resolveIlcPaths(
  pkgsDir: in String, packsOpt: in Option[String], rid: in String, ilcVersion: in String
): Result[IlcPaths, String] {
  var ilcBinOpt: Option[String] = None

  // Try NuGet packages directory
  val nugetIlc = Path.join(
    Path.join(
      Path.join(Path.join(pkgsDir, "runtime." + rid + ".microsoft.dotnet.ilcompiler"), ilcVersion),
      "tools"
    ),
    "ilc"
  )
  var packIlc1Opt: Option[String] = None
  var packIlc2Opt: Option[String] = None

  if File.fileExists(nugetIlc) {
    ilcBinOpt = Some(value = nugetIlc)
  } else {
    match packsOpt {
      case Some(packsDir) -> {
        val packIlc1 = Path.join(
          Path.join(
            Path.join(Path.join(packsDir, "runtime." + rid + ".Microsoft.DotNet.ILCompiler"), ilcVersion),
            "tools"
          ),
          "ilc"
        )
        packIlc1Opt = Some(value = packIlc1)
        if File.fileExists(packIlc1) {
          ilcBinOpt = Some(value = packIlc1)
        } else {
          val packIlc2 = Path.join(
            Path.join(
              Path.join(Path.join(packsDir, "runtime." + rid + ".microsoft.dotnet.ilcompiler"), ilcVersion),
              "tools"
            ),
            "ilc"
          )
          packIlc2Opt = Some(value = packIlc2)
          if File.fileExists(packIlc2) {
            ilcBinOpt = Some(value = packIlc2)
          }
        }
      }
      case None -> ()
    }
  }

  val ilcBin = match ilcBinOpt {
    case Some(path) -> path
    case None -> return Err(
      error = "ILC binary ('ilc') not found. Probed paths:\n" + "  - NuGet cache: " + nugetIlc + "\n" +
        (
          match packsOpt {
            case Some(packsDir) -> "  - SDK pack 1: " + optPathOrNotAttempted(packIlc1Opt) +
              "\n  - SDK pack 2: " +
              optPathOrNotAttempted(packIlc2Opt)
            case None -> packsNotFoundHint()
          }
        )
    )
  }

  var nativeaotRootOpt: Option[String] = None

  // Try NuGet packages directory
  val nugetNativeAot = Path.join(
    Path.join(
      Path.join(Path.join(pkgsDir, "microsoft.netcore.app.runtime.nativeaot." + rid), ilcVersion),
      "runtimes"
    ),
    rid
  )
  var packNativeAot1Opt: Option[String] = None
  var packNativeAot2Opt: Option[String] = None

  if File.dirExists(nugetNativeAot) {
    nativeaotRootOpt = Some(value = nugetNativeAot)
  } else {
    match packsOpt {
      case Some(packsDir) -> {
        val packNativeAot1 = Path.join(
          Path.join(
            Path.join(Path.join(packsDir, "Microsoft.NETCore.App.Runtime.NativeAOT." + rid), ilcVersion),
            "runtimes"
          ),
          rid
        )
        packNativeAot1Opt = Some(value = packNativeAot1)
        if File.dirExists(packNativeAot1) {
          nativeaotRootOpt = Some(value = packNativeAot1)
        } else {
          val packNativeAot2 = Path.join(
            Path.join(
              Path.join(Path.join(packsDir, "microsoft.netcore.app.runtime.nativeaot." + rid), ilcVersion),
              "runtimes"
            ),
            rid
          )
          packNativeAot2Opt = Some(value = packNativeAot2)
          if File.dirExists(packNativeAot2) {
            nativeaotRootOpt = Some(value = packNativeAot2)
          }
        }
      }
      case None -> ()
    }
  }

  val nativeaotRoot = match nativeaotRootOpt {
    case Some(path) -> path
    case None -> return Err(
      error = "NativeAOT runtime pack directory not found. Probed paths:\n" + "  - NuGet cache: " + nugetNativeAot +
        "\n" +
        (
          match packsOpt {
            case Some(packsDir) -> "  - SDK pack 1: " + optPathOrNotAttempted(packNativeAot1Opt) +
              "\n  - SDK pack 2: " +
              optPathOrNotAttempted(packNativeAot2Opt)
            case None -> packsNotFoundHint()
          }
        )
    )
  }

  val major = semverMajor(ilcVersion)
  val tfm = "net" + toString(major) + ".0"
  val sdkPath = Path.join(nativeaotRoot, "native")
  val frameworkPath = Path.join(Path.join(nativeaotRoot, "lib"), tfm)

  if not File.dirExists(sdkPath) {
    return Err(
      error = "NativeAOT runtime SDK directory ('native' subfolder) not found under runtime pack root:\n" +
        "  Root: " +
        nativeaotRoot +
        "\n" +
        "  Expected: " +
        sdkPath
    )
  }

  Ok(value = IlcPaths(ilcBin = ilcBin, sdkPath = sdkPath, frameworkPath = frameworkPath))
}

// Attempt to build IlcPaths from an already-populated probe directory.
// Returns None on any missing file or parse failure so the caller can fall
// through to a full `dotnet restore`.  Used as the cache-hit fast path.
func tryLoadCachedIlcPaths(probeDir: in String, rid: in String): Option[IlcPaths] {
  val assetsPath = Path.join(Path.join(probeDir, "obj"), "project.assets.json")
  if not File.fileExists(assetsPath) {
    return None
  }
  val assetsJson = match File.readText(assetsPath) { case Err(_) -> return None; case Ok(t) -> t }
  val pkgsDir = match jsonStringField(assetsJson, "packagesPath") { case None -> return None; case Some(p) -> p }
  val ilcVersion = match parseIlcVersion(assetsJson, rid) { case None -> return None; case Some(v) -> v }
  val sdkPacksDirOpt = parseSdkPacksDir(assetsJson)
  match resolveIlcPaths(pkgsDir, sdkPacksDirOpt, rid, ilcVersion) {
    case Ok(paths) -> Some(value = paths)
    case Err(_) -> None
  }
}

// Restore the ILC probe project and return the NuGet packages directory and
// ILC version.  The probe project lives under `<stageDir>/ilc-probe/`.
// Returns Err with a diagnostic message on any failure.
func restoreIlcProbe(stageDir: in String, rid: in String): Result[IlcPaths, String] {
  val probeDir = Path.join(stageDir, "ilc-probe")
  if not File.dirExists(probeDir) {
    match File.createDir(probeDir) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = "could not create ILC probe dir: " + IOError.message(e))
    }
  }

  // Fast path: if a previous restore already populated obj/project.assets.json and
  // the ILC binary is still present in the NuGet cache, skip dotnet restore entirely.
  match tryLoadCachedIlcPaths(probeDir, rid) {
    case Some(cached) -> return Ok(value = cached)
    case None -> ()
  }

  val csprojPath = Path.join(probeDir, "probe.csproj")
  match File.writeText(csprojPath, probeProjectContent(rid)) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "could not write ILC probe project: " + IOError.message(e))
  }

  // Run `dotnet restore` to populate the NuGet cache with the per-RID ILC packages.
  val restoreArgs: List[String] = newList()
  restoreArgs.add("restore")
  restoreArgs.add(csprojPath)
  restoreArgs.add("--nologo")
  val restoreResult = PC.runCaptureWithDiagnosticsTimeout("dotnet", restoreArgs, "", 300000)
  if restoreResult.timedOut {
    return Err(
      error = "dotnet restore for ILC toolchain timed out (5-minute limit); check network connectivity or NuGet feed availability"
    )
  }
  if restoreResult.exitCode != 0 {
    return Err(
      error = "dotnet restore for ILC toolchain failed (exit " + toString(restoreResult.exitCode) + "):\n" +
        restoreResult.stdout +
        restoreResult.stderr
    )
  }

  // Parse project.assets.json
  val assetsPath = Path.join(Path.join(probeDir, "obj"), "project.assets.json")
  val assetsJson = match File.readText(assetsPath) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = "could not read project.assets.json: " + IOError.message(e))
  }

  val pkgsDir = match jsonStringField(assetsJson, "packagesPath") {
    case Some(p) -> p
    case None -> return Err(error = "could not find packagesPath in project.assets.json")
  }

  val ilcVersion = match parseIlcVersion(assetsJson, rid) {
    case Some(v) -> v
    case None -> return Err(
      error = "could not find ILC version for RID '" + rid + "' in project.assets.json. " +
        "ILC is a NuGet package (runtime." +
        rid +
        ".Microsoft.DotNet.ILCompiler), not a workload — " +
        "check that the NuGet feed is reachable and retry: " +
        "`dotnet restore --verbosity detailed " +
        csprojPath +
        "`"
    )
  }

  val sdkPacksDirOpt = parseSdkPacksDir(assetsJson)
  match resolveIlcPaths(pkgsDir, sdkPacksDirOpt, rid, ilcVersion) {
    case Ok(paths) -> Ok(value = paths)
    case Err(err) -> Err(error = err)
  }
}

// ─── ILC RSP construction ─────────────────────────────────────────────────────
// Feature flags and runtime knobs for AOT compilation.  These disable
// reflection-heavy and JIT-dependent subsystems incompatible with static
// compilation and trim unused framework code paths.  The list mirrors what
// `dotnet publish -p:PublishAot=true` injects via Microsoft.NETCore.Native.targets
// for net10.0.
func appendAotFeatureLines(lines: in List[String]): Unit {
  lines.add("--feature:Microsoft.Extensions.DependencyInjection.VerifyOpenGenericServiceTrimmability=true")
  lines.add("--feature:System.ComponentModel.DefaultValueAttribute.IsSupported=false")
  lines.add("--feature:System.ComponentModel.Design.IDesignerHost.IsSupported=false")
  lines.add(
    "--feature:System.ComponentModel.TypeConverter.EnableUnsafeBinaryFormatterInDesigntimeLicenseContextSerialization=false"
  )
  lines.add("--feature:System.ComponentModel.TypeDescriptor.IsComObjectDescriptorSupported=false")
  lines.add("--feature:System.Data.DataSet.XmlSerializationIsSupported=false")
  lines.add("--feature:System.Diagnostics.Tracing.EventSource.IsSupported=false")
  lines.add("--feature:System.Linq.Enumerable.IsSizeOptimized=true")
  lines.add("--feature:System.Net.Security.UseManagedNtlm=false")
  lines.add("--feature:System.Net.SocketsHttpHandler.Http3Support=false")
  lines.add("--feature:System.Reflection.Metadata.MetadataUpdater.IsSupported=false")
  lines.add("--feature:System.Resources.ResourceManager.AllowCustomResourceTypes=false")
  lines.add("--feature:System.Resources.UseSystemResourceKeys=false")
  lines.add("--feature:System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported=false")
  lines.add("--feature:System.Runtime.InteropServices.BuiltInComInterop.IsSupported=false")
  lines.add("--feature:System.Runtime.InteropServices.EnableConsumingManagedCodeFromNativeHosting=false")
  lines.add("--feature:System.Runtime.InteropServices.EnableCppCLIHostActivation=false")
  lines.add("--feature:System.Runtime.InteropServices.Marshalling.EnableGeneratedComInterfaceComImportInterop=false")
  lines.add("--feature:System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization=false")
  lines.add("--feature:System.StartupHookProvider.IsSupported=false")
  lines.add("--feature:System.Text.Encoding.EnableUnsafeUTF7Encoding=false")
  lines.add("--feature:System.Text.Json.JsonSerializer.IsReflectionEnabledByDefault=false")
  lines.add("--feature:System.Threading.Thread.EnableAutoreleasePool=false")
  lines.add("--feature:System.Linq.Expressions.CanEmitObjectArrayDelegate=false")
  lines.add("--feature:System.Diagnostics.Debugger.IsSupported=false")
  lines.add("--runtimeknob:Microsoft.Extensions.DependencyInjection.VerifyOpenGenericServiceTrimmability=true")
  lines.add("--runtimeknob:System.ComponentModel.DefaultValueAttribute.IsSupported=false")
  lines.add("--runtimeknob:System.ComponentModel.Design.IDesignerHost.IsSupported=false")
  lines.add(
    "--runtimeknob:System.ComponentModel.TypeConverter.EnableUnsafeBinaryFormatterInDesigntimeLicenseContextSerialization=false"
  )
  lines.add("--runtimeknob:System.ComponentModel.TypeDescriptor.IsComObjectDescriptorSupported=false")
  lines.add("--runtimeknob:System.Data.DataSet.XmlSerializationIsSupported=false")
  lines.add("--runtimeknob:System.Diagnostics.Tracing.EventSource.IsSupported=false")
  lines.add("--runtimeknob:System.Linq.Enumerable.IsSizeOptimized=true")
  lines.add("--runtimeknob:System.Net.Security.UseManagedNtlm=false")
  lines.add("--runtimeknob:System.Net.SocketsHttpHandler.Http3Support=false")
  lines.add("--runtimeknob:System.Reflection.Metadata.MetadataUpdater.IsSupported=false")
  lines.add("--runtimeknob:System.Resources.ResourceManager.AllowCustomResourceTypes=false")
  lines.add("--runtimeknob:System.Resources.UseSystemResourceKeys=false")
  lines.add("--runtimeknob:System.Runtime.CompilerServices.RuntimeFeature.IsDynamicCodeSupported=false")
  lines.add("--runtimeknob:System.Runtime.InteropServices.BuiltInComInterop.IsSupported=false")
  lines.add("--runtimeknob:System.Runtime.InteropServices.EnableConsumingManagedCodeFromNativeHosting=false")
  lines.add("--runtimeknob:System.Runtime.InteropServices.EnableCppCLIHostActivation=false")
  lines.add(
    "--runtimeknob:System.Runtime.InteropServices.Marshalling.EnableGeneratedComInterfaceComImportInterop=false"
  )
  lines.add("--runtimeknob:System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization=false")
  lines.add("--runtimeknob:System.StartupHookProvider.IsSupported=false")
  lines.add("--runtimeknob:System.Text.Encoding.EnableUnsafeUTF7Encoding=false")
  lines.add("--runtimeknob:System.Text.Json.JsonSerializer.IsReflectionEnabledByDefault=false")
  lines.add("--runtimeknob:System.Threading.Thread.EnableAutoreleasePool=false")
  lines.add("--runtimeknob:System.Linq.Expressions.CanEmitObjectArrayDelegate=false")
}

// Validate a .NET RID: must be non-empty, at most 50 chars, and contain only
// lowercase letters, digits, dots, and hyphens.  Rejects XML metacharacters
// (< > & " ') that would inject into the probe .csproj <RuntimeIdentifier>
// element if a user-supplied --rid value were passed through unvalidated.
pub func isValidRid(rid: in String): Bool {
  val n = Str.length(rid)
  if n == 0 or n > 50 {
    return false
  }
  val valid = "abcdefghijklmnopqrstuvwxyz0123456789.-"
  var i = 0
  while i < n {
    val ch = Str.substring(rid, i, 1)
    if not Str.contains(valid, ch) {
      return false
    }
    i += 1
  }
  true
}

// Extract the OS component from a .NET RID: "linux-x64" → "linux",
// "osx-arm64" → "osx", "win-x64" → "windows".
pub func ridOs(rid: in String): String {
  match Str.indexOf(rid, "-") {
    case None -> rid
    case Some(i) -> {
      val os = Str.substring(rid, 0, i)
      if os == "osx" {
        "osx"
      } else if os == "win" {
        "windows"
      } else {
        os
      }
    }
  }
}

// Extract the arch component from a .NET RID: "linux-x64" → "x64",
// "linux-arm64" → "arm64", "osx-x64" → "x64", "linux-musl-x64" → "x64".
// Uses the LAST dash so multi-segment RIDs (linux-musl-x64) work correctly.
pub func ridArch(rid: in String): String {
  match Str.lastIndexOf(rid, "-") {
    case None -> rid
    case Some(i) -> Str.substring(rid, i + 1, Str.length(rid) - i - 1)
  }
}

// Build the ILC RSP (response file) content for the given program DLL.
// `extraRefs` are additional managed DLLs (stdlib, restored deps) to pass as `-r:`.
// `exportsFile` is the path where ILC should write the linker exports script.
func buildIlcRsp(
  programDll: in String,
  objFile: in String,
  extraRefs: in List[String],
  paths: in IlcPaths,
  rid: in String,
  exportsFile: in String,
): Result[String, String] {
  val lines: List[String] = newList()

  // Primary input: the Lyric program DLL.  ILC reads the EntryPointToken from
  // the PE metadata and uses it as the native entry — no C# trampoline needed.
  lines.add(programDll)
  lines.add("-o:" + objFile)

  // Framework DLLs from lib/net10.0/
  match File.listFiles(paths.frameworkPath) {
    case Ok(fs) -> {
      var fi = 0
      while fi < fs.count {
        val f = fs[fi]
        if Str.endsWith(f, ".dll") {
          lines.add("-r:" + f)
        }
        fi += 1
      }
    }
    case Err(e) -> {
      return Err(error = "could not enumerate framework DLLs from '" + paths.frameworkPath + "': " + IOError.message(e))
    }
  }

  // Private SDK DLLs from native/ — compiled as ILC *inputs* (not -r:) so
  // that [RuntimeExport]-attributed managed functions (InitializeModules,
  // GetRuntimeException, RuntimeFailFast, ThreadEntryPoint, AppendExceptionStackFrame,
  // GetSystemArrayEEType, RhThrowEx, RhRethrow, ProcessFinalizers, etc.) are
  // compiled into the output object file by this ILC invocation.
  // The pre-compiled libRuntime.WorkstationGC.a provides only the C/assembly
  // GC primitives (RhNewObject, RhpNewArrayFast, etc.); the managed-tier init
  // and exception sequences live in these managed assemblies and MUST be
  // compiled fresh — passing them as -r: leaves the [RuntimeExport] symbols
  // absent from Hello.o and the linker reports them as undefined from
  // libbootstrapper.o (#4139 linker fix).
  val privateDlls: List[String] = newList()
  privateDlls.add("System.Private.CoreLib.dll")
  privateDlls.add("System.Private.Reflection.Execution.dll")
  privateDlls.add("System.Private.StackTraceMetadata.dll")
  privateDlls.add("System.Private.TypeLoader.dll")
  var pi = 0
  while pi < privateDlls.count {
    val p = Path.join(paths.sdkPath, privateDlls[pi])
    if not File.fileExists(p) {
      return Err(
        error = "required ILC input '" + privateDlls[pi] + "' not found at '" + p + "'. " +
          "The NativeAOT SDK pack may be incomplete — delete the ilc-probe directory and retry."
      )
    }
    lines.add(p)
    pi += 1
  }

  // Extra managed references: Lyric.Stdlib.dll and restored dependencies.
  var ri = 0
  while ri < extraRefs.count {
    lines.add("-r:" + extraRefs[ri])
    ri += 1
  }

  // Target platform
  lines.add("--targetos:" + ridOs(rid))
  lines.add("--targetarch:" + ridArch(rid))

  // On Linux/macOS (non-Windows) with non-static builds, dehydrate data to
  // reduce binary size.
  val os = ridOs(rid)
  if os != "windows" {
    lines.add("--dehydrate")
  }

  lines.add("-O")

  // Assembly initializers
  lines.add("--initassembly:System.Private.CoreLib")
  lines.add("--initassembly:System.Private.StackTraceMetadata")
  lines.add("--initassembly:System.Private.TypeLoader")
  lines.add("--initassembly:System.Private.Reflection.Execution")

  // Direct P/Invoke for native shims included in the static libs
  lines.add("--directpinvoke:System.Native")
  lines.add("--directpinvoke:System.Globalization.Native")
  lines.add("--directpinvoke:System.IO.Compression.Native")
  lines.add("--directpinvoke:System.Net.Security.Native")
  lines.add("--directpinvoke:System.Security.Cryptography.Native.OpenSsl")

  // AOT feature flags and runtime knobs
  appendAotFeatureLines(lines)

  lines.add("--runtimeknob:RUNTIME_IDENTIFIER=" + rid)
  lines.add("--stacktracedata")
  lines.add("--scanreflection")
  lines.add("--methodbodyfolding:generic")
  lines.add("--resilient")

  // Exports file for the linker version script (controls symbol visibility).
  lines.add("--exportsfile:" + exportsFile)
  lines.add("--export-dynamic-symbol:DotNetRuntimeDebugHeader")

  // Build the RSP text: one arg per line.
  var rsp = ""
  var li = 0
  while li < lines.count {
    rsp = rsp + lines[li] + "\n"
    li += 1
  }
  Ok(value = rsp)
}

// ─── Linker invocation (Unix / clang) ────────────────────────────────────────
// Build the clang linker argument list for a Unix native executable.
// Returns all args in the order: obj file, -o output, native libs, linker flags.
func buildLinkerArgsUnix(
  objFile: in String,
  exportsFile: in String,
  outBin: in String,
  sdkPath: in String,
  arch: in String,
): List[String] {
  val sdk = sdkPath
  val args: List[String] = newList()

  // Input object
  args.add(objFile)
  args.add("-o")
  args.add(outBin)

  // Optimization / strip (match Release config)
  args.add("-fuse-ld=bfd")

  // Native shim static archives (netcoreapp native libs)
  args.add(Path.join(sdk, "libSystem.Native.a"))
  args.add(Path.join(sdk, "libSystem.Globalization.Native.a"))
  args.add(Path.join(sdk, "libSystem.IO.Compression.Native.a"))
  args.add(Path.join(sdk, "libSystem.Net.Security.Native.a"))
  args.add(Path.join(sdk, "libSystem.Security.Cryptography.Native.OpenSsl.a"))

  // Runtime bootstrapper + GC + minipal.  --start-group/--end-group lets
  // ld.bfd handle the circular symbol deps between Hello.o, libbootstrapper.o,
  // and libRuntime.WorkstationGC.a: Hello.o needs RhNewObject/RhTypeCast etc.
  // from WorkstationGC; WorkstationGC needs RhExceptionHandling_FailedAllocation
  // etc. from Hello.o; libbootstrapper.o needs InitializeModules from Hello.o.
  // Without the group, a single left-to-right scan leaves some symbols unresolved.
  args.add("-Wl,--start-group")
  args.add(Path.join(sdk, "libbootstrapper.o"))
  args.add(Path.join(sdk, "libRuntime.WorkstationGC.a"))
  args.add(Path.join(sdk, "libeventpipe-disabled.a"))
  // VxSort support (x64 only)
  if arch == "x64" {
    args.add(Path.join(sdk, "libRuntime.VxsortDisabled.a"))
  }
  args.add(Path.join(sdk, "libstandalonegc-disabled.a"))
  args.add(Path.join(sdk, "libaotminipal.a"))
  args.add(Path.join(sdk, "libstdc++compat.a"))
  args.add("-Wl,--end-group")

  // Compression + Brotli
  args.add(Path.join(sdk, "libz.a"))
  args.add(Path.join(sdk, "libbrotlienc.a"))
  args.add(Path.join(sdk, "libbrotlidec.a"))
  args.add(Path.join(sdk, "libbrotlicommon.a"))

  // Linker flags for PIE, symbol visibility, debug info
  args.add("-Wl,--version-script=" + exportsFile)
  args.add("-Wl,--export-dynamic")
  args.add("-Wl,--discard-all")
  args.add("-Wl,--gc-sections")
  args.add("-Wl,--build-id=sha1")
  args.add("-Wl,--as-needed")
  args.add("-Wl,--strip-debug")
  args.add("-pie")
  args.add("-Wl,-z,relro")
  args.add("-Wl,-z,now")

  // Required system libraries
  args.add("-pthread")
  args.add("-ldl")
  args.add("-lrt")
  args.add("-lm")

  args
}

// Build the clang linker argument list for a macOS native executable.
func buildLinkerArgsMac(
  objFile: in String,
  exportsFile: in String,
  outBin: in String,
  sdkPath: in String,
  arch: in String,
): List[String] {
  val args: List[String] = newList()

  // Input object
  args.add(objFile)
  args.add("-o")
  args.add(outBin)

  // Native shim static archives (netcoreapp native libs)
  args.add(Path.join(sdkPath, "libSystem.Native.a"))
  args.add(Path.join(sdkPath, "libSystem.Globalization.Native.a"))
  args.add(Path.join(sdkPath, "libSystem.IO.Compression.Native.a"))
  args.add(Path.join(sdkPath, "libSystem.Net.Security.Native.a"))
  args.add(Path.join(sdkPath, "libSystem.Security.Cryptography.Native.Apple.a"))

  // Runtime bootstrapper + GC + minipal.
  // Note: macOS linker (ld64) does not support --start-group/--end-group.
  args.add(Path.join(sdkPath, "libbootstrapper.o"))
  args.add(Path.join(sdkPath, "libRuntime.WorkstationGC.a"))
  args.add(Path.join(sdkPath, "libeventpipe-disabled.a"))
  // VxSort is disabled on macOS x64 via the VxsortDisabled stub to prevent unresolved symbols.
  if arch == "x64" {
    args.add(Path.join(sdkPath, "libRuntime.VxsortDisabled.a"))
  }
  args.add(Path.join(sdkPath, "libstandalonegc-disabled.a"))
  args.add(Path.join(sdkPath, "libaotminipal.a"))

  val stdcppCompat = Path.join(sdkPath, "libstdc++compat.a")
  if File.fileExists(stdcppCompat) {
    args.add(stdcppCompat)
  }

  // Compression + Brotli (check if present, since on macOS these may not be shipped as static libs in NativeAOT pack)
  val libz = Path.join(sdkPath, "libz.a")
  if File.fileExists(libz) {
    args.add(libz)
  } else {
    args.add("-lz")
  }

  val libbrotlienc = Path.join(sdkPath, "libbrotlienc.a")
  if File.fileExists(libbrotlienc) {
    args.add(libbrotlienc)
  }

  val libbrotlidec = Path.join(sdkPath, "libbrotlidec.a")
  if File.fileExists(libbrotlidec) {
    args.add(libbrotlidec)
  }

  val libbrotlicommon = Path.join(sdkPath, "libbrotlicommon.a")
  if File.fileExists(libbrotlicommon) {
    args.add(libbrotlicommon)
  }

  // Linker flags for symbol visibility and dead code stripping
  args.add("-Wl,-exported_symbols_list," + exportsFile)
  args.add("-Wl,-dead_strip")

  // Required system libraries and frameworks
  args.add("-pthread")
  args.add("-ldl")
  args.add("-lm")
  args.add("-liconv")
  args.add("-framework")
  args.add("Foundation")
  args.add("-framework")
  args.add("Security")
  args.add("-framework")
  args.add("GSS")

  args
}

// Delete the per-build ILC staging artifacts (the RSP file, the ILC object
// file, and the linker exports/version-script file) once they are no longer
// needed — on every return path from the ILC-run point onward, success or
// failure alike.  Only the final native binary at `outPath` is the
// deliverable; for programs of any size the `.o` file alone can be hundreds
// of megabytes, and repeated builds would otherwise accumulate disk usage
// silently in the staging directory (#4217).  `File.deleteFile` is
// idempotent on not-found, so this is safe to call even when a given
// artifact was never produced (e.g. ilc failed before writing objFile).
// The `ilc-probe/` sub-directory is deliberately left alone — it backs the
// cache-hit fast path in `tryLoadCachedIlcPaths`.
func cleanupIlcIntermediates(rspFile: in String, objFile: in String, exportsFile: in String): Unit {
  val _ = File.deleteFile(rspFile)
  val _ = File.deleteFile(objFile)
  val _ = File.deleteFile(exportsFile)
}

// ─── Top-level release pipeline ──────────────────────────────────────────────
/// Produce a native binary from an already-built program DLL via .NET Native AOT.
///
/// Drives `ilc` and the platform linker directly — no generated C#, no
/// `dotnet publish`.  The Lyric MSIL emitter sets `EntryPointToken` to the
/// program's `main()` method so ILC roots from that token without a C#
/// trampoline.
///
/// `programDll` — absolute path to the compiled program DLL.
/// `extraRefs` — additional managed DLLs to pass as ILC references (restored deps).
/// `ridOpt` — explicit .NET RID (e.g. "linux-x64"), or None to use the host RID.
/// `outPath` — destination for the native binary.
pub func buildReleaseDotnet(
  programDll: in String,
  extraRefs: in List[String],
  ridOpt: in Option[String],
  outPath: in String,
): Int {
  val absProgramDll = absPath(programDll)
  val programDir = Path.dirname(absProgramDll)
  val stageDir = programDir

  // Locate Lyric.Stdlib.dll and add it to the managed references for ILC.
  val allRefs: List[String] = newList()
  match locateStdlib(programDir) {
    case Some(p) -> allRefs.add(absPath(p))
    case None -> {
      releaseErr(
        "Lyric.Stdlib.dll not found near " + programDir + " or the lyric binary (" + Environment.appBaseDirectory() + ")"
      )
      return 1
    }
  }
  var ei = 0
  while ei < extraRefs.count {
    allRefs.add(absPath(extraRefs[ei]))
    ei += 1
  }

  // Determine the RID.
  val rid = match ridOpt {
    case Some(r) -> r
    case None -> {
      val hostRid = Environment.runtimeIdentifier()
      if hostRid == "" {
        releaseErr("could not determine the host RID; pass --rid <value> explicitly")
        return 1
      }
      hostRid
    }
  }

  if not isValidRid(rid) {
    releaseErr(
      "invalid RID '" + rid +
        "': a .NET RID must contain only lowercase letters, digits, dots, and hyphens (e.g. linux-x64)"
    )
    return 1
  }

  // Reject unsupported OS targets before the slow ILC probe + compile steps
  // so users get an immediate error rather than waiting 10+ minutes.  This is
  // an allowlist (not a blocklist of just "windows") so a RID whose OS is
  // neither "linux" nor "osx" — e.g. freebsd-x64, illumos-x64, or any future
  // RID — fails fast with an actionable message instead of falling through
  // to buildLinkerArgsUnix's Linux-ELF-specific flags and confusing
  // clang/ld.bfd errors (#4204).
  val os = ridOs(rid)
  val arch = ridArch(rid)
  if os != "linux" and os != "osx" {
    releaseErr("'" + rid + "' is not yet supported for native AOT (Linux and macOS only); tracked in #1975")
    return 1
  }

  // Verify clang is on PATH before the slow ILC probe and compile steps.
  // Probed by scanning $PATH, not by spawning it: a failed launch surfaces as
  // a thrown host exception rather than a non-zero exit code, so spawning an
  // absent clang aborted the build with a raw .NET stack trace instead of the
  // install hint below.
  if not isOnPath("clang", os) {
    releaseErr(
      "clang not found on PATH; install it before building Native AOT binaries\n" +
        "  Debian/Ubuntu: apt install clang binutils\n" +
        "  Fedora:        dnf install clang binutils\n" +
        "  Alpine:        apk add clang binutils"
    )
    return 1
  }

  // Verify ld.bfd is on PATH for non-macOS Unix platforms before the slow steps.
  // -fuse-ld=bfd in buildLinkerArgsUnix requires ld.bfd from GNU binutils; without
  // it clang fails with a cryptic "unable to execute command: No such file or directory".
  if os != "osx" {
    if not isOnPath("ld.bfd", os) {
      releaseErr(
        "ld.bfd (GNU binutils) not found on PATH; it is required by -fuse-ld=bfd\n" +
          "  Debian/Ubuntu: apt install binutils\n" +
          "  Fedora:        dnf install binutils\n" +
          "  Alpine:        apk add binutils"
      )
      return 1
    }
  }

  // Ensure the ILC toolchain is present in the NuGet cache and discover its paths.
  Console.println("release: resolving ILC toolchain for " + rid + " ...")
  val paths = match restoreIlcProbe(stageDir, rid) { case Ok(p) -> p; case Err(msg) -> { releaseErr(msg); return 1 } }

  // Derive output paths.
  val stem = match Str.indexOf(Path.basename(absProgramDll), ".") {
    case Some(i) -> Str.substring(Path.basename(absProgramDll), 0, i)
    case None -> Path.basename(absProgramDll)
  }
  val objFile = Path.join(stageDir, stem + ".o")
  val exportsFile = Path.join(stageDir, stem + ".exports")
  val rspFile = Path.join(stageDir, stem + ".ilc.rsp")

  // Write ILC RSP file.
  val rspContent = match buildIlcRsp(absProgramDll, objFile, allRefs, paths, rid, exportsFile) {
    case Ok(rsp) -> rsp
    case Err(msg) -> {
      releaseErr(msg)
      return 1
    }
  }
  match File.writeText(rspFile, rspContent) {
    case Ok(_) -> ()
    case Err(e) -> {
      releaseErr("could not write ILC RSP file: " + IOError.message(e))
      return 1
    }
  }

  // Run ILC.
  Console.println("release: running ilc (" + paths.ilcBin + ") ...")
  val ilcArgs: List[String] = newList()
  ilcArgs.add("@" + rspFile)
  val ilcResult = PC.runCaptureWithDiagnosticsTimeout(paths.ilcBin, ilcArgs, "", 600000)
  if ilcResult.stdout != "" {
    Console.println(ilcResult.stdout)
  }
  if ilcResult.stderr != "" {
    Console.error(ilcResult.stderr)
  }
  if ilcResult.timedOut {
    releaseErr("ilc timed out after 10 minutes")
    cleanupIlcIntermediates(rspFile, objFile, exportsFile)
    return 1
  }
  if ilcResult.exitCode != 0 {
    releaseErr("ilc exited " + toString(ilcResult.exitCode))
    cleanupIlcIntermediates(rspFile, objFile, exportsFile)
    return 1
  }
  if not File.fileExists(objFile) {
    releaseErr("ilc did not produce object file at " + objFile)
    cleanupIlcIntermediates(rspFile, objFile, exportsFile)
    return 1
  }
  if not File.fileExists(exportsFile) {
    releaseErr("ilc did not produce exports file at " + exportsFile)
    cleanupIlcIntermediates(rspFile, objFile, exportsFile)
    return 1
  }

  // Run platform linker.
  Console.println("release: linking native binary ...")
  val linkerArgs = if os == "osx" {
    buildLinkerArgsMac(objFile, exportsFile, outPath, paths.sdkPath, arch)
  } else {
    buildLinkerArgsUnix(objFile, exportsFile, outPath, paths.sdkPath, arch)
  }
  val linkResult = PC.runCaptureWithDiagnosticsTimeout("clang", linkerArgs, "", 300000)
  if linkResult.stdout != "" {
    Console.println(linkResult.stdout)
  }
  if linkResult.stderr != "" {
    Console.error(linkResult.stderr)
  }
  if linkResult.timedOut {
    releaseErr("linker timed out after 5 minutes")
    cleanupIlcIntermediates(rspFile, objFile, exportsFile)
    return 1
  }
  if linkResult.exitCode != 0 {
    releaseErr("clang linker exited " + toString(linkResult.exitCode))
    cleanupIlcIntermediates(rspFile, objFile, exportsFile)
    return 1
  }
  if not File.fileExists(outPath) {
    releaseErr("linker exited 0 but output binary was not produced at " + outPath)
    cleanupIlcIntermediates(rspFile, objFile, exportsFile)
    return 1
  }

  cleanupIlcIntermediates(rspFile, objFile, exportsFile)
  Console.println("built native binary " + outPath)
  0
}

// ─── GraalVM native-image (JVM target) ───────────────────────────────────────
// Classpath separator for the host: ';' on Windows, ':' everywhere else.
// `buildReleaseJvm` rejects Windows before this is reached, but the arg
// builder is pure and independently tested, so it takes the separator as a
// parameter rather than hard-coding a POSIX-only ':'.
pub func classpathSeparator(os: in String): String {
  if os == "windows" {
    ";"
  } else {
    ":"
  }
}

/// The middle segment(s) of a RID between OS and arch — the C-library / distro
/// qualifier.  `"linux-musl-x64"` → `"musl"`, `"linux-x64"` → `""`.
///
/// `ridOs` and `ridArch` alone cannot tell `linux-musl-x64` from `linux-x64`
/// (both yield `linux` / `x64`), so a host-match check built on those two
/// would accept `--rid linux-musl-x64` on a glibc host and emit a glibc binary
/// under a musl RID name — exactly the mislabelling the JVM arm rejects `--rid`
/// mismatches to prevent.
pub func ridFlavor(rid: in String): String {
  val first = match Str.indexOf(rid, "-") { case Some(i) -> i; case None -> return "" }
  val last = match Str.lastIndexOf(rid, "-") { case Some(i) -> i; case None -> return "" }
  if last <= first {
    ""
  } else {
    Str.substring(rid, first + 1, last - first - 1)
  }
}

/// Whether `rid` names the same platform as `hostRid` for native-image
/// purposes: same OS, same arch, and same C-library flavor.
pub func ridMatchesHost(rid: in String, hostRid: in String): Bool {
  ridOs(rid) == ridOs(hostRid) and ridArch(rid) == ridArch(hostRid) and ridFlavor(rid) == ridFlavor(hostRid)
}

/// Join classpath entries with the host separator.  Returns "" for an empty
/// list so callers can skip emitting `-cp` entirely.
pub func joinClasspath(entries: in List[String], os: in String): String {
  val sep = classpathSeparator(os)
  var acc = ""
  var i = 0
  while i < entries.count {
    if i > 0 {
      acc = acc + sep
    }
    acc = acc + entries[i]
    i += 1
  }
  acc
}

/// Build the `native-image` argument list for a bundled Lyric JAR.
///
/// `extraJars` are additional classpath entries (restored Maven jars); the
/// entry class is taken from `jarPath`'s manifest `Main-Class`, which the JVM
/// backend always writes, so no main class is passed explicitly.
pub func buildNativeImageArgs(
  jarPath: in String,
  extraJars: in List[String],
  configDir: in String,
  outPath: in String,
  os: in String,
): List[String] {
  val args: List[String] = newList()

  // A "fallback image" is a launcher that still requires a JVM at runtime;
  // native-image emits one silently when it cannot close the world.  That
  // would make `--release` produce a non-self-contained artifact while
  // exiting 0, so make it a build failure instead.
  args.add("--no-fallback")
  args.add("-H:+ReportExceptionStackTraces")
  args.add("-H:ConfigurationFileDirectories=" + configDir)

  if extraJars.count > 0 {
    args.add("-cp")
    args.add(joinClasspath(extraJars, os))
  }

  args.add("-jar")
  args.add(jarPath)
  args.add("-o")
  args.add(outPath)
  args
}

// Diagnostic for a host with no usable `native-image` driver, listing every
// probed location and how to install one.
pub func nativeImageNotFoundMessage(probed: in List[String]): String {
  var msg = "GraalVM `native-image` not found. Probed:\n"
  var i = 0
  while i < probed.count {
    msg = msg + "  - " + probed[i] + "\n"
    i += 1
  }
  msg + "Install a GraalVM JDK (21 or newer) and set GRAALVM_HOME to it:\n" +
    "  SDKMAN:  sdk install java 21.0.2-graalce\n" +
    "  Manual:  https://github.com/graalvm/graalvm-ce-builds/releases\n" +
    "  (GraalVM 22.3 and older also need a separate `gu install native-image`)\n" +
    "native-image also needs a C toolchain and zlib headers on the host:\n" +
    "  Debian/Ubuntu: apt install build-essential zlib1g-dev\n" +
    "  Fedora:        dnf install gcc glibc-devel zlib-devel\n" +
    "  macOS:         xcode-select --install"
}

// Diagnostic for `--rid` naming a platform other than the host.  GraalVM
// native-image has no cross-compilation mode: the image is always built for
// the machine running the builder.
pub func jvmCrossCompileMessage(requestedRid: in String, hostRid: in String): String {
  "`--release --target jvm` cannot cross-compile: GraalVM native-image always builds for the host.\n" +
    "  requested --rid: " +
    requestedRid +
    "\n  host:            " +
    hostRid +
    "\nBuild on a " +
    requestedRid +
    " machine (or in a matching container) instead, or drop --rid to target the host."
}

// Locate the GraalVM `native-image` driver.  Probes `$GRAALVM_HOME/bin`, then
// `$JAVA_HOME/bin` (a GraalVM JDK set as JAVA_HOME is the common SDKMAN
// layout), then `native-image` on PATH.
func findNativeImage(): Result[String, String] {
  val probed: List[String] = newList()

  val graalHome = Environment.getVarOrDefault("GRAALVM_HOME", "")
  if graalHome != "" {
    val fromGraalHome = Path.join(Path.join(graalHome, "bin"), "native-image")
    probed.add("$GRAALVM_HOME/bin/native-image -> " + fromGraalHome)
    if File.fileExists(fromGraalHome) {
      return Ok(value = fromGraalHome)
    }
  } else {
    probed.add("$GRAALVM_HOME (not set)")
  }

  val javaHome = Environment.getVarOrDefault("JAVA_HOME", "")
  if javaHome != "" {
    val fromJavaHome = Path.join(Path.join(javaHome, "bin"), "native-image")
    probed.add("$JAVA_HOME/bin/native-image -> " + fromJavaHome)
    if File.fileExists(fromJavaHome) {
      return Ok(value = fromJavaHome)
    }
  } else {
    probed.add("$JAVA_HOME (not set)")
  }

  match findOnPath("native-image", Environment.getVarOrDefault("PATH", ""), ridOs(Environment.runtimeIdentifier())) {
    case Some(p) -> return Ok(value = p)
    case None -> probed.add("native-image on $PATH")
  }

  Err(error = nativeImageNotFoundMessage(probed))
}

// Write the four native-image JSON configs into `configDir`, creating it.
func writeNativeImageConfigs(configDir: in String): Result[Unit, String] {
  if not File.dirExists(configDir) {
    match File.createDir(configDir) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = "could not create native-image config dir '" + configDir + "': " + IOError.message(e))
    }
  }
  val names: List[String] = newList()
  val bodies: List[String] = newList()
  names.add("reflect-config.json")
  bodies.add(NI.reflectConfigJson())
  names.add("resource-config.json")
  bodies.add(NI.resourceConfigJsonAll())
  names.add("proxy-config.json")
  bodies.add(NI.proxyConfigJson())
  names.add("jni-config.json")
  bodies.add(NI.jniConfigJson())

  var i = 0
  while i < names.count {
    val path = Path.join(configDir, names[i])
    match File.writeText(path, bodies[i]) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = "could not write " + path + ": " + IOError.message(e))
    }
    i += 1
  }
  Ok(value = ())
}

/// Validate everything about a JVM release request that can be checked before
/// the (slow) managed build runs: the `--rid` shape, that it names the host,
/// and that the host platform is supported.  Returns the diagnostic to print,
/// or `None` when the request is buildable.
///
/// Callers run this *before* staging the JAR so a bad `--rid` costs nothing;
/// `buildReleaseJvm` re-checks so it stays correct when driven directly (e.g.
/// `--release-from-dll`).
pub func jvmReleasePreflightError(ridOpt: in Option[String], hostRid: in String): Option[String] {
  if hostRid == "" {
    return Some(value = "could not determine the host platform for the native-image build")
  }
  match ridOpt {
    case Some(r) -> {
      if not isValidRid(r) {
        return Some(
          value = "invalid RID '" + r +
            "': a RID must contain only lowercase letters, digits, dots, and hyphens (e.g. linux-x64)"
        )
      }
      if not ridMatchesHost(r, hostRid) {
        return Some(value = jvmCrossCompileMessage(r, hostRid))
      }
    }
    case None -> ()
  }
  val os = ridOs(hostRid)
  if os != "linux" and os != "osx" {
    return Some(
      value = "'" + hostRid +
        "' is not yet supported for `--release --target jvm` (Linux and macOS only); tracked in #1975"
    )
  }
  None
}

/// Produce a native binary from an already-built bundled JAR via GraalVM
/// `native-image`.
///
/// `jarPath` — absolute path to the bundled JAR (its manifest `Main-Class` is
/// the image entry point).
/// `extraJars` — additional classpath entries (restored Maven dependencies).
/// `ridOpt` — explicit RID; native-image cannot cross-compile, so anything
/// other than the host platform is rejected up front.
/// `outPath` — destination for the native binary.
pub func buildReleaseJvm(
  jarPath: in String, extraJars: in List[String], ridOpt: in Option[String], outPath: in String
): Int {
  val absJar = absPath(jarPath)
  if not File.fileExists(absJar) {
    releaseErr("JAR not found at " + absJar)
    return 1
  }

  val hostRid = Environment.runtimeIdentifier()
  // native-image builds for the host only, and only Linux/macOS are supported.
  // The CLI runs this same preflight before staging the JAR so a bad request
  // costs no build; re-checking here keeps `buildReleaseJvm` correct when
  // driven directly (`--release-from-dll`).
  match jvmReleasePreflightError(ridOpt, hostRid) {
    case Some(msg) -> {
      releaseErr(msg)
      return 1
    }
    case None -> ()
  }
  val os = ridOs(hostRid)

  val niBin = match findNativeImage() { case Ok(p) -> p; case Err(msg) -> { releaseErr(msg); return 1 } }

  val stageDir = Path.dirname(absJar)
  val configDir = Path.join(stageDir, "native-image-config")
  match writeNativeImageConfigs(configDir) {
    case Ok(_) -> ()
    case Err(msg) -> {
      releaseErr(msg)
      return 1
    }
  }

  // native-image refuses to write into a directory that does not exist
  // ("Writing image to non-existent directory ... is not allowed") rather than
  // creating it, so materialize the output directory first.
  val absOut = absPath(outPath)
  val outDir = Path.dirname(absOut)
  if not File.dirExists(outDir) {
    match File.createDir(outDir) {
      case Ok(_) -> ()
      case Err(e) -> {
        releaseErr("could not create output dir '" + outDir + "': " + IOError.message(e))
        val _ = File.deleteDirRecursive(configDir)
        return 1
      }
    }
  }

  val absExtras: List[String] = newList()
  var xi = 0
  while xi < extraJars.count {
    absExtras.add(absPath(extraJars[xi]))
    xi += 1
  }

  Console.println("release: running native-image (" + niBin + ") ...")
  val niArgs = buildNativeImageArgs(absJar, absExtras, configDir, absOut, os)
  val niResult = PC.runCaptureWithDiagnosticsTimeout(niBin, niArgs, "", 1800000)
  if niResult.stdout != "" {
    Console.println(niResult.stdout)
  }
  if niResult.stderr != "" {
    Console.error(niResult.stderr)
  }
  // The staging config dir is deleted only on success.  Every failure below
  // leaves it on disk on purpose: a malformed config is a real, already-hit
  // failure mode here, and native-image names the offending *file* in its
  // error, so the file has to still exist to be worth naming.  It also
  // survives into a CI artifact upload, which the captured stdout/stderr text
  // alone does not.
  if niResult.timedOut {
    releaseErr("native-image timed out after 30 minutes; config left at " + configDir)
    return 1
  }
  if niResult.exitCode != 0 {
    releaseErr("native-image exited " + toString(niResult.exitCode) + "; config left at " + configDir)
    return 1
  }
  // native-image reports a config-parse failure through its own summary block
  // and still prints "Finished generating", so the produced-artifact check is
  // load-bearing, not belt-and-braces.
  if not File.fileExists(absOut) {
    releaseErr(
      "native-image exited 0 but no binary was produced at " + absOut +
        "; this usually means a config file was rejected — see the build output above, config left at " +
        configDir
    )
    return 1
  }
  val _ = File.deleteDirRecursive(configDir)

  // Report the path as the user spelled it, matching `buildReleaseDotnet`.
  Console.println("built native binary " + outPath)
  0
}

// ─── Standalone shape (self-contained, still JIT / interpreted) ──────────────
/// The placeholder the .NET apphost template embeds where the application
/// DLL name goes (the SHA-256 of "foobar", as in the SDK's HostWriter).
pub func apphostPlaceholder(): String = "c3ab8ff13720e8ad9047dd39466b3c8974e592c2fa383d4a3960714caef0c4f2"

// The embedded name slot in the apphost template is this many bytes.
val APPHOST_SLOT_BYTES: Int = 1024

/// Index of `needle` in `hay`, or -1.
pub func indexOfBytes(hay: in slice[Byte], needle: in slice[Byte]): Int {
  if needle.length == 0 or hay.length < needle.length {
    return -1
  }
  var i = 0
  val last = hay.length - needle.length
  while i <= last {
    var j = 0
    while j < needle.length and hay[i + j] == needle[j] {
      j += 1
    }
    if j == needle.length {
      return i
    }
    i += 1
  }
  -1
}

/// The apphost `host` with the application DLL name `appName` written over
/// its placeholder, as `dotnet publish` does.  The name is zero-padded; the
/// template reserves 1024 bytes for it.
pub func patchApphost(host: in slice[Byte], appName: in String): Result[slice[Byte], String] {
  val needle = Enc.encodeUtf8(apphostPlaceholder())
  val name = Enc.encodeUtf8(appName)
  if name.length == 0 or name.length >= APPHOST_SLOT_BYTES {
    return Err(error = "application name '" + appName + "' must be 1 to 1023 bytes long")
  }
  val at = indexOfBytes(host, needle)
  if at < 0 {
    return Err(error = "the apphost template does not contain the application-name placeholder")
  }
  if at + APPHOST_SLOT_BYTES > host.length {
    return Err(error = "the apphost template is truncated after the application-name placeholder")
  }
  val acc: List[Byte] = newList()
  var i = 0
  while i < host.length {
    if i >= at and i < at + name.length {
      acc.add(name[i - at])
    } else if i >= at and i < at + needle.length {
      acc.add((0).toByte())
    } else {
      acc.add(host[i])
    }
    i += 1
  }
  Ok(value = acc.toArray())
}

/// The `.runtimeconfig.json` of a self-contained program: the framework is
/// included in the directory rather than named for the host to resolve.
pub func standaloneRuntimeConfig(tfm: in String, frameworkVersion: in String): String {
  "{\n  \"runtimeOptions\": {\n    \"tfm\": \"" + tfm +
    "\",\n    \"includedFrameworks\": [\n      {\n        \"name\": \"Microsoft.NETCore.App\",\n        \"version\": \"" +
    frameworkVersion +
    "\"\n      }\n    ]\n  }\n}\n"
}

func versionCore(v: in String): String {
  match Str.indexOf(v, "-") {
    case Some(d) -> Str.substring(v, 0, d)
    case None -> v
  }
}

func versionPart(p: in String): Int {
  match Parse.tryParseInt(p) {
    case Ok(n) -> n
    case Err(_) -> 0
  }
}

/// Compare dotted numeric versions ("10.0.7" vs "10.0.12"); a pre-release
/// suffix ("-rc.1") is ignored.  Negative, zero or positive like a comparator.
pub func compareVersions(a: in String, b: in String): Int {
  val pa = Str.split(versionCore(a), ".")
  val pb = Str.split(versionCore(b), ".")
  var i = 0
  while i < pa.length or i < pb.length {
    val x = if i < pa.length { versionPart(pa[i]) } else { 0 }
    val y = if i < pb.length { versionPart(pb[i]) } else { 0 }
    if x != y {
      return if x < y { -1 } else { 1 }
    }
    i += 1
  }
  0
}

/// The highest of `names` (version-named directories) whose major version is
/// `major`, or the highest of all when `major` is 0.
pub func highestVersion(names: in List[String], major: in Int): Option[String] {
  var best: Option[String] = None
  for n in names {
    if major == 0 or semverMajor(n) == major {
      best = match best {
        case None -> Some(value = n)
        case Some(cur) -> if compareVersions(n, cur) > 0 { Some(value = n) } else { best }
      }
    }
  }
  best
}

/// Major version of a target framework moniker ("net10.0" -> 10), 0 if unknown.
pub func tfmMajor(tfm: in String): Int {
  if Str.startsWith(tfm, "net") {
    semverMajor(Str.substring(tfm, 3, tfm.length - 3))
  } else {
    0
  }
}

/// Why a `--shape standalone` .NET build cannot run on this host, or None.
/// The runtime bundled is the one installed here, so the program can only be
/// packaged for the host platform; the Windows and macOS layouts are not
/// supported yet.
pub func dotnetStandalonePreflightError(ridOpt: in Option[String], hostRid: in String): Option[String] {
  if hostRid == "" {
    return Some(value = "could not determine the host RID for the self-contained runtime")
  }
  match ridOpt {
    case Some(r) -> {
      if not isValidRid(r) {
        return Some(
          value = "invalid RID '" + r +
            "': a .NET RID must contain only lowercase letters, digits, dots, and hyphens (e.g. linux-x64)"
        )
      }
      if r != hostRid {
        return Some(
          value = "--shape standalone bundles the runtime installed on this machine, so it can only build for the host RID '" +
            hostRid +
            "' (requested '" +
            r +
            "'); build on a " +
            r +
            " machine"
        )
      }
    }
    case None -> ()
  }
  if ridOs(hostRid) != "linux" {
    return Some(
      value = "--shape standalone for --target dotnet is supported on Linux hosts only ('" + hostRid +
        "'); use --shape portable, or --shape aot on macOS"
    )
  }
  None
}

// The dotnet installation root: `$DOTNET_ROOT`, the root of the `dotnet`
// on `$PATH`, the running runtime's root, then the conventional locations.
func findDotnetRoot(os: in String): Option[String] {
  val candidates: List[String] = newList()
  val envRoot = Environment.getVarOrDefault("DOTNET_ROOT", "")
  if envRoot != "" {
    candidates.add(envRoot)
  }
  match findOnPath("dotnet", Environment.getVarOrDefault("PATH", ""), os) {
    case Some(p) -> {
      match File.realPath(p) {
        case Ok(real) -> candidates.add(Path.dirname(real))
        case Err(_) -> candidates.add(Path.dirname(p))
      }
    }
    case None -> ()
  }
  val rt = Environment.runtimeDirectory()
  if rt != "" {
    candidates.add(Path.dirname(Path.dirname(Path.dirname(rt))))
  }
  candidates.add(Path.join(Environment.getVarOrDefault("HOME", ""), ".dotnet"))
  candidates.add("/usr/share/dotnet")
  candidates.add("/usr/lib/dotnet")
  candidates.add("/usr/lib64/dotnet")
  candidates.add("/opt/dotnet")
  for c in candidates {
    if c != "" and File.dirExists(Path.join(Path.join(c, "shared"), "Microsoft.NETCore.App")) {
      return Some(value = c)
    }
  }
  None
}

func subdirNames(dir: in String): List[String] {
  val acc: List[String] = newList()
  match File.listDirs(dir) {
    case Ok(ds) -> {
      for d in ds {
        acc.add(Path.basename(d))
      }
    }
    case Err(_) -> ()
  }
  acc
}

func ensureDir(dir: in String): Result[Unit, String] {
  if File.dirExists(dir) {
    return Ok(value = ())
  }
  match File.createDir(dir) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "could not create " + dir + ": " + IOError.message(e))
  }
}

func copyFile(src: in String, dst: in String): Result[Unit, String] {
  match ensureDir(Path.dirname(dst)) {
    case Ok(_) -> ()
    case Err(m) -> return Err(error = m)
  }
  match File.readBytes(src) {
    case Err(e) -> Err(error = "could not read " + src + ": " + IOError.message(e))
    case Ok(bytes) -> match File.writeBytes(dst, bytes) {
      case Ok(_) -> Ok(value = ())
      case Err(e) -> Err(error = "could not write " + dst + ": " + IOError.message(e))
    }
  }
}

// Copy every file under `srcDir` into `dstDir`, keeping the relative layout.
func copyTree(srcDir: in String, dstDir: in String): Result[Unit, String] {
  val files = match File.listFilesRecursive(srcDir) {
    case Ok(fs) -> fs
    case Err(e) -> return Err(error = "could not list " + srcDir + ": " + IOError.message(e))
  }
  for f in files {
    val rel = Str.substring(f, srcDir.length, f.length - srcDir.length)
    val relClean = if Str.startsWith(rel, "/") { Str.substring(rel, 1, rel.length - 1) } else { rel }
    match copyFile(f, Path.join(dstDir, relClean)) {
      case Ok(_) -> ()
      case Err(m) -> return Err(error = m)
    }
  }
  Ok(value = ())
}

val STANDALONE_MARKER: String = ".lyric-standalone"

/// Prepare an empty `outDir`.  A directory a previous standalone build wrote
/// (it carries the marker) is replaced; anything else is never deleted.
pub func prepareStandaloneOutDir(outDir: in String): Result[Unit, String] {
  if File.fileExists(outDir) {
    return Err(error = "output path '" + outDir + "' is a file; --shape standalone writes a directory")
  }
  if File.dirExists(outDir) {
    if File.fileExists(Path.join(outDir, STANDALONE_MARKER)) {
      match File.deleteDirRecursive(outDir) {
        case Ok(_) -> ()
        case Err(e) -> return Err(error = "could not clear " + outDir + ": " + IOError.message(e))
      }
    } else {
      val entries = match File.listEntries(outDir) { case Ok(es) -> es.count; case Err(_) -> 1 }
      if entries > 0 {
        return Err(
          error = "output directory '" + outDir +
            "' already exists and was not written by a standalone build; remove it or pass a different -o"
        )
      }
    }
  }
  match ensureDir(outDir) {
    case Err(m) -> return Err(error = m)
    case Ok(_) -> ()
  }
  match File.writeText(Path.join(outDir, STANDALONE_MARKER), "written by lyric build --shape standalone\n") {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "could not write the marker in " + outDir + ": " + IOError.message(e))
  }
}

// `Err(message)` after reporting it, so callers can `return 1`.
func failWith(m: in String): Int {
  releaseErr(m)
  1
}

/// Package a built .NET program as a self-contained directory.
///
/// `programDll` is the portable build; its directory (the program, the
/// stdlib and every reference the build staged beside it) and `extraRefs`
/// are copied into
/// `outDir` together with the installed shared runtime, `hostfxr` and an
/// apphost patched to start the program, so the directory runs on a machine
/// with no .NET installed.  `outDir/<exeName>` is the executable.
pub func buildStandaloneDotnet(
  programDll: in String,
  extraRefs: in List[String],
  ridOpt: in Option[String],
  outDir: in String,
  exeName: in String,
): Int {
  val hostRid = Environment.runtimeIdentifier()
  match dotnetStandalonePreflightError(ridOpt, hostRid) {
    case Some(msg) -> return failWith(msg)
    case None -> ()
  }
  val absDll = absPath(programDll)
  val stageDir = Path.dirname(absDll)
  val dllName = Path.basename(absDll)
  val root = match findDotnetRoot("linux") {
    case Some(r) -> r
    case None -> return failWith(
      "no .NET installation found to bundle (looked at $DOTNET_ROOT, the dotnet on $PATH and the usual install directories)"
    )
  }
  val runtimesDir = Path.join(Path.join(root, "shared"), "Microsoft.NETCore.App")
  val configName = Str.substring(dllName, 0, dllName.length - 4) + ".runtimeconfig.json"
  val configText = match File.readText(Path.join(stageDir, configName)) { case Ok(t) -> t; case Err(_) -> "" }
  val tfm = match jsonStringField(configText, "tfm") { case Some(t) -> t; case None -> "net10.0" }
  val wantMajor = tfmMajor(tfm)
  val runtimeVer = match highestVersion(subdirNames(runtimesDir), wantMajor) {
    case Some(v) -> v
    case None -> return failWith(
      "no Microsoft.NETCore.App " + (if wantMajor > 0 { toString(wantMajor) + ".x " } else { "" }) +
        "runtime is installed under " +
        runtimesDir
    )
  }
  val fxrRoot = Path.join(Path.join(root, "host"), "fxr")
  val fxrVer = match highestVersion(subdirNames(fxrRoot), wantMajor) {
    case Some(v) -> v
    case None -> return failWith("no hostfxr is installed under " + fxrRoot)
  }
  val hostPackRoot = Path.join(Path.join(root, "packs"), "Microsoft.NETCore.App.Host." + hostRid)
  val hostPackVer = match highestVersion(subdirNames(hostPackRoot), wantMajor) {
    case Some(v) -> v
    case None -> return failWith(
      "the apphost pack Microsoft.NETCore.App.Host." + hostRid + " is not installed under " + hostPackRoot +
        " (it ships with the .NET SDK)"
    )
  }
  val apphostPath = Path.join(
    Path.join(
      Path.join(Path.join(Path.join(hostPackRoot, hostPackVer), "runtimes"), hostRid),
      "native"
    ),
    "apphost"
  )
  val apphost = match File.readBytes(apphostPath) {
    case Ok(b) -> b
    case Err(e) -> return failWith("could not read " + apphostPath + ": " + IOError.message(e))
  }
  val patched = match patchApphost(apphost, dllName) { case Ok(b) -> b; case Err(m) -> return failWith(m) }
  val absOut = absPath(outDir)
  match prepareStandaloneOutDir(absOut) {
    case Ok(_) -> ()
    case Err(m) -> return failWith(m)
  }
  Console.println("release: bundling .NET " + runtimeVer + " (" + hostRid + ") ...")
  match copyTree(Path.join(runtimesDir, runtimeVer), absOut) {
    case Ok(_) -> ()
    case Err(m) -> return failWith(m)
  }
  match copyTree(Path.join(fxrRoot, fxrVer), absOut) {
    case Ok(_) -> ()
    case Err(m) -> return failWith(m)
  }
  match copyTree(stageDir, absOut) {
    case Ok(_) -> ()
    case Err(m) -> return failWith(m)
  }
  // References the build resolved outside the staging directory (workspace
  // and restored packages, third-party assemblies).
  for ref in extraRefs {
    match copyFile(absPath(ref), Path.join(absOut, Path.basename(ref))) {
      case Ok(_) -> ()
      case Err(m) -> return failWith(m)
    }
  }
  // The portable runtimeconfig names a shared framework; replace it.
  match File.writeText(Path.join(absOut, configName), standaloneRuntimeConfig(tfm, runtimeVer)) {
    case Ok(_) -> ()
    case Err(e) -> return failWith("could not write the runtimeconfig: " + IOError.message(e))
  }
  val exePath = Path.join(absOut, exeName)
  match File.writeBytes(exePath, patched) {
    case Ok(_) -> ()
    case Err(e) -> return failWith("could not write " + exePath + ": " + IOError.message(e))
  }
  match File.setExecutable(exePath) {
    case Ok(_) -> ()
    case Err(e) -> return failWith("could not mark " + exePath + " executable: " + IOError.message(e))
  }
  // `createdump` is an executable the runtime spawns on a crash.
  val dump = Path.join(absOut, "createdump")
  if File.fileExists(dump) {
    val _ = File.setExecutable(dump)
  }
  Console.println("built standalone directory " + outDir + " (run " + Path.join(outDir, exeName) + ")")
  0
}

// ─── Standalone, JVM: jlink runtime image + launcher ─────────────────────────
/// Why a `--shape standalone` JVM build cannot run on this host, or None.
/// The runtime image is built from the JDK that runs `jlink`, so it can only
/// target the host; the launcher is a POSIX shell script.
pub func jvmStandalonePreflightError(ridOpt: in Option[String], hostRid: in String): Option[String] {
  if hostRid == "" {
    return Some(value = "could not determine the host platform for the jlink runtime image")
  }
  match ridOpt {
    case Some(r) -> {
      if not isValidRid(r) {
        return Some(
          value = "invalid RID '" + r +
            "': a RID must contain only lowercase letters, digits, dots, and hyphens (e.g. linux-x64)"
        )
      }
      if not ridMatchesHost(r, hostRid) {
        return Some(
          value = "--shape standalone for --target jvm builds a jlink image of the JDK on this machine, so it can only build for the host RID '" +
            hostRid +
            "' (requested '" +
            r +
            "'); build on a " +
            r +
            " machine"
        )
      }
    }
    case None -> ()
  }
  val os = ridOs(hostRid)
  if os != "linux" and os != "osx" {
    return Some(value = "'" + hostRid + "' is not supported for --shape standalone --target jvm (Linux and macOS only)")
  }
  None
}

/// The launcher written beside the runtime image: resolves its own directory
/// (following symlinks), then starts the bundled JVM on the program classes.
pub func standaloneLauncherScript(mainClass: in String): String {
  "#!/bin/sh\n" + "# Generated by lyric build --shape standalone.\n" + "self=\"$0\"\n" + "while [ -h \"$self\" ]; do\n" +
    "  dir=$(cd \"$(dirname \"$self\")\" && pwd -P)\n" +
    "  target=$(readlink \"$self\")\n" +
    "  case \"$target\" in /*) self=\"$target\" ;; *) self=\"$dir/$target\" ;; esac\n" +
    "done\n" +
    "here=$(cd \"$(dirname \"$self\")\" && pwd -P)\n" +
    "exec \"$here/runtime/bin/java\" --enable-native-access=ALL-UNNAMED -cp \"$here/lib/*\" " +
    mainClass +
    " \"$@\"\n"
}

/// `jlink` arguments for a runtime image holding `modules` at `imageDir`.
pub func buildJlinkArgs(modules: in String, imageDir: in String): List[String] {
  val a: List[String] = newList()
  a.add("--add-modules")
  a.add(modules)
  a.add("--output")
  a.add(imageDir)
  a.add("--strip-debug")
  a.add("--no-header-files")
  a.add("--no-man-pages")
  a
}

// "Proj.dll" -> "Proj".
func jarStem(base: in String): String {
  match Str.lastIndexOf(base, ".") {
    case Some(d) -> if d > 0 { Str.substring(base, 0, d) } else { base }
    case None -> base
  }
}

func findJdkTool(name: in String, os: in String): Result[String, String] {
  val home = Environment.getVarOrDefault("JAVA_HOME", "")
  if home != "" {
    val p = Path.join(Path.join(home, "bin"), name)
    if File.fileExists(p) {
      return Ok(value = p)
    }
  }
  match findOnPath(name, Environment.getVarOrDefault("PATH", ""), os) {
    case Some(p) -> Ok(value = p)
    case None -> Err(
      error = name +
        " not found ($JAVA_HOME/bin and $PATH); --shape standalone --target jvm needs a full JDK 21 or later (with the jmods)"
    )
  }
}

/// The comma-separated module list for `jlink`: what `jdeps` reported plus
/// `java.base` and the modules the runtime support classes reach without a
/// static reference `jdeps` can follow (HTTP and TLS, the EC provider, zip
/// file systems, logging, `sun.misc.Unsafe`).
pub func jlinkModules(jdepsOutput: in String): String {
  val seen: List[String] = newList()
  seen.add("java.base")
  for part in Str.split(Str.trim(jdepsOutput), ",") {
    seen.add(Str.trim(part))
  }
  seen.add("java.net.http")
  seen.add("jdk.crypto.ec")
  seen.add("jdk.zipfs")
  seen.add("java.logging")
  seen.add("jdk.unsupported")
  val uniq: List[String] = newList()
  for m in seen {
    if m != "" {
      var dup = false
      for u in uniq {
        if u == m {
          dup = true
        }
      }
      if not dup {
        uniq.add(m)
      }
    }
  }
  var acc = ""
  for m in uniq {
    acc = if acc == "" { m } else { acc + "," + m }
  }
  acc
}

/// The text of the JAR manifest with line continuations ("\n ") joined.
pub func unfoldManifest(text: in String): String {
  Str.replace(Str.replace(text, "\r\n", "\n"), "\n ", "")
}

/// The value of manifest attribute `key` in an unfolded manifest, or "".
pub func manifestAttribute(unfolded: in String, key: in String): String {
  for line in Str.split(unfolded, "\n") {
    if Str.startsWith(line, key + ": ") {
      return Str.trim(Str.substring(line, key.length + 2, line.length - key.length - 2))
    }
  }
  ""
}

func readJarManifest(jar: in String): Result[String, String] {
  val data = match File.readBytes(jar) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "could not read " + jar + ": " + IOError.message(e))
  }
  val entries = match Zip.readZipDirectory(data, Zip.defaultZipLimits()) {
    case Ok(es) -> es
    case Err(e) -> return Err(error = "could not read the entries of " + jar + ": " + Zip.zipErrorMessage(e))
  }
  for en in entries {
    if en.name == "META-INF/MANIFEST.MF" {
      return match Zip.readZipEntry(data, en) {
        case Ok(b) -> match Enc.tryDecodeUtf8(b) {
          case Some(t) -> Ok(value = unfoldManifest(t))
          case None -> Err(error = "the manifest of " + jar + " is not UTF-8")
        }
        case Err(e) -> Err(error = "could not read the manifest of " + jar + ": " + Zip.zipErrorMessage(e))
      }
    }
  }
  Err(error = jar + " has no META-INF/MANIFEST.MF")
}

/// Package a built JVM program as a self-contained directory:
/// `outDir/<exeName>` (launcher), `outDir/runtime/` (a `jlink` image) and
/// `outDir/lib/` (the program JAR and the Maven jars it refers to).
pub func buildStandaloneJvm(
  jarPath: in String,
  extraJars: in List[String],
  ridOpt: in Option[String],
  outDir: in String,
  exeName: in String,
): Int {
  val absJar = absPath(jarPath)
  if not File.fileExists(absJar) {
    return failWith("JAR not found at " + absJar)
  }
  val hostRid = Environment.runtimeIdentifier()
  match jvmStandalonePreflightError(ridOpt, hostRid) {
    case Some(msg) -> return failWith(msg)
    case None -> ()
  }
  val os = ridOs(hostRid)
  val jlink = match findJdkTool("jlink", os) { case Ok(p) -> p; case Err(m) -> return failWith(m) }
  val jdeps = match findJdkTool("jdeps", os) { case Ok(p) -> p; case Err(m) -> return failWith(m) }
  val manifest = match readJarManifest(absJar) { case Ok(m) -> m; case Err(m) -> return failWith(m) }
  val mainClass = manifestAttribute(manifest, "Main-Class")
  if mainClass == "" {
    return failWith(absJar + " has no Main-Class in its manifest")
  }
  // Jars the program refers to: the restored Maven jars named by the
  // manifest's Class-Path, then the ones the caller passed.
  val libJars: List[String] = newList()
  libJars.add(absJar)
  for tok in Str.split(manifestAttribute(manifest, "Class-Path"), " ") {
    val t = if Str.startsWith(tok, "file:") { Str.substring(tok, 5, tok.length - 5) } else { tok }
    if t != "" and File.fileExists(t) {
      libJars.add(t)
    }
  }
  for e in extraJars {
    libJars.add(absPath(e))
  }
  val absOut = absPath(outDir)
  match prepareStandaloneOutDir(absOut) {
    case Ok(_) -> ()
    case Err(m) -> return failWith(m)
  }
  // Stage the jars under `lib/` first: both `jdeps` and the `lib/*` classpath
  // of the launcher need the `.jar` suffix, and the project path names its
  // staging artifact after `output_assembly`, which is often `*.dll`.
  val libDir = Path.join(absOut, "lib")
  val staged: List[String] = newList()
  for j in libJars {
    val base = Path.basename(j)
    val libName = if Str.endsWith(base, ".jar") { base } else { jarStem(base) + ".jar" }
    val dst = Path.join(libDir, libName)
    match copyFile(j, dst) {
      case Ok(_) -> ()
      case Err(m) -> return failWith(m)
    }
    staged.add(dst)
  }
  val depArgs: List[String] = newList()
  depArgs.add("--print-module-deps")
  depArgs.add("--ignore-missing-deps")
  depArgs.add("--multi-release")
  depArgs.add("base")
  var cp = ""
  for j in staged {
    cp = if cp == "" { j } else { cp + classpathSeparator(os) + j }
  }
  depArgs.add("--class-path")
  depArgs.add(cp)
  depArgs.add(staged[0])
  val deps = PC.runCaptureWithDiagnosticsTimeout(jdeps, depArgs, "", 300000)
  if deps.exitCode != 0 or deps.timedOut {
    if deps.stderr != "" {
      Console.error(deps.stderr)
    }
    return failWith("jdeps could not analyse " + absJar + (if deps.timedOut { " (timed out)" } else { "" }))
  }
  val modules = jlinkModules(deps.stdout)
  Console.println("release: building a jlink runtime image (" + modules + ") ...")
  val link = PC.runCaptureWithDiagnosticsTimeout(
    jlink,
    buildJlinkArgs(modules, Path.join(absOut, "runtime")),
    "",
    600000
  )
  if link.stdout != "" {
    Console.println(link.stdout)
  }
  if link.exitCode != 0 or link.timedOut {
    if link.stderr != "" {
      Console.error(link.stderr)
    }
    return failWith(
      "jlink failed" + (if link.timedOut { " (timed out)" } else { " with exit code " + toString(link.exitCode) })
    )
  }
  val exePath = Path.join(absOut, exeName)
  match File.writeText(exePath, standaloneLauncherScript(mainClass)) {
    case Ok(_) -> ()
    case Err(e) -> return failWith("could not write " + exePath + ": " + IOError.message(e))
  }
  match File.setExecutable(exePath) {
    case Ok(_) -> ()
    case Err(e) -> return failWith("could not mark " + exePath + " executable: " + IOError.message(e))
  }
  Console.println("built standalone directory " + outDir + " (run " + Path.join(outDir, exeName) + ")")
  0
}

/// Target-agnostic release entry point.  Dispatches to the .NET AOT path
/// (`ilc` + platform linker) or the JVM path (GraalVM `native-image`).  Both
/// arms produce a standalone binary or fail — neither falls back to a managed
/// artifact.
///
/// `programArtifact` is the already-built managed input: a `.dll` for
/// `DotnetAot`, a bundled `.jar` for `JvmNativeImage`.  `extraRefs` are the
/// matching auxiliary inputs (ILC `-r:` references / extra classpath jars).
pub func buildRelease(
  target: in ReleaseTarget,
  programArtifact: in String,
  extraRefs: in List[String],
  ridOpt: in Option[String],
  outPath: in String,
): Int {
  match target {
    case DotnetAot -> buildReleaseDotnet(programArtifact, extraRefs, ridOpt, outPath)
    case JvmNativeImage -> buildReleaseJvm(programArtifact, extraRefs, ridOpt, outPath)
    case DotnetStandalone -> buildStandaloneDotnet(programArtifact, extraRefs, ridOpt, outPath, Path.basename(outPath))
    case JvmStandalone -> buildStandaloneJvm(programArtifact, extraRefs, ridOpt, outPath, Path.basename(outPath))
  }
}
