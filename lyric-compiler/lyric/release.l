//! release.l — `lyric build --release` native-binary pipeline.
//!
//! Produces a self-contained, optimized, standalone native executable from a
//! compiled Lyric program — no managed runtime required on the target machine.
//! Plain `lyric build` keeps emitting the fast framework-dependent DLL (the
//! inner loop); `--release` is the deployable-artifact path.
//!
//! .NET target (DotnetAot): mirrors the compiler's own AOT entry-point pattern
//! (bootstrap/src/Lyric.Cli.Aot).  We generate a tiny host project that
//! references the already-built program DLL(s) + the stdlib bundle (+ restored
//! dependency DLLs), with a C# trampoline into the program's emitted
//! `<package>.Program.main()`, then run `dotnet publish -p:PublishAot=true`.
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
// before Path so Path.join/2 wins over Str.join (overload resolution)
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Lyric.Pack as Pack

// Release target selector.  `buildRelease` is target-agnostic; each arm owns
// its toolchain invocation so adding the GraalVM path later does not touch the
// dispatcher or the .NET path.
pub union ReleaseTarget {
  case DotnetAot
  case JvmNativeImage
}

func releaseErr(message: in String): Unit {
  Console.error("release: " + message)
}

// The host assembly name is deliberately distinct from any user package name:
// ILC resolves assembly identities case-insensitively, so a host named after
// the program (e.g. `prog` vs the program's `Prog`) would shadow the program's
// `<pkg>.Program` type and the entry trampoline would fail to load at runtime.
func hostAssemblyName(): String {
  "__lyric_aot_host"
}

/// Extract the `package X` name from Lyric source text — the first line that
/// begins with `package `.  Returns "" if absent.  The trampoline targets
/// `<package>.Program.main()`, so this is how we name the entry type.
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
// no params).  Will be used to pick the entry package in a multi-package
// project when that feature is wired up.
pub func declaresEntryMain(source: in String): Bool {
  val lines = Str.split(source, "\n")
  var i = 0
  while i < lines.length {
    val line = Str.trim(lines[i])
    // Match `func main()` / `pub func main()` with an empty parameter list,
    // tolerating whitespace before the `(`.
    if (Str.startsWith(line, "func main") or Str.startsWith(line, "pub func main")) {
      val afterMain = afterToken(line, "main")
      val trimmed = Str.trim(afterMain)
      if Str.startsWith(trimmed, "()") {
        return true
      }
    }
    i += 1
  }
  false
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

// Locate the stdlib bundle (`Lyric.Stdlib.dll`).  Probe the program DLL's own
// directory first (project-mode bundles sit beside it), then the running
// binary's base directory (where the SDK ships the bundle).
func locateStdlib(programDllDir: in String): Option[String] {
  val candidates: List[String] = newList()
  candidates.add(Path.join(programDllDir, "Lyric.Stdlib.dll"))
  candidates.add(Path.join(Environment.appBaseDirectory(), "Lyric.Stdlib.dll"))
  var i = 0
  while i < candidates.count {
    if File.fileExists(candidates[i]) {
      return Some(value = candidates[i])
    }
    i += 1
  }
  None
}

func referenceXml(dllPath: in String): String {
  "    <Reference Include=\"" + Pack.xmlEscape(dllPath) + "\"><Private>true</Private></Reference>\n"
}

// Write the AOT host project.  `refDlls` are absolute paths to every managed
// assembly the program needs at link time.  `ridValue` is either an explicit
// RID or the MSBuild auto-detect property for the host RID.
func writeHostProject(hostDir: in String, refDlls: in List[String], ridValue: in String): Result[Unit, String] {
  var refs = ""
  var i = 0
  while i < refDlls.count {
    refs = refs + referenceXml(refDlls[i])
    i += 1
  }
  val csproj = "<Project Sdk=\"Microsoft.NET.Sdk\">\n" + "  <PropertyGroup>\n" + "    <OutputType>Exe</OutputType>\n" +
    "    <TargetFramework>net10.0</TargetFramework>\n" +
    "    <AssemblyName>" +
    hostAssemblyName() +
    "</AssemblyName>\n" +
    "    <Nullable>enable</Nullable>\n" +
    "    <PublishAot>true</PublishAot>\n" +
    "    <RuntimeIdentifier>" +
    ridValue +
    "</RuntimeIdentifier>\n" +
    "    <!-- Surface ILC trim/AOT warnings to the user without failing the build. -->\n" +
    "    <IlcTreatWarningsAsErrors>false</IlcTreatWarningsAsErrors>\n" +
    "  </PropertyGroup>\n" +
    "  <ItemGroup>\n" +
    refs +
    "  </ItemGroup>\n" +
    "</Project>\n"
  match File.writeText(Path.join(hostDir, "host.csproj"), csproj) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "could not write host.csproj: " + IOError.message(e))
  }
}

// Write the C# trampoline whose `Main` forwards into the program's emitted
// zero-arg `<pkgName>.Program.main()`.
func writeTrampoline(hostDir: in String, pkgName: in String): Result[Unit, String] {
  val cs = "// Generated by `lyric build --release`.  Trampoline into the Lyric\n" +
    "// program's emitted entry point.\n" +
    "public static class LyricAotEntry {\n" +
    "    public static int Main(string[] args) => " +
    pkgName +
    ".Program.main();\n" +
    "}\n"
  match File.writeText(Path.join(hostDir, "Trampoline.cs"), cs) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "could not write trampoline: " + IOError.message(e))
  }
}

// Copy `src` to `dst` preserving the executable bit (native binaries must stay
// runnable).  Uses `cp -p`; the AOT host RID is always the current platform, so
// a POSIX copy is sufficient for the .NET-on-Unix path.  Windows packaging is
// tracked under #1975.
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

/// Produce a native binary from an already-built program DLL via .NET Native AOT.
///
/// `programDll` — absolute path to the compiled program (single DLL for a
///   single-file build, or the bundled project DLL).
/// `pkgName` — the package whose `Program.main()` is the entry point.
/// `extraRefs` — additional managed DLLs to reference (restored deps).
/// `ridOpt` — explicit RID, or None to auto-detect the host RID.
/// `outPath` — destination for the native binary.
pub func buildReleaseDotnet(
  programDll: in String,
  pkgName: in String,
  extraRefs: in List[String],
  ridOpt: in Option[String],
  outPath: in String,
): Int {
  if pkgName == "" {
    releaseErr("could not determine the entry package (no `package` declaration found)")
    return 1
  }
  val programDir = Path.dirname(programDll)
  // Stage the host project alongside the program DLL — `buildOne` already
  // created this directory (`.lyric-release/`), so we avoid a Std.Directory
  // dependency.  `dotnet publish -o` creates the output dir itself.
  val hostDir = programDir

  // Assemble the reference set: program DLL + restored deps + stdlib bundle.
  val refs: List[String] = newList()
  refs.add(programDll)
  var i = 0
  while i < extraRefs.count {
    refs.add(extraRefs[i])
    i += 1
  }
  match locateStdlib(programDir) {
    case Some(p) -> refs.add(p)
    case None -> {
      // Fail with a clear Lyric diagnostic rather than letting `dotnet
      // publish` fail later with a cryptic ILC link error (#2020).
      releaseErr(
        "Lyric.Stdlib.dll not found near " + programDir + " or the lyric binary (" + Environment.appBaseDirectory() + ")"
      )
      return 1
    }
  }

  val ridValue = match ridOpt { case Some(r) -> r; case None -> "$(NETCoreSdkPortableRuntimeIdentifier)" }
  match writeHostProject(hostDir, refs, ridValue) {
    case Ok(_) -> ()
    case Err(m) -> {
      releaseErr(m)
      return 1
    }
  }
  match writeTrampoline(hostDir, pkgName) {
    case Ok(_) -> ()
    case Err(m) -> {
      releaseErr(m)
      return 1
    }
  }

  // Publish to a known output dir so the native binary path is RID-independent.
  val outStage = Path.join(hostDir, "out")
  val pubArgs: List[String] = newList()
  pubArgs.add("publish")
  pubArgs.add(Path.join(hostDir, "host.csproj"))
  pubArgs.add("-c")
  pubArgs.add("Release")
  pubArgs.add("-p:PublishAot=true")
  pubArgs.add("-o")
  pubArgs.add(outStage)
  Console.println("release: compiling native binary (dotnet publish -p:PublishAot=true) ...")
  val pubExit = match Process.run("dotnet", pubArgs) {
    case Ok(code) -> code
    case Err(e) -> {
      releaseErr("dotnet publish failed to start: " + IOError.message(e))
      return 1
    }
  }
  if pubExit != 0 {
    releaseErr("dotnet publish exited " + toString(pubExit) + " — see output above")
    return 1
  }

  // The native binary is named after the host assembly.
  val nativeBin = Path.join(outStage, hostAssemblyName())
  if not File.fileExists(nativeBin) {
    releaseErr("native binary not found at " + nativeBin + " after publish")
    return 1
  }
  match copyExecutable(nativeBin, outPath) {
    case Ok(_) -> ()
    case Err(m) -> {
      releaseErr(m)
      return 1
    }
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
  pkgName: in String,
  extraRefs: in List[String],
  ridOpt: in Option[String],
  outPath: in String,
): Int {
  match target {
    case DotnetAot -> buildReleaseDotnet(programDll, pkgName, extraRefs, ridOpt, outPath)
    case JvmNativeImage -> {
      releaseErr("`--release --target jvm` (GraalVM native-image) is not yet implemented; tracked in #1975")
      1
    }
  }
}
