//! llvm_config_self_test.l -- `config { }` blocks on `--target native`
//! (docs/25, #7435).
//!
//! Real programs with config blocks compile through the full bridge pipeline
//! (`Lyric.LlvmBridge.compileToNativeWithFlags`, `-fsanitize=address`) and run
//! with the environment set per case, asserting what the program computes and,
//! for a field that stops startup, the exit code (78) and the stderr message,
//! which are the dotnet and JVM lowerings' (`config_block_self_test.l`,
//! `config_block_missing_required_self_test.l`): the default for an unset or
//! empty var, a value of each field type, a required field, a value that does
//! not parse (G0003), and a value outside the field's range (G0004).
//!
//! The child process inherits this process's environment, so a case sets its
//! `LYRIC_CONFIG_*` vars with `Std.Environment.setVar` first and clears them
//! after (an empty value is an absent one).
//!
//! Requires `clang` on PATH and a built runtime (`make -C lyric-rt`).
//!   make -C lyric-rt && LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/llvm_config_self_test.l
@test_module
package Lyric.LlvmConfigSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.File as File
import Std.Path as Path
import Std.Process as Process
import Std.Environment as Environment
import Std.Uuid as Uuid
import Std.String as Str
import Lyric.Emitter
import Lyric.LlvmBridge
import Lyric.DiagnosticUtil as DiagUtil

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

record RunOutcome {
  exitCode: Int
  stdout: String
  stderr: String
}

func compileAndRunNative(source: in String): RunOutcome {
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-config-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "t_" + Uuid.uuidToString(Uuid.newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  if not compileToNativeWithFlags(source, stem, stdlib, "", "0", flags, newList(), "", true) {
    panic("native compilation failed for a config self-test program")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> RunOutcome(exitCode = nativeExitStatus(res.exitCode), stdout = res.stdout, stderr = res.stderr)
    case Err(e) -> panic("binary could not be started: " + e)
  }
}

func withEnv(names: in List[String], values: in List[String], run: in () -> RunOutcome): RunOutcome {
  var i = 0
  while i < names.count {
    Environment.setVar(names[i], values[i])
    i = i + 1
  }
  val res = run()
  var j = 0
  while j < names.count {
    Environment.setVar(names[j], "")
    j = j + 1
  }
  res
}

func runWith1(source: in String, n1: in String, v1: in String): RunOutcome {
  val names: List[String] = newList()
  val values: List[String] = newList()
  names.add(n1)
  values.add(v1)
  withEnv(names, values, { -> compileAndRunNative(source) })
}

func fieldsSource(pkg: in String): String {
  "package " + pkg + "\n" + "import Std.Core\n" + "import Std.Console\n" + "config Limits {\n" + "  port: Int = 8080\n" +
    "  big: Long = 5000000000\n" +
    "  rate: Float = 0.5\n" +
    "  ratio: Double = 2.25\n" +
    "  on: Bool = true\n" +
    "  off: Bool = false\n" +
    "  name: String = \"svc\"\n" +
    "  neg: Int = -3\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  println(Limits.port.toString())\n" +
    "  println(Limits.big.toString())\n" +
    "  println(Limits.rate.toString())\n" +
    "  println(Limits.ratio.toString())\n" +
    "  println(Limits.on.toString())\n" +
    "  println(Limits.off.toString())\n" +
    "  println(Limits.name)\n" +
    "  println(Limits.neg.toString())\n" +
    "  0\n" +
    "}\n"
}

test "every field type takes its declared default when the vars are unset (#7435)" {
  val r = compileAndRunNative(fieldsSource("CfgDefaults"))
  assertEqualInt(r.exitCode, 0, "exit code; stderr: " + r.stderr)
  assertEqual(r.stdout, "8080\n5000000000\n0.5\n2.25\ntrue\nfalse\nsvc\n-3\n", "defaults")
}

test "a set var overrides the default for every field type (#7435)" {
  val names: List[String] = newList()
  val values: List[String] = newList()
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_PORT")
  values.add(" 9090 ")
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_BIG")
  values.add("-42")
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_RATE")
  values.add("1.25")
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_RATIO")
  values.add("3.5e2")
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_ON")
  values.add("0")
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_OFF")
  values.add("TRUE")
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_NAME")
  values.add("  spaced name  ")
  names.add("LYRIC_CONFIG_CFGENV_LIMITS_NEG")
  values.add("+7")
  val r = withEnv(names, values, { -> compileAndRunNative(fieldsSource("CfgEnv")) })
  assertEqualInt(r.exitCode, 0, "exit code; stderr: " + r.stderr)
  assertEqual(r.stdout, "9090\n-42\n1.25\n350\nfalse\ntrue\n  spaced name  \n7\n", "values from the environment")
}

test "an empty var is an absent one (#7435)" {
  val r = runWith1(fieldsSource("CfgEmpty"), "LYRIC_CONFIG_CFGEMPTY_LIMITS_PORT", "")
  assertEqualInt(r.exitCode, 0, "exit code; stderr: " + r.stderr)
  assertTrue(Str.startsWith(r.stdout, "8080\n"), "the default: " + r.stdout)
}

func requiredSource(): String {
  "package CfgRequired\n" + "import Std.Console\n" + "config Required {\n" + "  secret: String\n" + "}\n" +
    "func main(): Int {\n" +
    "  println(Required.secret)\n" +
    "  0\n" +
    "}\n"
}

test "a required field with no var stops startup with exit 78 (#7435)" {
  val r = compileAndRunNative(requiredSource())
  assertEqualInt(r.exitCode, 78, "exit code")
  assertEqual(
    r.stderr,
    "error: required config field Required.secret (env var LYRIC_CONFIG_CFGREQUIRED_REQUIRED_SECRET) is not set\n",
    "stderr"
  )
  assertEqual(r.stdout, "", "nothing runs before the failure")
}

test "a required field takes its var (#7435)" {
  val r = runWith1(requiredSource(), "LYRIC_CONFIG_CFGREQUIRED_REQUIRED_SECRET", "hunter2")
  assertEqualInt(r.exitCode, 0, "exit code; stderr: " + r.stderr)
  assertEqual(r.stdout, "hunter2\n", "value")
}

func parseSource(pkg: in String, ty: in String): String {
  "package " + pkg + "\n" + "import Std.Console\n" + "config C {\n" + "  v: " + ty + " = 1\n" + "}\n" +
    "func main(): Int {\n" +
    "  println(C.v.toString())\n" +
    "  0\n" +
    "}\n"
}

func expectParseFailure(pkg: in String, ty: in String, value: in String) {
  val r = runWith1(parseSource(pkg, ty), "LYRIC_CONFIG_" + Str.toUpper(pkg) + "_C_V", value)
  assertEqualInt(r.exitCode, 78, ty + " '" + value + "': exit code")
  assertEqual(
    r.stderr,
    "error: config field C.v (env var LYRIC_CONFIG_" + Str.toUpper(pkg) + "_C_V) is not a valid " + ty + " (G0003)\n",
    ty + " '" + value + "': stderr"
  )
  assertEqual(r.stdout, "", ty + ": nothing runs")
}

test "a value that does not parse stops startup with G0003 (#7435)" {
  expectParseFailure("CfgBadInt", "Int", "80a")
  expectParseFailure("CfgBadIntRange", "Int", "3000000000")
  expectParseFailure("CfgBadLong", "Long", "1.5")
  expectParseFailure("CfgBadDouble", "Double", "1,5")
  expectParseFailure("CfgBadFloat", "Float", "abc")
}

test "a Bool is exactly 1, 0, true or false in any case (#7435)" {
  val src = "package CfgBool\n" + "import Std.Console\n" + "config C {\n" + "  v: Bool = false\n" + "}\n" +
    "func main(): Int {\n" +
    "  println(C.v.toString())\n" +
    "  0\n" +
    "}\n"
  val bad = runWith1(src, "LYRIC_CONFIG_CFGBOOL_C_V", "maybe")
  assertEqualInt(bad.exitCode, 78, "maybe: exit code")
  assertEqual(
    bad.stderr,
    "error: config field C.v (env var LYRIC_CONFIG_CFGBOOL_C_V) is not a valid Bool (G0003)\n",
    "maybe: stderr"
  )
  val ok = runWith1(src, "LYRIC_CONFIG_CFGBOOL_C_V", "True")
  assertEqualInt(ok.exitCode, 0, "True: exit code; stderr: " + ok.stderr)
  assertEqual(ok.stdout, "true\n", "True")
}

func rangeSource(pkg: in String, decl: in String): String {
  "package " + pkg + "\n" + "import Std.Console\n" + "config C {\n" + "  v: " + decl + "\n" + "}\n" +
    "func main(): Int {\n" +
    "  println(C.v.toString())\n" +
    "  0\n" +
    "}\n"
}

func expectOutsideRange(pkg: in String, decl: in String, value: in String, desc: in String) {
  val r = runWith1(rangeSource(pkg, decl), "LYRIC_CONFIG_" + Str.toUpper(pkg) + "_C_V", value)
  assertEqualInt(r.exitCode, 78, decl + " '" + value + "': exit code")
  assertEqual(
    r.stderr,
    "error: config field C.v (env var LYRIC_CONFIG_" + Str.toUpper(pkg) + "_C_V) is outside its range " + desc + "\n",
    decl + " '" + value + "': stderr"
  )
  assertEqual(r.stdout, "", decl + ": nothing runs")
}

test "a value outside a range field's bounds stops startup with exit 78 (#7435)" {
  expectOutsideRange("CfgRangeA", "Int range 1 ..= 65535 = 8080", "0", "[1, 65535]")
  expectOutsideRange("CfgRangeB", "Int range 1 ..= 65535 = 8080", "65536", "[1, 65535]")
  expectOutsideRange("CfgRangeC", "Int range 0 ..< 10 = 1", "10", "[0, 10)")
  expectOutsideRange("CfgRangeD", "Long range 5 .. = 5", "4", "(at least 5)")
  expectOutsideRange("CfgRangeE", "Double range ..= 1.5 = 1.0", "1.5000001", "(at most 1.5)")
  expectOutsideRange("CfgRangeF", "Double range 0.25 ..= 1.5 = 0.5", "nan", "[0.25, 1.5]")
}

test "a value inside the bounds, an edge included, is accepted (#7435)" {
  val low = runWith1(rangeSource("CfgRangeOkA", "Int range 1 ..= 65535 = 8080"), "LYRIC_CONFIG_CFGRANGEOKA_C_V", "1")
  assertEqualInt(low.exitCode, 0, "low edge; stderr: " + low.stderr)
  assertEqual(low.stdout, "1\n", "low edge")
  val high = runWith1(rangeSource("CfgRangeOkB", "Int range 0 ..< 10 = 1"), "LYRIC_CONFIG_CFGRANGEOKB_C_V", "9")
  assertEqualInt(high.exitCode, 0, "just inside the exclusive bound; stderr: " + high.stderr)
  assertEqual(high.stdout, "9\n", "just inside the exclusive bound")
  val dflt = compileAndRunNative(rangeSource("CfgRangeOkC", "Int range 1 ..= 65535 = 8080"))
  assertEqualInt(dflt.exitCode, 0, "default; stderr: " + dflt.stderr)
  assertEqual(dflt.stdout, "8080\n", "default")
}

test "config fields are read inside functions, closures and another block (#7435)" {
  val src = "package CfgUse\n" + "import Std.Core\n" + "import Std.Console\n" + "config A {\n" + "  n: Int = 40\n" +
    "}\n" +
    "config B {\n" +
    "  m: Int = 2\n" +
    "  label: String = \"x\"\n" +
    "}\n" +
    "func sum(): Int {\n" +
    "  A.n + B.m\n" +
    "}\n" +
    "func main(): Int {\n" +
    "  val f: () -> Int = { -> A.n * B.m }\n" +
    "  println(B.label + f().toString())\n" +
    "  sum()\n" +
    "}\n"
  val r = compileAndRunNative(src)
  assertEqualInt(r.exitCode, 42, "sum(); stderr: " + r.stderr)
  assertEqual(r.stdout, "x80\n", "closure")
}

test "a config block in a package of a project builds and reads its own var (#7435)" {
  val pkgs: List[NativeSourcePackage] = newList()
  pkgs.add(
    NativeSourcePackage(
      name = "CfgProj.Lib",
      path = "",
      source = "package CfgProj.Lib\n" + "config Knobs {\n" + "  scale: Int = 6\n" + "}\n" + "pub func scaled(x: in Int): Int {\n" +
        "  x * Knobs.scale\n" +
        "}\n"
    )
  )
  pkgs.add(
    NativeSourcePackage(
      name = "CfgProj.App",
      path = "",
      source = "package CfgProj.App\n" + "import CfgProj.Lib\n" + "func main(): Int {\n" + "  scaled(7)\n" + "}\n"
    )
  )
  val stdlib = findStdlibSourcesNative()
  if stdlib.count == 0 {
    panic("native stdlib sources not found (run from the repo root or set LYRIC_STD_PATH)")
  }
  val dir = Path.join(tempBase(), "lyric-llvm-config-selftest")
  val _ = File.createDir(dir)
  val stem = Path.join(dir, "p_" + Uuid.uuidToString(Uuid.newUuid()))
  val flags: List[String] = newList()
  flags.add("-fsanitize=address")
  val noFeatures: List[String] = newList()
  val noOrigins: List[DiagUtil.PackageLineOrigins] = newList()
  if not compileProjectToNativeWithFlags(pkgs, stem, stdlib, "", "0", flags, newList(), noFeatures, noFeatures, "", noOrigins, true) {
    panic("native project compilation failed")
  }
  val noArgs: List[String] = newList()
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> assertEqualInt(nativeExitStatus(res.exitCode), 42, "scaled(7) with the default scale (== 42)")
    case Err(e) -> panic("binary could not be started: " + e)
  }
  Environment.setVar("LYRIC_CONFIG_CFGPROJ_LIB_KNOBS_SCALE", "3")
  match Process.runCapture(stem, noArgs, 60000) {
    case Ok(res) -> assertEqualInt(nativeExitStatus(res.exitCode), 21, "scaled(7) with the var set (== 21)")
    case Err(e) -> panic("binary could not be started: " + e)
  }
  Environment.setVar("LYRIC_CONFIG_CFGPROJ_LIB_KNOBS_SCALE", "")
}
