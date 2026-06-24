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

// Whether the entry `main` is declared to return `Int` (vs `Unit`/void).
// Still exposed for callers that need to surface this information, but
// no longer required by `buildReleaseDotnet` (ILC reads the entry point
// token directly from the PE metadata).
pub func mainReturnsInt(source: in String): Bool {
  val lines = Str.split(source, "\n")
  var inTripleString = false
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    if not inTripleString and (Str.startsWith(line, "func main") or Str.startsWith(line, "pub func main")) {
      val afterMain = Str.trim(afterToken(line, "main"))
      if Str.startsWith(afterMain, "()") {
        val afterParen = Str.trim(afterToken(afterMain, "()"))
        if Str.startsWith(afterParen, ":") {
          val retPart = Str.trim(afterToken(afterParen, ":"))
          // Exact `Int`, not a prefix of a longer type name (`IntFoo`): the
          // type token must be followed by a delimiter or end-of-string.
          if Str.startsWith(retPart, "Int") {
            val rest = Str.substring(retPart, 3, Str.length(retPart) - 3)
            if rest == "" or Str.startsWith(rest, " ") or Str.startsWith(rest, "\t") or Str.startsWith(rest, "{") or Str.startsWith(rest, "(") {
              return true
            }
          }
        }
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

// Copy `src` to `dst` preserving the executable bit (native binaries must stay
// runnable).
func copyExecutable(src: in String, dst: in String): Result[Unit, String] {
  val args: List[String] = newList()
  args.add("-p")
  args.add(src)
  args.add(dst)
  match Process.run("cp", args) {
    case Ok(code) -> if code == 0 { Ok(value = ()) } else { Err(error = "cp exited " + toString(code)) }
    case Err(e) -> Err(error = "cp failed: " + IOError.message(e))
  }
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
func probeProjectContent(rid: in String): String {
  "<Project Sdk=\"Microsoft.NET.Sdk\">\n" +
    "  <PropertyGroup>\n" +
    "    <OutputType>Exe</OutputType>\n" +
    "    <TargetFramework>net10.0</TargetFramework>\n" +
    "    <PublishAot>true</PublishAot>\n" +
    "    <RuntimeIdentifier>" + rid + "</RuntimeIdentifier>\n" +
    "    <EnableDefaultCompileItems>false</EnableDefaultCompileItems>\n" +
    "  </PropertyGroup>\n" +
    "</Project>\n"
}

// Extract the value of a `"key": "value"` JSON string field.
// Finds the first occurrence of `"<key>":` and returns the quoted value after it.
// Only handles simple string values (no nested objects).
func jsonStringField(json: in String, key: in String): Option[String] {
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
        case Some(closeIdx) -> Some(value = Str.substring(inner, 0, closeIdx))
      }
    }
  }
}

// Extract the ILC version from the `libraries` section of `project.assets.json`.
// The key has the form `"runtime.<RID>.Microsoft.DotNet.ILCompiler/<version>"`.
func parseIlcVersion(assetsJson: in String, rid: in String): Option[String] {
  val prefix = "\"runtime." + rid + ".Microsoft.DotNet.ILCompiler/"
  match Str.indexOf(assetsJson, prefix) {
    case None -> None
    case Some(i) -> {
      val start = i + Str.length(prefix)
      val rest = Str.substring(assetsJson, start, Str.length(assetsJson) - start)
      match Str.indexOf(rest, "\"") {
        case None -> None
        case Some(endIdx) -> Some(value = Str.substring(rest, 0, endIdx))
      }
    }
  }
}

// Major version number from a semver string like "10.0.7" → 10.
func semverMajor(version: in String): Int {
  match Str.indexOf(version, ".") {
    case None -> 0
    case Some(dot) -> match Parse.tryParseInt(Str.substring(version, 0, dot)) {
      case Ok(n) -> n
      case Err(_) -> 0
    }
  }
}

// Restore the ILC probe project and return the NuGet packages directory and
// ILC version.  The probe project lives under `<stageDir>/ilc-probe/`.
// Returns Err with a diagnostic message on any failure.
func restoreIlcProbe(stageDir: in String, rid: in String): Result[IlcPaths, String] {
  val probeDir = Path.join(stageDir, "ilc-probe")
  match File.createDir(probeDir) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = "could not create ILC probe dir: " + IOError.message(e))
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
  val restoreResult = PC.runCaptureWithDiagnosticsTimeout("dotnet", restoreArgs, "", 120000)
  if restoreResult.exitCode != 0 {
    return Err(
      error = "dotnet restore for ILC toolchain failed (exit " + toString(restoreResult.exitCode) + "):\n" +
        restoreResult.stdout + restoreResult.stderr
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
        "Ensure the .NET NativeAOT workload is installed: `dotnet workload install wasm-tools` or check " +
        "`dotnet workload list`"
    )
  }

  // ILC binary: runtime.<RID>.Microsoft.DotNet.ILCompiler/<version>/tools/ilc
  val ilcBin = Path.join(
    Path.join(
      Path.join(Path.join(pkgsDir, "runtime." + rid + ".microsoft.dotnet.ilcompiler"), ilcVersion),
      "tools"
    ),
    "ilc"
  )
  if not File.fileExists(ilcBin) {
    return Err(error = "ILC binary not found at '" + ilcBin + "'")
  }

  // NativeAOT runtime pack: microsoft.netcore.app.runtime.nativeaot.<RID>/<version>
  // Version matches the ILC version; this package carries the pre-compiled native libs.
  val major = semverMajor(ilcVersion)
  val tfm = "net" + toString(major) + ".0"
  val nativeaotRoot = Path.join(
    Path.join(
      Path.join(Path.join(pkgsDir, "microsoft.netcore.app.runtime.nativeaot." + rid), ilcVersion),
      "runtimes"
    ),
    rid
  )
  val sdkPath = Path.join(nativeaotRoot, "native")
  val frameworkPath = Path.join(Path.join(nativeaotRoot, "lib"), tfm)

  if not File.dirExists(Path.join(nativeaotRoot, "native")) {
    return Err(
      error = "NativeAOT runtime pack not found at '" + nativeaotRoot + "'. " +
        "Expected microsoft.netcore.app.runtime.nativeaot." + rid + "/" + ilcVersion + " in " + pkgsDir
    )
  }

  Ok(value = IlcPaths(ilcBin = ilcBin, sdkPath = sdkPath, frameworkPath = frameworkPath))
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
  lines.add("--feature:System.ComponentModel.TypeConverter.EnableUnsafeBinaryFormatterInDesigntimeLicenseContextSerialization=false")
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
  lines.add("--runtimeknob:System.ComponentModel.TypeConverter.EnableUnsafeBinaryFormatterInDesigntimeLicenseContextSerialization=false")
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
  lines.add("--runtimeknob:System.Runtime.InteropServices.Marshalling.EnableGeneratedComInterfaceComImportInterop=false")
  lines.add("--runtimeknob:System.Runtime.Serialization.EnableUnsafeBinaryFormatterSerialization=false")
  lines.add("--runtimeknob:System.StartupHookProvider.IsSupported=false")
  lines.add("--runtimeknob:System.Text.Encoding.EnableUnsafeUTF7Encoding=false")
  lines.add("--runtimeknob:System.Text.Json.JsonSerializer.IsReflectionEnabledByDefault=false")
  lines.add("--runtimeknob:System.Threading.Thread.EnableAutoreleasePool=false")
  lines.add("--runtimeknob:System.Linq.Expressions.CanEmitObjectArrayDelegate=false")
}

// Extract the OS component from a .NET RID: "linux-x64" → "linux",
// "osx-arm64" → "osx", "win-x64" → "windows".
func ridOs(rid: in String): String {
  match Str.indexOf(rid, "-") {
    case None -> rid
    case Some(i) -> {
      val os = Str.substring(rid, 0, i)
      if os == "osx" { "osx" } else if os == "win" { "windows" } else { os }
    }
  }
}

// Extract the arch component from a .NET RID: "linux-x64" → "x64",
// "linux-arm64" → "arm64", "osx-x64" → "x64".
func ridArch(rid: in String): String {
  match Str.indexOf(rid, "-") {
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
      return Err(
        error = "could not enumerate framework DLLs from '" + paths.frameworkPath + "': " + IOError.message(e)
      )
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
    if File.fileExists(p) {
      lines.add(p)
    }
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
  args.add("-gz=zlib")
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
  args.add("-Wl,-pie")
  args.add("-Wl,-z,relro")
  args.add("-Wl,-z,now")

  // Required system libraries
  args.add("-pthread")
  args.add("-ldl")
  args.add("-lrt")
  args.add("-lm")

  args
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

  // Ensure the ILC toolchain is present in the NuGet cache and discover its paths.
  Console.println("release: resolving ILC toolchain for " + rid + " ...")
  val paths = match restoreIlcProbe(stageDir, rid) {
    case Ok(p) -> p
    case Err(msg) -> {
      releaseErr(msg)
      return 1
    }
  }

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
    return 1
  }
  if ilcResult.exitCode != 0 {
    releaseErr("ilc exited " + toString(ilcResult.exitCode))
    return 1
  }
  if not File.fileExists(objFile) {
    releaseErr("ilc did not produce object file at " + objFile)
    return 1
  }

  // Run platform linker.
  val arch = ridArch(rid)
  val os = ridOs(rid)
  if os == "windows" {
    releaseErr("Windows native linking is not yet implemented; tracked in #1975")
    return 1
  }
  Console.println("release: linking native binary ...")
  val linkerArgs = buildLinkerArgsUnix(objFile, exportsFile, outPath, paths.sdkPath, arch)
  val linkResult = PC.runCaptureWithDiagnosticsTimeout("clang", linkerArgs, "", 300000)
  if linkResult.stdout != "" {
    Console.println(linkResult.stdout)
  }
  if linkResult.stderr != "" {
    Console.error(linkResult.stderr)
  }
  if linkResult.timedOut {
    releaseErr("linker timed out after 5 minutes")
    return 1
  }
  if linkResult.exitCode != 0 {
    releaseErr("clang linker exited " + toString(linkResult.exitCode))
    return 1
  }

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
