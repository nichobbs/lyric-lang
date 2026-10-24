package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Errors
import Std.Process as Process
import Std.String as Str
import Std.Char as Ch
import Std.JsonValue as Jv
import Lyric.Manifest as Mf
import Lyric.PluginManifest as Pm
import Lyric.PluginSdk as Sdk

// ─────────────────────────────────────────────────────────────────────────────
// `lyric plugin` (D207 Decisions 5 and 6, docs/69 §13): pack a plugin project
// into an artifact directory, check an artifact directory, and generate plugin
// SDKs in other languages from a plugin API package.
// ─────────────────────────────────────────────────────────────────────────────
func pluginUsageText(): String {
  "Usage: lyric plugin <command> [args]\n" + "\n" +
    "  lyric plugin pack  [--manifest <lyric.toml>] [--targets dotnet,jvm,native,wasm,component] [--trusted] [-o <dir>]\n" +
    "                     (build the plugin project for each target (default: dotnet), read its manifest\n" +
    "                      with --lyric-plugin-manifest, and write <dir>/<id>-<version>/plugin.json and\n" +
    "                      the payloads; <dir> defaults to bin/plugin beside the manifest; --trusted also\n" +
    "                      lists trusted payloads a host may load into its own process: the dotnet and\n" +
    "                      jvm payloads themselves, and a native --shape plugin library)\n" +
    "  lyric plugin check <dir>\n" +
    "                     (validate a plugin artifact directory; prints each problem and exits 1)\n" +
    "  lyric plugin sdk   --api <dir|file.l|lyric.toml> --lang csharp|java|typescript -o <dir>\n" +
    "                     (generate a plugin SDK for the API package's points and capabilities:\n" +
    "                      boundary types, codecs, a process-mode server, capability clients, a\n" +
    "                      manifest builder, and a JSON Schema of the boundary)"
}

func cmdPlugin(argv: in slice[String]): Int {
  if argv.length < 2 {
    printErr(pluginUsageText())
    return 1
  }
  val sub = argv[1]
  if sub == "--help" or sub == "-h" or sub == "help" {
    Console.println(pluginUsageText())
    return 0
  }
  if sub == "pack" {
    return cmdPluginPack(argv)
  }
  if sub == "check" {
    return cmdPluginCheck(argv)
  }
  if sub == "sdk" {
    return cmdPluginSdk(argv)
  }
  printErr("plugin: unknown command '" + sub + "'")
  printErr(pluginUsageText())
  1
}

// ── check ────────────────────────────────────────────────────────────────────
func cmdPluginCheck(argv: in slice[String]): Int {
  if argv.length != 3 or Str.startsWith(argv[2], "-") {
    printErr("usage: lyric plugin check <dir>")
    return 1
  }
  val dir = argv[2]
  val problems = Pm.checkArtifactDir(dir)
  if problems.count == 0 {
    return 0
  }
  val manifestPath = Path.join(dir, "plugin.json")
  val reportPath = if File.fileExists(manifestPath) { manifestPath } else { dir }
  for p in problems {
    printErr(reportPath + ": " + Pm.problemText(p))
  }
  1
}

// ── sdk ──────────────────────────────────────────────────────────────────────
func sdkSourcesOf(api: in String): Result[List[Sdk.SdkSource], String] {
  val sources: List[Sdk.SdkSource] = newList()
  val paths: List[String] = newList()
  if File.dirExists(api) {
    match File.listFiles(api) {
      case Ok(fs) -> {
        for f in sortFileList(fs) {
          if Str.endsWith(f, ".l") {
            paths.add(f)
          }
        }
      }
      case Err(e) -> return Err(error = "cannot list " + api + ": " + IOError.message(e))
    }
    if paths.count == 0 {
      return Err(error = api + " contains no .l files")
    }
  } else if Str.endsWith(api, ".toml") {
    if not File.fileExists(api) {
      return Err(error = api + " does not exist")
    }
    val (projectPaths, hadFatal) = collectProjectSourcePaths(api)
    if hadFatal {
      return Err(error = "cannot read the API project " + api)
    }
    for p in projectPaths {
      paths.add(p)
    }
  } else if Str.endsWith(api, ".l") and File.fileExists(api) {
    paths.add(api)
  } else {
    return Err(error = "--api must name a directory of .l files, a .l file or a lyric.toml; " + api + " is none of them")
  }
  for p in paths {
    match File.readText(p) {
      case Ok(text) -> sources.add(Sdk.SdkSource(path = p, text = text))
      case Err(e) -> return Err(error = "cannot read " + p + ": " + IOError.message(e))
    }
  }
  Ok(value = sources)
}

func cmdPluginSdk(argv: in slice[String]): Int {
  var api = ""
  var lang = ""
  var outDir = ""
  var i = 2
  while i < argv.length {
    val arg = argv[i]
    if arg == "--api" or arg == "--lang" or arg == "-o" or arg == "--out" {
      if i + 1 >= argv.length {
        printErr("plugin sdk: " + arg + " requires a value")
        return 1
      }
      val value = argv[i + 1]
      if arg == "--api" {
        api = value
      } else if arg == "--lang" {
        lang = value
      } else {
        outDir = value
      }
      i += 2
    } else {
      printErr("plugin sdk: unexpected argument " + arg)
      printErr("usage: lyric plugin sdk --api <dir|file.l|lyric.toml> --lang csharp|java|typescript -o <dir>")
      return 1
    }
  }
  if api.length == 0 or lang.length == 0 or outDir.length == 0 {
    printErr("usage: lyric plugin sdk --api <dir|file.l|lyric.toml> --lang csharp|java|typescript -o <dir>")
    return 1
  }
  if not listContains(Sdk.sdkLanguages(), lang) {
    printErr("plugin sdk: unknown language '" + lang + "' (expected csharp, java or typescript)")
    return 1
  }
  val sources = match sdkSourcesOf(api) {
    case Ok(s) -> s
    case Err(msg) -> {
      printErr("plugin sdk: " + msg)
      return 1
    }
  }
  val model = Sdk.buildApiModel(sources)
  if model.errors.count > 0 {
    for e in model.errors {
      printErr(e)
    }
    printErr("plugin sdk: the API package has errors; no SDK was written")
    return 1
  }
  val generated = Sdk.generateSdk(model.model, lang)
  if generated.errors.count > 0 {
    for e in generated.errors {
      printErr(e)
    }
    printErr("plugin sdk: cannot generate the " + lang + " SDK; no files were written")
    return 1
  }
  for f in generated.files {
    val target = Path.join(outDir, f.path)
    match File.createDir(Path.dirname(target)) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr("plugin sdk: cannot create " + Path.dirname(target) + ": " + IOError.message(e))
        return 1
      }
    }
    match File.writeText(target, f.content) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr("plugin sdk: cannot write " + target + ": " + IOError.message(e))
        return 1
      }
    }
  }
  Console.println(
    "plugin sdk: wrote the " + lang + " SDK for " + model.model.packageName + " (" + generated.files.count.toString() +
      " files) to " +
      outDir
  )
  0
}

// ── pack ─────────────────────────────────────────────────────────────────────
func packTargetNames(): List[String] {
  val names: List[String] = newList()
  names.add("dotnet")
  names.add("jvm")
  names.add("native")
  names.add("wasm")
  names.add("component")
  names
}

/// The `--targets` list, or an error naming the bad entry.
pub func parsePackTargets(raw: in String): Result[List[String], String] {
  val targets: List[String] = newList()
  for piece in Str.split(raw, ",") {
    val t = Str.trim(piece)
    if t.length == 0 {
      continue
    }
    if not listContains(packTargetNames(), t) {
      return Err(error = "unknown target '" + t + "' (expected dotnet, jvm, native, wasm or component)")
    }
    if listContains(targets, t) {
      return Err(error = "target '" + t + "' is listed twice")
    }
    targets.add(t)
  }
  if targets.count == 0 {
    return Err(error = "--targets names no target")
  }
  Ok(value = targets)
}

func toolRuns(exe: in String, args: in List[String]): Bool {
  match Process.runCapture(exe, args, 60000) {
    case Ok(res) -> res.exitCode == 0
    case Err(_) -> false
  }
}

func oneArg(a: in String): List[String] {
  val xs: List[String] = newList()
  xs.add(a)
  xs
}

/// The wasmtime executable: `$LYRIC_WASMTIME`, else `wasmtime` on PATH (D207
/// Decision 6), or "" when neither runs.
func findWasmtime(): String {
  val fromEnv = Environment.getVarOrDefault("LYRIC_WASMTIME", "")
  if fromEnv.length > 0 {
    if toolRuns(fromEnv, oneArg("--version")) {
      return fromEnv
    }
    return ""
  }
  if toolRuns("wasmtime", oneArg("--version")) {
    return "wasmtime"
  }
  ""
}

/// A message naming the missing toolchain for `target`, or "" when it is present.
func missingToolchain(target: in String, wasmtime: in String): String {
  if target == "dotnet" {
    if not toolRuns("dotnet", oneArg("--version")) {
      return "the dotnet payload is run with `dotnet exec` to read its manifest, and `dotnet` could not be run; install the .NET SDK or drop dotnet from --targets"
    }
  } else if target == "jvm" {
    if not toolRuns("java", oneArg("-version")) {
      return "the jvm payload is run with `java -jar` to read its manifest, and `java` could not be run; install a JDK (21 or later) or drop jvm from --targets"
    }
  } else if target == "native" {
    if not toolRuns("clang", oneArg("--version")) {
      return "a native payload is linked with clang, and `clang` could not be run; install clang or drop native from --targets"
    }
  } else if target == "wasm" or target == "component" {
    val sdk = Environment.getVarOrDefault("WASI_SDK_PATH", "")
    if sdk.length == 0 {
      return "a " + target +
        " payload is built with the wasi-sdk; set WASI_SDK_PATH to its install directory (docs/35 section 5.1) or drop " +
        target +
        " from --targets"
    }
    if not File.dirExists(sdk) {
      return "WASI_SDK_PATH is " + sdk + ", which is not a directory; point it at a wasi-sdk install"
    }
    if wasmtime.length == 0 {
      return "the " + target +
        " payload is run with wasmtime to read its manifest, and wasmtime was not found; put it on PATH or set LYRIC_WASMTIME (D207 Decision 6)"
    }
  }
  ""
}

/// The trusted native library of a `--trusted` pack: `native/lib<stem>.so`
/// (`.dylib` for macOS).
func packTrustedLibraryFile(stem: in String, os: in String): String {
  "native/lib" + stem + Pm.trustedLibrarySuffix(os)
}

func packPayloadFile(target: in String, stem: in String): String {
  if target == "dotnet" {
    "dotnet/" + stem + ".dll"
  } else if target == "jvm" {
    "jvm/" + stem + ".jar"
  } else if target == "native" {
    "native/" + stem + nativeOutputExt("")
  } else if target == "component" {
    "component/" + stem + ".wasm"
  } else {
    "wasm/" + stem + ".wasm"
  }
}

func packBuild(mfPath: in String, target: in String, outPath: in String, shape: in String = ""): Int {
  val args: List[String] = newList()
  args.add("build")
  args.add("--manifest")
  args.add(mfPath)
  args.add("--target")
  if target == "dotnet" {
    args.add("dotnet")
  } else if target == "jvm" {
    args.add("jvm")
  } else {
    args.add("native")
  }
  if target == "wasm" or target == "component" {
    args.add("--triple")
    args.add("wasm32-wasi")
  }
  if target == "component" {
    args.add("--shape")
    args.add("component")
  } else if shape.length > 0 {
    args.add("--shape")
    args.add(shape)
  }
  args.add("-o")
  args.add(outPath)
  cmdBuild(args.toArray())
}

/// The value of a WAVE-encoded string (`"..."` with `\"`, `\\`, `\'`, `\n`,
/// `\r`, `\t` and `\u{hex}` escapes), as `wasmtime run --invoke` prints a
/// `string` result.
pub func waveStringValue(text: in String): Result[String, String] {
  val t = Str.trim(text)
  if t.length < 2 or not Str.startsWith(t, "\"") or not Str.endsWith(t, "\"") {
    return Err(error = "expected a quoted string, got: " + t)
  }
  var acc = ""
  var i = 1
  val last = t.length - 1
  while i < last {
    val c = Str.substring(t, i, 1)
    if c != "\\" {
      acc = acc + c
      i = i + 1
      continue
    }
    if i + 1 >= last {
      return Err(error = "the string ends inside an escape")
    }
    val e = Str.substring(t, i + 1, 1)
    if e == "\"" or e == "\\" or e == "'" {
      acc = acc + e
      i = i + 2
    } else if e == "n" {
      acc = acc + "\n"
      i = i + 2
    } else if e == "r" {
      acc = acc + "\r"
      i = i + 2
    } else if e == "t" {
      acc = acc + "\t"
      i = i + 2
    } else if e == "u" {
      val close = Str.indexOfRaw(Str.substring(t, i), "}")
      if close < 0 or i + 2 >= last or Str.substring(t, i + 2, 1) != "{" {
        return Err(error = "a malformed \\u{...} escape")
      }
      val hex = Str.substring(t, i + 3, close - 3)
      var code = 0
      var h = 0
      while h < hex.length {
        val d = Str.codeUnitAt(hex, h)
        val v = if d >= 48 and d <= 57 {
          d - 48
        } else if d >= 97 and d <= 102 {
          d - 87
        } else if d >= 65 and d <= 70 {
          d - 55
        } else {
          return Err(error = "a malformed \\u{...} escape")
        }
        code = code * 16 + v
        h = h + 1
      }
      match Ch.tryFromInt(code) {
        case Some(ch) -> {
          acc = acc + ch.toString()
        }
        case None -> return Err(error = "\\u{" + hex + "} is not a BMP character (wasmtime escapes only control characters)")
      }
      i = i + close + 1
    } else {
      return Err(error = "an unknown escape \\" + e)
    }
  }
  Ok(value = acc)
}

/// The manifest of a component payload: its `plugin-describe` export, called
/// with `wasmtime run --invoke`.  Its imports, WASI and the capabilities, are
/// linked as traps (`-S cli=n -W unknown-imports-trap=y`; wasmtime cannot trap
/// the capabilities while it provides WASI), so the manifest is computed without
/// I/O, as a plugin's contributions and requests are.
func probeComponentManifest(payload: in String, wasmtime: in String): Result[String, String] {
  val args: List[String] = newList()
  args.add("run")
  args.add("-W")
  args.add("unknown-imports-trap=y")
  args.add("-S")
  args.add("cli=n")
  args.add("--invoke")
  args.add("plugin-describe()")
  args.add(payload)
  match Process.runCapture(wasmtime, args, 120000) {
    case Err(e) -> Err(error = "could not run " + wasmtime + ": " + e)
    case Ok(res) -> {
      if res.exitCode != 0 {
        val detail = Str.trim(res.stderr)
        return Err(
          error = "the component payload's plugin-describe export failed under wasmtime (exit " +
            res.exitCode.toString() +
            ")" +
            (if detail.length > 0 { ":\n" + detail } else { "" })
        )
      }
      match waveStringValue(res.stdout) {
        case Ok(text) -> Ok(value = text)
        case Err(e) -> Err(error = "the component payload's plugin-describe export did not return a string: " + e)
      }
    }
  }
}

/// Runs a built payload with `--lyric-plugin-manifest` (a component: calls its
/// `plugin-describe` export under wasmtime): its manifest text, or an error
/// saying what went wrong.
func probeManifest(target: in String, payload: in String, wasmtime: in String): Result[String, String] {
  if target == "component" {
    return probeComponentManifest(payload, wasmtime)
  }
  val args: List[String] = newList()
  var exe = payload
  if target == "dotnet" {
    exe = "dotnet"
    args.add("exec")
    args.add(payload)
  } else if target == "jvm" {
    exe = "java"
    args.add("-jar")
    args.add(payload)
  } else if target == "wasm" {
    exe = wasmtime
    args.add("run")
    args.add(payload)
  }
  args.add("--lyric-plugin-manifest")
  match Process.runCapture(exe, args, 120000) {
    case Err(e) -> Err(error = "could not run " + exe + ": " + e)
    case Ok(res) -> {
      if res.exitCode != 0 {
        val detail = Str.trim(res.stderr)
        return Err(
          error = "the " + target + " payload exited " + res.exitCode.toString() + " for --lyric-plugin-manifest" +
            (if detail.length > 0 { ":\n" + detail } else { "" })
        )
      }
      val text = Str.trim(res.stdout)
      if text.length == 0 {
        return Err(error = "the " + target + " payload printed nothing for --lyric-plugin-manifest; is it a plugin?")
      }
      Ok(value = text)
    }
  }
}

func normalizedJson(text: in String): String {
  match Jv.parseValue(text) {
    case Ok(v) -> Jv.writeValue(v)
    case Err(_) -> text
  }
}

/// Copies every file under `src` to the same relative path under `dst`,
/// leaving out the names in `skip` (relative paths).
func copyTree(src: in String, dst: in String, skip: in List[String]): Result[Unit, String] {
  val files = match File.listFilesRecursive(src) {
    case Ok(fs) -> fs
    case Err(e) -> return Err(error = "cannot list " + src + ": " + IOError.message(e))
  }
  val prefix = if Str.endsWith(src, "/") { src } else { src + "/" }
  for f in files {
    if not Str.startsWith(f, prefix) {
      return Err(error = "cannot place " + f + " relative to " + src)
    }
    val rel = Str.substring(f, prefix.length)
    if listContains(skip, rel) {
      continue
    }
    val target = Path.join(dst, rel)
    match File.createDir(Path.dirname(target)) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = "cannot create " + Path.dirname(target) + ": " + IOError.message(e))
    }
    match File.readBytes(f) {
      case Ok(bs) -> match File.writeBytes(target, bs) {
        case Ok(_) -> ()
        case Err(e) -> return Err(error = "cannot write " + target + ": " + IOError.message(e))
      }
      case Err(e) -> return Err(error = "cannot read " + f + ": " + IOError.message(e))
    }
  }
  Ok(value = ())
}

func markExecutable(path: in String): Result[Unit, String] {
  if Environment.isWindows() {
    return Ok(value = ())
  }
  val args: List[String] = newList()
  args.add("+x")
  args.add(path)
  match Process.run("chmod", args) {
    case Ok(code) -> if code == 0 {
      Ok(value = ())
    } else {
      Err(error = "chmod +x " + path + " exited " + code.toString())
    }
    case Err(e) -> Err(error = "cannot run chmod: " + IOError.message(e))
  }
}

func removeDirIfPresent(dir: in String): Unit {
  if File.dirExists(dir) {
    val _ = File.deleteDirRecursive(dir)
  }
}

/// The os/arch of the native payload: the manifest's `[native] triple`, else
/// the host clang's.
func nativeOsArch(manifest: in Mf.Manifest): Result[Pm.OsArch, String] {
  var triple = ""
  match manifest.native {
    case Some(cfg) -> {
      triple = cfg.triple
    }
    case None -> ()
  }
  if triple.length == 0 {
    triple = hostTripleOrEmpty()
  }
  if triple.length == 0 {
    return Err(error = "cannot read the host target triple from `clang -print-effective-triple`")
  }
  Pm.osArchOfTriple(triple)
}

func cmdPluginPack(argv: in slice[String]): Int {
  var manifestArg: Option[String] = None
  var targetsRaw = "dotnet"
  var outArg = ""
  var trusted = false
  var i = 2
  while i < argv.length {
    val arg = argv[i]
    if arg == "--trusted" {
      trusted = true
      i += 1
    } else if arg == "--manifest" or arg == "--targets" or arg == "-o" or arg == "--out" {
      if i + 1 >= argv.length {
        printErr("plugin pack: " + arg + " requires a value")
        return 1
      }
      val value = argv[i + 1]
      if arg == "--manifest" {
        manifestArg = Some(value = value)
      } else if arg == "--targets" {
        targetsRaw = value
      } else {
        outArg = value
      }
      i += 2
    } else {
      printErr("plugin pack: unexpected argument " + arg)
      printErr(
        "usage: lyric plugin pack [--manifest <lyric.toml>] [--targets dotnet,jvm,native,wasm,component] [--trusted] [-o <dir>]"
      )
      return 1
    }
  }
  val targets = match parsePackTargets(targetsRaw) {
    case Ok(t) -> t
    case Err(msg) -> {
      printErr("plugin pack: " + msg)
      return 1
    }
  }
  if trusted and not (listContains(targets, "dotnet") or listContains(targets, "jvm") or listContains(targets, "native")) {
    printErr("plugin pack: --trusted needs a dotnet, jvm or native target; a wasm payload has no trusted form")
    return 1
  }
  val mfPath = match discoverManifest(manifestArg) {
    case Some(p) -> p
    case None -> {
      printErr("plugin pack: no lyric.toml found in this directory or any parent; pass --manifest <lyric.toml>")
      return 1
    }
  }
  val mfText = match File.readText(mfPath) {
    case Ok(t) -> t
    case Err(e) -> {
      printErr("plugin pack: cannot read " + mfPath + ": " + IOError.message(e))
      return 1
    }
  }
  val manifest = match Mf.parseManifest(mfText, mfPath) {
    case Ok(m) -> m
    case Err(e) -> {
      printErr("plugin pack: " + Mf.ManifestError.message(e))
      return 1
    }
  }
  val proj = match manifest.project {
    case Some(p) -> p
    case None -> {
      printErr("plugin pack: " + mfPath + " has no [project] section; a plugin is packed from a project manifest")
      return 1
    }
  }
  if listContains(targets, "jvm") {
    match manifest.maven {
      case Some(mv) -> {
        if mv.entries.count > 0 {
          printErr(
            "plugin pack: " + mfPath +
              " declares [maven] dependencies, which a `java -jar` payload cannot load; drop jvm from --targets"
          )
          return 1
        }
      }
      case None -> ()
    }
  }
  val wasmtime = if listContains(targets, "wasm") { findWasmtime() } else { "" }
  for t in targets {
    val missing = missingToolchain(t, wasmtime)
    if missing.length > 0 {
      printErr("plugin pack: " + missing)
      return 1
    }
  }
  var nativeOs = ""
  var nativeArch = ""
  if listContains(targets, "native") {
    match nativeOsArch(manifest) {
      case Ok(oa) -> {
        nativeOs = oa.os
        nativeArch = oa.arch
      }
      case Err(msg) -> {
        printErr("plugin pack: " + msg)
        return 1
      }
    }
    if trusted and not (nativeOs == "linux" or nativeOs == "macos") {
      printErr(
        "plugin pack: a trusted native library is built for a Linux or macOS host, not " + nativeOs +
          " (docs/69 section 10); drop --trusted or native"
      )
      return 1
    }
  }
  val mfDir = Path.dirname(mfPath)
  val outDir = if outArg.length > 0 { outArg } else { Path.join(Path.join(mfDir, "bin"), "plugin") }
  val staging = Path.join(outDir, ".lyric-pack-staging")
  removeDirIfPresent(staging)
  match File.createDir(staging) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("plugin pack: cannot create " + staging + ": " + IOError.message(e))
      return 1
    }
  }
  val rc = packStaged(mfPath, proj.name, targets, outDir, staging, wasmtime, nativeOs, nativeArch, trusted)
  removeDirIfPresent(staging)
  rc
}

func packStaged(
  mfPath: in String,
  stem: in String,
  targets: in List[String],
  outDir: in String,
  staging: in String,
  wasmtime: in String,
  nativeOs: in String,
  nativeArch: in String,
  trusted: in Bool,
): Int {
  for t in targets {
    Console.println("plugin pack: building the " + t + " payload")
    val built = packBuild(mfPath, t, Path.join(staging, packPayloadFile(t, stem)))
    if built != 0 {
      printErr("plugin pack: the " + t + " build failed (see the errors above)")
      return 1
    }
  }
  if trusted and listContains(targets, "native") {
    Console.println("plugin pack: building the trusted native library")
    val built = packBuild(mfPath, "native", Path.join(staging, packTrustedLibraryFile(stem, nativeOs)), "plugin")
    if built != 0 {
      printErr("plugin pack: the trusted native library build failed (see the errors above)")
      return 1
    }
  }
  // Every payload is probed, so a manifest that depends on the target is
  // caught here rather than by a host.
  var manifestText = ""
  var firstTarget = ""
  for t in targets {
    val probed = match probeManifest(t, Path.join(staging, packPayloadFile(t, stem)), wasmtime) {
      case Ok(text) -> text
      case Err(msg) -> {
        printErr("plugin pack: " + msg)
        return 1
      }
    }
    val problems = Pm.checkManifestText(probed, Pm.ProbeCheck)
    if problems.count > 0 {
      printErr("plugin pack: the " + t + " payload printed an invalid manifest for --lyric-plugin-manifest:")
      for p in problems {
        printErr("  " + Pm.problemText(p))
      }
      return 1
    }
    if manifestText.length == 0 {
      manifestText = probed
      firstTarget = t
    } else if normalizedJson(probed) != normalizedJson(manifestText) {
      printErr(
        "plugin pack: the " + t + " payload's manifest differs from the " + firstTarget +
          " payload's; a plugin's manifest must not depend on its target"
      )
      return 1
    }
  }
  val id = Pm.manifestString(manifestText, "id")
  val version = Pm.manifestString(manifestText, "version")
  val artifact = Path.join(outDir, id + "-" + version)
  removeDirIfPresent(artifact)
  match File.createDir(artifact) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("plugin pack: cannot create " + artifact + ": " + IOError.message(e))
      return 1
    }
  }
  val skip: List[String] = newList()
  skip.add("jvm/module-path.txt")
  match copyTree(staging, artifact, skip) {
    case Ok(_) -> ()
    case Err(msg) -> {
      printErr("plugin pack: " + msg)
      return 1
    }
  }
  val payloads: List[String] = newList()
  for t in targets {
    val file = packPayloadFile(t, stem)
    if t == "dotnet" {
      payloads.add(Pm.dotnetPayload(file))
    } else if t == "jvm" {
      payloads.add(Pm.jvmPayload(file))
    } else if t == "component" {
      payloads.add(Pm.componentPayload(file))
    } else if t == "native" {
      match markExecutable(Path.join(artifact, file)) {
        case Ok(_) -> ()
        case Err(msg) -> {
          printErr("plugin pack: " + msg)
          return 1
        }
      }
      payloads.add(Pm.nativePayload(nativeOs, nativeArch, file))
    } else {
      payloads.add(Pm.wasmPayload(file))
    }
  }
  if trusted {
    // The managed trusted payloads are the process payloads' own files; the
    // native one is the `--shape plugin` library built above.
    for t in targets {
      if t == "dotnet" or t == "jvm" {
        payloads.add(Pm.trustedManagedPayload(t, packPayloadFile(t, stem)))
      } else if t == "native" {
        payloads.add(Pm.trustedNativePayload(nativeOs, nativeArch, packTrustedLibraryFile(stem, nativeOs)))
      }
    }
  }
  val pluginJson = Pm.prettyJson(Pm.withPayloads(manifestText, payloads))
  val pluginJsonPath = Path.join(artifact, "plugin.json")
  match File.writeText(pluginJsonPath, pluginJson) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("plugin pack: cannot write " + pluginJsonPath + ": " + IOError.message(e))
      return 1
    }
  }
  val problems = Pm.checkArtifactDir(artifact)
  if problems.count > 0 {
    for p in problems {
      printErr("plugin pack: internal error: the packed " + pluginJsonPath + " is invalid: " + Pm.problemText(p))
    }
    return 1
  }
  Console.println(
    "plugin pack: wrote " + artifact + " (" + id + " " + version + "; payloads: " + Str.joinList(", ", targets) + ")"
  )
  0
}
