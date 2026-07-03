//! release.l — `lyric build --release` native-binary pipeline.
//!
//! Produces a self-contained, optimized, standalone native executable from a
//! compiled Lyric program — no managed runtime required on the target machine.
//! Plain `lyric build` keeps emitting the fast framework-dependent DLL (the
//! inner loop); `--release` is the deployable-artifact path.
//!
//! .NET target (DotnetAot): drives `ilc` (the .NET IL-to-native compiler) and
//! the platform linker (`clang` on Unix) directly from Lyric — no generated C#,
//! no `dotnet publish`.  The Lyric MSIL emitter already sets `EntryPointToken`
//! in the PE metadata to the program's `main()` method; `ilc` roots from this
//! token and produces a native object file.  A one-time `dotnet restore` on a
//! minimal probe `.csproj` seeds the NuGet cache and lets us discover the ILC
//! toolchain version via `project.assets.json`.
//!
//! JVM target (JvmNativeImage): the release path is GraalVM `native-image` over
//! the bundled JAR.  The seam is defined here so the dispatcher is target-
//! agnostic; the toolchain invocation is not yet implemented (#1975) and fails
//! loud rather than silently producing a managed artifact.
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

// Release target selector.  `buildRelease` is target-agnostic; each arm owns
// its toolchain invocation so adding the GraalVM path later does not touch the
// dispatcher or the .NET path.
pub union ReleaseTarget {
  case DotnetAot
  case JvmNativeImage
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

/// Extract the `package X` name from Lyric source text — the first line that
/// begins with `package `.  Returns "" if absent.
pub func packageNameOf(source: in String): String {
  val lines = Str.split(source, "\n")
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    if Str.startsWith(line, "package ") {
      val raw = Str.trim(Str.substring(line, 8, Str.length(line) - 8))
      // Strip any inline // comment from the package name so that a line
      // like `package Demo // entry point` yields "Demo", not "Demo // entry point".
      return match Str.indexOf(raw, "//") { case Some(idx) -> Str.trim(Str.substring(raw, 0, idx)); case None -> raw }
    }
    i += 1
  }
  ""
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
pub func declaresEntryMain(source: in String): Bool {
  val lines = Str.split(source, "\n")
  var inTripleString = false
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    // Match `func main()` / `pub func main()` with an empty parameter list,
    // tolerating whitespace before the `(`.
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
        case None -> match Str.lastIndexOf(graphPath, "\\sdk\\") { case Some(idx) -> Some(value = Str.substring(graphPath, 0, idx) + "\\packs"); case None -> None }
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
            case Some(packsDir) -> "  - SDK pack 1: " + optPathOrNotAttempted(packIlc1Opt) + "\n  - SDK pack 2: " + optPathOrNotAttempted(packIlc2Opt)
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
            case Some(packsDir) -> "  - SDK pack 1: " + optPathOrNotAttempted(packNativeAot1Opt) + "\n  - SDK pack 2: " + optPathOrNotAttempted(packNativeAot2Opt)
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
  val clangVersionArgs: List[String] = newList()
  clangVersionArgs.add("--version")
  val clangCheck = PC.runCaptureWithDiagnosticsTimeout("clang", clangVersionArgs, "", 10000)
  if clangCheck.timedOut or clangCheck.exitCode != 0 {
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
    val ldBfdArgs: List[String] = newList()
    ldBfdArgs.add("--version")
    val ldBfdCheck = PC.runCaptureWithDiagnosticsTimeout("ld.bfd", ldBfdArgs, "", 10000)
    if ldBfdCheck.timedOut or ldBfdCheck.exitCode != 0 {
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

/// Target-agnostic release entry point.  Dispatches to the .NET AOT path or the
/// JVM GraalVM path.  The JVM arm is not yet implemented and fails loud (#1975)
/// rather than silently producing a non-native artifact.
pub func buildRelease(
  target: in ReleaseTarget,
  programDll: in String,
  extraRefs: in List[String],
  ridOpt: in Option[String],
  outPath: in String,
): Int {
  match target {
    case DotnetAot -> buildReleaseDotnet(programDll, extraRefs, ridOpt, outPath)
    case JvmNativeImage -> {
      releaseErr("`--release --target jvm` (GraalVM native-image) is not yet implemented; tracked in #1975")
      1
    }
  }
}
