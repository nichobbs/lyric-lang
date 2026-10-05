//! A call that leaves out a defaulted argument of a callee in a restored
//! (precompiled) dependency takes the callee's default, on both targets
//! (#7827).
//!
//! A restored package is read back from its contract metadata, which used to
//! carry each parameter without its default: `f()` for a restored
//! `pub func f(x: in Int = 5)` was T0042 ("expected 1 argument(s), got 0").
//! The declaring package now compiles each default of a public callable into
//! a public thunk (`__lyric_default_...`, Lyric.ContractElaborator.
//! synthesizeDefaultThunks), and the contract records the parameter's
//! default as a call to it, so the consumer calls the compiled default and
//! no default expression crosses the package boundary: a default reading a
//! private value of the library works, and a widening default converts in
//! the library.  A call takes the defaults of the declaration it resolves
//! through, as within a package: the interface member's on an
//! interface-typed value, the `impl` method's on the concrete type.  Two
//! overloads of one method each keep their own default (#8085), and so do a
//! record method and a dot-named function of the same type and name
//! (#8097): the thunk's name is an injective encoding of the callable's
//! kind, owner, name and parameter types.  A generic `impl` exports no
//! defaults (#8099).  A restored record method and dot-named function of the
//! same name and different arity each answer the calls the checker resolved
//! to them (#8098), and a public generic function whose body leaves out an
//! overloaded method's default binds the checker's overload when another
//! package specialises it, in the same build or restored.
//!
//! Each case builds a producer DLL / JAR through `Lyric.Emitter.emitProject`,
//! then a consumer that restores it (`restoredDllPaths`), runs it and
//! compares its output.
//!
//! Run in CI via native `lyric test` with LYRIC_LOAD_COMPILER=1 (it imports
//! `Lyric.Emitter`, a compiler package).
@test_module
package Lyric.RestoredDefaultArgsSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.ProcessCapture as Capture
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Lyric.Emitter as Emitter

// ─── Harness ─────────────────────────────────────────────────────────────────
func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-restored-defaults-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

func runtimeConfigJson(): String {
  "{\n" + "  \"runtimeOptions\": {\n" + "    \"tfm\": \"net10.0\",\n" + "    \"framework\": {\n" +
    "      \"name\": \"Microsoft.NETCore.App\",\n" +
    "      \"version\": \"10.0.0\"\n" +
    "    }\n" +
    "  }\n" +
    "}\n"
}

func writeRuntimeConfig(dllPath: in String): Unit {
  val stem = Path.basename(dllPath).substring(0, Path.basename(dllPath).length - 4)
  match File.writeText(Path.join(Path.dirname(dllPath), stem + ".runtimeconfig.json"), runtimeConfigJson()) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write runtimeconfig for " + dllPath + ": " + IOError.message(e))
  }
}

func mkPkg(name: in String, source: in String): Emitter.ProjectPackage {
  val srcs: List[String] = newList()
  srcs.add(source)
  val paths: List[String] = newList()
  paths.add("")
  Emitter.ProjectPackage(name = name, sources = srcs, paths = paths)
}

// Compile one package to `outPath` for `target`, restoring `restored`
// (`<package>\t<path>` entries).  True on success.
func emitOne(
  pkgName: in String,
  source: in String,
  outPath: in String,
  target: in Emitter.CompileTarget,
  restored: in List[String],
): Bool {
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg(pkgName, source))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = pkgName,
    outputPath = outPath,
    target = target,
    restoredDllPaths = restored,
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList(),
    packageFeatures = Emitter.noPackageFeatures(),
    contractsEnabled = true
  )
  match Emitter.emitProject(req).outputPath {
    case Some(_) -> true
    case None -> false
  }
}

// Build the producer, then a consumer restoring it, run the consumer and
// return its trimmed stdout.  Fails the test with the stage that failed.
func runRestored(label: in String, jvm: in Bool, libSrc: in String, appSrc: in String): String {
  val dir = freshTempDir(label + (if jvm { "-jvm" } else { "-dotnet" }))
  val ext = if jvm { ".jar" } else { ".dll" }
  val target = if jvm { Emitter.Jvm } else { Emitter.Dotnet }
  val libPath = Path.join(dir, "Rd.Lib" + ext)
  val noRestored: List[String] = newList()
  if not emitOne("Rd.Lib", libSrc, libPath, target, noRestored) {
    cleanup(dir)
    panic(label + ": the library failed to compile")
  }
  val appPath = Path.join(dir, "Rd.App" + ext)
  val restored: List[String] = newList()
  restored.add("Rd.Lib\t" + libPath)
  if not emitOne("Rd.App", appSrc, appPath, target, restored) {
    cleanup(dir)
    panic(label + ": the consumer failed to compile against the restored library")
  }
  val args: List[String] = newList()
  val captured = if jvm {
    args.add("-jar")
    args.add(appPath)
    Capture.runCaptureWithDiagnostics("java", args, "")
  } else {
    Emitter.copyStdlibDllsBeside(appPath, Emitter.findCompiledStdlibDir())
    writeRuntimeConfig(appPath)
    args.add("exec")
    args.add(appPath)
    Capture.runCaptureWithDiagnostics("dotnet", args, "")
  }
  cleanup(dir)
  assertEqualInt(captured.exitCode, 0, label + ": the consumer exits 0 (stderr=" + captured.stderr + ")")
  Str.trim(captured.stdout)
}

func assertLines(label: in String, actual: in String, expected: in List[String]): Unit {
  val lines = Str.split(actual, "\n")
  assertEqualInt(lines.count, expected.count, label + ": line count of\n" + actual)
  var i = 0
  while i < lines.count and i < expected.count {
    assertEqual(Str.trim(lines[i]), expected[i], label + ": line " + toString(i + 1))
    i = i + 1
  }
}

// ─── Sources ─────────────────────────────────────────────────────────────────
func libSource(): String {
  "package Rd.Lib\n\n" + "val base: Int = 100\n" + "pub val bigU: UInt = 4000000000u32\n\n" +
    "pub func f(x: in Int = 5): Int {\n  x * 10\n}\n\n" +
    "pub func fromBase(x: in Int = base + 1): Int {\n  x\n}\n\n" +
    "pub func widened(x: in ULong = bigU): ULong {\n  x\n}\n\n" +
    "pub func mixed(a: in Int, b: in Int = 10, c: in Int = 100): Int {\n  a + b * 2 + c * 3\n}\n\n" +
    "pub record Acc {\n  n: Int\n\n  func add(self: in Acc, x: in Int = 5): Int {\n    self.n + x\n  }\n\n" +
    "  func at(self: in Acc, i: in Int, f: in Int = 3): Int {\n    i * f\n  }\n\n" +
    "  func at(self: in Acc, i: in Int, j: in Int, k: in Int, f: in Int = 4): Int {\n    i + j + k + f * 100\n  }\n}\n\n" +
    "pub func Acc.scaled(self: in Acc, k: in Int = 3): Int {\n  self.n * k\n}\n\n" +
    "pub interface Shape {\n  func area(self: in Self, scale: in Int = 2): Int\n\n" +
    "  func describe(self: in Self, prefix: in String = \"shape:\"): String {\n" +
    "    prefix + toString(self.area())\n  }\n}\n\n" +
    "pub record Sq {\n  s: Int\n}\n\n" +
    "impl Shape for Sq {\n  func area(self: in Sq, scale: in Int = 3): Int {\n    self.s * scale\n  }\n}\n\n" +
    "pub func areaOf(sh: in Shape): Int {\n  sh.area()\n}\n"
}

func appSource(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "record Tri {\n  b: Int\n}\n\n" +
    "impl Shape for Tri {\n  func area(self: in Tri, scale: in Int = 2): Int {\n    self.b * scale + 1\n  }\n}\n\n" +
    "func viaShape(sh: in Shape): Int {\n  sh.area()\n}\n\n" +
    "func main(): Unit {\n" +
    "  println(toString(f()))\n" +
    "  println(toString(f(2)))\n" +
    "  println(toString(f(x = 3)))\n" +
    "  println(toString(fromBase()))\n" +
    "  println(toString(widened()))\n" +
    "  println(toString(mixed(1, c = 3)))\n" +
    "  println(toString(Acc(n = 1).add()))\n" +
    "  println(toString(Acc(n = 4).scaled()))\n" +
    "  println(toString(Acc(n = 0).at(5)))\n" +
    "  println(toString(Acc(n = 0).at(1, 2, 3)))\n" +
    "  println(toString(Sq(s = 4).area()))\n" +
    "  println(toString(viaShape(Sq(s = 4))))\n" +
    "  println(toString(areaOf(Sq(s = 4))))\n" +
    "  println(Sq(s = 4).describe())\n" +
    "  println(toString(viaShape(Tri(b = 4))))\n" +
    "  println(toString(Tri(b = 4).area()))\n" +
    "}\n"
}

func expectedLines(): List[String] {
  val e: List[String] = newList()
  e.add("50")
  e.add("20")
  e.add("30")
  e.add("101")
  e.add("4000000000")
  e.add("30")
  e.add("6")
  e.add("12")
  e.add("15")
  e.add("406")
  e.add("12")
  e.add("8")
  e.add("8")
  e.add("shape:12")
  e.add("9")
  e.add("9")
  e
}

// ─── Tests ───────────────────────────────────────────────────────────────────
test "a restored callee's omitted defaults are filled on dotnet (#7827)" {
  assertLines("dotnet", runRestored("defaults", false, libSource(), appSource()), expectedLines())
}

test "a restored callee's omitted defaults are filled on the JVM (#7827)" {
  assertLines("jvm", runRestored("defaults", true, libSource(), appSource()), expectedLines())
}

// A public generic function's defaults whose type names no type parameter
// are exported too: the thunks are synthesised before mono drops the
// generic from the package (#8085).  dotnet only: a restored generic
// function is not callable on the JVM at all yet, with or without a
// default (NoSuchMethodError on `Rd.Lib.idOr(ArrayList, int)`), a separate
// gap.
test "a restored generic function's non-generic default is filled on dotnet (#8085)" {
  val lib = "package Rd.Lib\n\nimport Std.Collections\n\n" +
    "pub func idOr[T](v: in List[T], n: in Int = 7): Int {\n  n + v.count\n}\n"
  val app = "package Rd.App\n\nimport Std.Collections\nimport Rd.Lib\n\nfunc main(): Unit {\n" +
    "  val xs: List[String] = newList()\n  println(toString(idOr(xs)))\n  println(toString(idOr(xs, 2)))\n}\n"
  val e: List[String] = newList()
  e.add("7")
  e.add("2")
  assertLines("dotnet generic", runRestored("generic", false, lib, app), e)
}

// #8097: a record method and a dot-named function of the same type, name
// and parameters each keep their own default across the restored boundary,
// and a parameter that declares no default stays required even when the
// same-named method's parameter has one.
func methodAndDotNamedLib(): String {
  "package Rd.Lib\n\n" + "pub record Acc {\n  n: Int\n\n" +
    "  func scaled(self: in Acc, k: in Int = 7): Int {\n    self.n - k\n  }\n\n" +
    "  func trim(self: in Acc, k: in Int = 2): Int {\n    self.n - k\n  }\n}\n\n" +
    "pub func Acc.scaled(self: in Acc, k: in Int = 3): Int {\n  self.n * k\n}\n\n" +
    "pub func Acc.trim(self: in Acc, k: in Int): Int {\n  self.n + k\n}\n"
}

func methodAndDotNamedApp(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "func main(): Unit {\n" + "  println(toString(Acc(n = 4).scaled()))\n" +
    "  println(toString(Acc.scaled(Acc(n = 4))))\n" +
    "  println(toString(Acc(n = 9).trim()))\n" +
    "  println(toString(Acc.trim(Acc(n = 9), 1)))\n" +
    "}\n"
}

func methodAndDotNamedLines(): List[String] {
  val e: List[String] = newList()
  e.add("-3")
  e.add("12")
  e.add("7")
  e.add("10")
  e
}

// True when a consumer of `libSrc` compiles; the library must.
func consumerCompiles(label: in String, jvm: in Bool, libSrc: in String, appSrc: in String): Bool {
  val dir = freshTempDir(label + (if jvm { "-jvm" } else { "-dotnet" }))
  val ext = if jvm { ".jar" } else { ".dll" }
  val target = if jvm { Emitter.Jvm } else { Emitter.Dotnet }
  val libPath = Path.join(dir, "Rd.Lib" + ext)
  val noRestored: List[String] = newList()
  if not emitOne("Rd.Lib", libSrc, libPath, target, noRestored) {
    cleanup(dir)
    panic(label + ": the library failed to compile")
  }
  val restored: List[String] = newList()
  restored.add("Rd.Lib\t" + libPath)
  val ok = emitOne("Rd.App", appSrc, Path.join(dir, "Rd.App" + ext), target, restored)
  cleanup(dir)
  ok
}

func omitsRequiredArgApp(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "func main(): Unit {\n" + "  println(toString(Acc.trim(Acc(n = 9))))\n" +
    "}\n"
}

test "a record method and a same-named dot-named function keep their own defaults on dotnet (#8097)" {
  assertLines(
    "dotnet",
    runRestored("dotnamed", false, methodAndDotNamedLib(), methodAndDotNamedApp()),
    methodAndDotNamedLines()
  )
  assertTrue(
    not consumerCompiles("dotnamed-required", false, methodAndDotNamedLib(), omitsRequiredArgApp()),
    "the dot-named function's k has no default, so leaving it out does not compile"
  )
}

test "a record method and a same-named dot-named function keep their own defaults on the JVM (#8097)" {
  assertLines(
    "jvm",
    runRestored("dotnamed", true, methodAndDotNamedLib(), methodAndDotNamedApp()),
    methodAndDotNamedLines()
  )
  assertTrue(
    not consumerCompiles("dotnamed-required", true, methodAndDotNamedLib(), omitsRequiredArgApp()),
    "the dot-named function's k has no default, so leaving it out does not compile"
  )
}

// #8099: a generic impl exports no defaults (its method heads would name type
// parameters the contract's `impl` head does not declare), so a consumer
// passes the argument; leaving it out does not compile.
func genericImplLib(): String {
  "package Rd.Lib\n\n" + "pub interface Sized {\n  func size(self: in Self, scale: in Int): Int\n}\n\n" +
    "pub record Box[T] {\n  v: T\n}\n\n" +
    "impl[T] Sized for Box[T] {\n  func size(self: in Box[T], scale: in Int = 3): Int {\n    scale * 2\n  }\n}\n"
}

func genericImplOmitsApp(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "func main(): Unit {\n" + "  println(toString(Box(v = 1).size()))\n" +
    "}\n"
}

func genericImplPassesApp(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "func main(): Unit {\n" + "  println(toString(Box(v = 1).size(4)))\n" +
    "}\n"
}

test "a generic impl's default is not exported (#8099)" {
  assertTrue(
    not consumerCompiles("genimpl-omits-dotnet", false, genericImplLib(), genericImplOmitsApp()),
    "dotnet: leaving out the generic impl's argument does not compile"
  )
  assertTrue(
    consumerCompiles("genimpl-passes-dotnet", false, genericImplLib(), genericImplPassesApp()),
    "dotnet: passing it does"
  )
  assertTrue(
    not consumerCompiles("genimpl-omits-jvm", true, genericImplLib(), genericImplOmitsApp()),
    "jvm: leaving out the generic impl's argument does not compile"
  )
  assertTrue(
    consumerCompiles("genimpl-passes-jvm", true, genericImplLib(), genericImplPassesApp()),
    "jvm: passing it does"
  )
}

// #8098: a restored record method and dot-named function of the same name
// and different arity: each call runs the one the checker resolved.
func arityLib(): String {
  "package Rd.Lib\n\n" + "pub record Od {\n  n: Int\n\n" +
    "  func m(self: in Od, x: in Int): Int {\n    6000 + x\n  }\n}\n\n" +
    "pub func Od.m(o: in Od, x: in Int, y: in Int, z: in Int = 3): Int {\n  7000 + x * 100 + y * 10 + z\n}\n\n" +
    "pub record Oe {\n  n: Int\n\n" +
    "  func m(self: in Oe, x: in Int, y: in Int = 2): Int {\n    8000 + x * 10 + y\n  }\n}\n\n" +
    "pub func Oe.m(o: in Oe, x: in Int): Int {\n  9000 + x\n}\n"
}

func arityApp(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "func main(): Unit {\n" + "  val d = Od(n = 0)\n" +
    "  println(toString(d.m(1)))\n" +
    "  println(toString(d.m(1, 2, 5)))\n" +
    "  println(toString(d.m(1, 2)))\n" +
    "  val e = Oe(n = 0)\n" +
    "  println(toString(e.m(1)))\n" +
    "  println(toString(e.m(1, 5)))\n" +
    "}\n"
}

func arityLines(): List[String] {
  val e: List[String] = newList()
  e.add("6001")
  e.add("7125")
  e.add("7123")
  e.add("9001")
  e.add("8015")
  e
}

test "a restored record method and dot-named function of another arity (#8098)" {
  assertLines("dotnet", runRestored("arity", false, arityLib(), arityApp()), arityLines())
  assertLines("jvm", runRestored("arity", true, arityLib(), arityApp()), arityLines())
}

// A public generic function whose body leaves out a defaulted argument of an
// overloaded method, specialised in another package of the same build: the
// specialised body still binds the overload the checker resolved in the
// declaring package.
func overloadInGenericLib(): String {
  "package Rd.Lib\n\n" + "pub record Ov {\n  n: Int\n\n" +
    "  func m(self: in Ov, x: in String): Int {\n    3000\n  }\n\n" +
    "  func m(self: in Ov, x: in Int, y: in Int = 2): Int {\n    4000 + x * 10 + y\n  }\n}\n\n" +
    "pub func viaGeneric[T](o: in Ov, t: in T): Int {\n  o.m(1)\n}\n"
}

func overloadInGenericApp(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "func main(): Unit {\n" +
    "  println(toString(viaGeneric(Ov(n = 0), \"s\")))\n" +
    "  println(toString(viaGeneric(Ov(n = 0), 5)))\n" +
    "}\n"
}

func overloadInGenericLines(): List[String] {
  val e: List[String] = newList()
  e.add("4012")
  e.add("4012")
  e
}

// Build `Rd.Lib` and `Rd.App` as one project (one output), run it and return
// its trimmed stdout.
func runBundle(label: in String, jvm: in Bool, libSrc: in String, appSrc: in String): String {
  val dir = freshTempDir(label + (if jvm { "-jvm" } else { "-dotnet" }))
  val ext = if jvm { ".jar" } else { ".dll" }
  val outPath = Path.join(dir, "Rd.App" + ext)
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(mkPkg("Rd.Lib", libSrc))
  pkgs.add(mkPkg("Rd.App", appSrc))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "Rd.App",
    outputPath = outPath,
    target = if jvm { Emitter.Jvm } else { Emitter.Dotnet },
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList(),
    packageFeatures = Emitter.noPackageFeatures(),
    contractsEnabled = true
  )
  match Emitter.emitProject(req).outputPath {
    case Some(_) -> ()
    case None -> {
      cleanup(dir)
      panic(label + ": the project failed to compile")
    }
  }
  val args: List[String] = newList()
  val captured = if jvm {
    args.add("-jar")
    args.add(outPath)
    Capture.runCaptureWithDiagnostics("java", args, "")
  } else {
    Emitter.copyStdlibDllsBeside(outPath, Emitter.findCompiledStdlibDir())
    writeRuntimeConfig(outPath)
    args.add("exec")
    args.add(outPath)
    Capture.runCaptureWithDiagnostics("dotnet", args, "")
  }
  cleanup(dir)
  assertEqualInt(captured.exitCode, 0, label + ": the program exits 0 (stderr=" + captured.stderr + ")")
  Str.trim(captured.stdout)
}

test "a generic body's omitted default binds the checker's overload when specialised in another package on dotnet" {
  assertLines(
    "dotnet bundle",
    runBundle("generic-overload", false, overloadInGenericLib(), overloadInGenericApp()),
    overloadInGenericLines()
  )
}

test "a generic body's omitted default binds the checker's overload when specialised in another package on the JVM" {
  assertLines(
    "jvm bundle",
    runBundle("generic-overload", true, overloadInGenericLib(), overloadInGenericApp()),
    overloadInGenericLines()
  )
}

test "a restored generic body's omitted default binds the checker's overload on dotnet" {
  assertLines(
    "dotnet restored",
    runRestored("generic-overload", false, overloadInGenericLib(), overloadInGenericApp()),
    overloadInGenericLines()
  )
}

// A call into a restored package evaluates its arguments left to right as
// written, then the omitted parameters' defaults through the producer's
// thunks, whatever the parameter order (#8158, D171): the consumer's type
// checker reads the parameters from the contract and orders the call before
// any backend lowers it.  The same holds for a restored record's constructor
// and method.
func evalOrderLib(): String {
  "package Rd.Lib\n\n" + "pub func say(s: in String, v: in Int): Int {\n  println(s)\n  v\n}\n\n" +
    "pub func tr(a: in Int, d: in Int = say(\"d\", 4), b: in Int): Int {\n  a * 100 + d * 10 + b\n}\n\n" +
    "pub record Pt {\n  x: Int\n  y: Int\n\n" +
    "  func mix(self: in Pt, a: in Int, b: in Int = say(\"mb\", 5)): Int {\n    self.x + a * 10 + b\n  }\n}\n"
}

func evalOrderApp(): String {
  "package Rd.App\n\n" + "import Rd.Lib\n\n" + "func main(): Unit {\n" +
    "  println(toString(tr(b = say(\"b\", 2), a = say(\"a\", 1))))\n" +
    "  val p = Pt(y = say(\"y\", 2), x = say(\"x\", 1))\n" +
    "  println(toString(p.x * 10 + p.y))\n" +
    "  println(toString(p.mix(a = say(\"ma\", 3))))\n" +
    "}\n"
}

func evalOrderLines(): List[String] {
  val e: List[String] = newList()
  e.add("b")
  e.add("a")
  e.add("d")
  e.add("142")
  e.add("y")
  e.add("x")
  e.add("12")
  e.add("ma")
  e.add("mb")
  e.add("36")
  e
}

test "a restored callee's arguments run in source order, its defaults after them, on dotnet (#8158)" {
  assertLines("dotnet", runRestored("eval-order", false, evalOrderLib(), evalOrderApp()), evalOrderLines())
}

test "a restored callee's arguments run in source order, its defaults after them, on the JVM (#8158)" {
  assertLines("jvm", runRestored("eval-order", true, evalOrderLib(), evalOrderApp()), evalOrderLines())
}
