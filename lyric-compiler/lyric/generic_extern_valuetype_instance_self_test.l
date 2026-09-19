//! generic_extern_valuetype_instance_self_test.l — regression test for the
//! build-time panic on INSTANCE-method `@externTarget` calls whose declaring
//! generic type is a value type (D-progress-686 / #5809, #5825).
//!
//! `Msil.Codegen.emitGenericExternMember` deliberately panics (rather than
//! silently falling through to a shape that would compile clean and fault at
//! runtime/verification) when an `@externTarget` names an INSTANCE member on
//! a value-type-declaring generic BCL type — e.g. `ValueTask`1.get_Result` —
//! because the receiver arrives object-boxed with no marshaling path back to
//! the managed pointer an instance call on a struct requires. Only
//! constructor calls and static members are supported for value-type
//! generic-declaring externs.
//!
//! A bad `@externTarget` like this can't be declared at this file's own
//! top level: the refusal fires during codegen of the *whole test module*,
//! which would abort the entire `lyric test` run rather than fail one
//! assertion. Instead this compiles a tiny fixture package IN-PROCESS via
//! `Lyric.Emitter.emitProject` (mirroring `emitter_project_self_test.l`'s
//! `runEmitProject*` helpers) from inside a `test { }` body.
//!
//! #6449/#6459/#6462 (D-progress-762): `Lyric.Emitter`'s
//! `msilBridgePanicDiagnostic` boundary (the `Jvm.Bridge` layering
//! convention — the bridge itself keeps its throw-on-refusal library
//! contract) contains the codegen panic as a printed `T0119`/`T0120`
//! diagnostic, a failed build, AND a structured entry in
//! `EmitResult.diagnostics` — this test asserts the contained-failure
//! contract (no throw, no output artifact) plus the T0120 code and the
//! refusal text from the result.
//!
//! Pulls in `Lyric.Emitter`, so `LYRIC_LOAD_COMPILER=1` is needed for
//! `lyric test` to resolve it:
//!
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/generic_extern_valuetype_instance_self_test.l
//!
//! `msil_project_bridge_self_test.l` ("instance call on a value-type
//! generic-declaring extern panics at build time, not silently")
//! already covers #5809/#5825, but through a deliberately different
//! surface: it calls `Msil.Bridge.compileProjectToMsil` directly against a
//! CONCRETE extern type (`ValueTaskOfObj`, the CLR instantiation baked into
//! the extern's declared string) with an explicit `@externInstance` hint.
//! This file instead exercises a Lyric-level GENERIC extern type (`VT[T]`)
//! through the higher-level `Lyric.Emitter.emitProject` entry point, with
//! no `@externInstance` hint, so the refusal is also proven to survive
//! `Lyric.Mono`'s monomorphization (`vtResult[T]` specializing to a
//! concrete `vtResult__Int` copy) before codegen ever sees it. Keep both —
//! they are not redundant.
@test_module
package Lyric.GenericExternValueTypeInstanceSelfTest

import Std.Core
import Std.Collections
import Std.File as File
import Std.Path as Path
import Std.String as Str
import Std.Testing
import Std.Uuid
import Std.Environment as Env
import Lyric.Emitter as Emitter

func tempBase(): String {
  Env.getVarOrDefault("TMPDIR", Env.getVarOrDefault("TEMP", Env.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-vtinst-" + label + "-" + uuidToString(newUuid()))
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

// A generic `@externTarget` calling an INSTANCE member (`get_Result`, the
// property accessor for `.Result`) on `ValueTask`1` — a value-type-declaring
// generic BCL type. `newVt`/`main` give `vtResult` a real call site so the
// monomorphizer specializes it to a concrete `vtResult__Int` and codegen
// actually reaches `emitGenericExternMember` for it.
func valueTypeInstanceExternSource(): String {
  "package ValueTaskInstanceFixture\n\n" + "extern type VT[T] = \"System.Threading.Tasks.ValueTask`1\"\n\n" +
    "@externTarget(\"System.Threading.Tasks.ValueTask`1..ctor\")\n" +
    "func newVt[T](value: in T): VT[T] = ()\n\n" +
    "@externTarget(\"System.Threading.Tasks.ValueTask`1.get_Result\")\n" +
    "func vtResult[T](vt: in VT[T]): T = ()\n\n" +
    "func main(): Unit {\n" +
    "  val vt: VT[Int] = newVt(42)\n" +
    "  println(vtResult(vt))\n" +
    "}\n"
}

test "instance-method extern on a value-type generic-declaring type fails the build cleanly, no thrown Bug" {
  val dir = freshTempDir("vt-instance")
  defer {
    cleanup(dir)
  }
  val dllPath = Path.join(dir, "ValueTaskInstanceFixture.dll")
  val srcs: List[String] = newList()
  srcs.add(valueTypeInstanceExternSource())
  val paths: List[String] = newList()
  paths.add("")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "ValueTaskInstanceFixture", sources = srcs, paths = paths))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "ValueTaskInstanceFixture",
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  var threw = false
  var produced = false
  var diagText = ""
  try {
    val res = Emitter.emitProject(req)
    match res.outputPath {
      case Some(_) -> {
        produced = true
      }
      case None -> ()
    }
    var di = 0
    while di < res.diagnostics.count {
      diagText = diagText + res.diagnostics[di].code + ": " + res.diagnostics[di].message + "\n"
      di = di + 1
    }
  } catch Bug as b {
    threw = true
  }
  assertFalse(
    threw,
    "value-type generic instance extern: the codegen refusal must be contained inside emitProject, never thrown to the caller"
  )
  assertFalse(
    produced,
    "value-type generic instance extern: emitProject reports build failure (no output artifact), not success"
  )
  // #6462: the contained refusal is a structured T0120 diagnostic in
  // `EmitResult.diagnostics` (the emitter boundary's generic wrapper — this
  // refusal carries no `T0NNN` code of its own), naming the unsupported
  // shape verbatim — the exact-message specificity the old escaping-panic
  // assertion had, restored through the result instead of a stderr seam.
  assertTrue(
    Str.contains(diagText, "T0120"),
    "value-type generic instance extern: EmitResult.diagnostics carries the T0120 wrapper (got: " + diagText + ")"
  )
  assertTrue(
    Str.contains(diagText, "INSTANCE call on a value-type generic-declaring type"),
    "value-type generic instance extern: the diagnostic names the unsupported shape (got: " + diagText + ")"
  )
}

// #7022/#7023: an `async`-declared `@externTarget` wrapper over a BCL
// method that is ALSO generic in its own right (e.g. `Task.FromResult<T>`,
// a non-generic-declaring-type static method with its own generic
// parameter, returning `Task<T>`) needs BOTH the MethodSpec instantiation
// `emitGenericMethodExternCall` builds AND the Task-unwrap machinery the
// plain (non-generic) async path relies on — neither alone is correct.
// Silently declining (leaving metadata resolution as if it found nothing)
// was tried first and found NOT to fail cleanly: the plain-method fallback
// path still builds a syntactically valid but uninstantiated MemberRef for
// the generic method, so the build succeeds and the call then throws a
// confusing `MissingMethodException` at RUNTIME instead of a clear
// build-time diagnostic. Declined LOUDLY instead, mirroring the #5809
// precedent this file already covers.
func asyncGenericMethodExternSource(): String {
  "package AsyncGenericMethodFixture\n\n" + "@externTarget(\"System.Threading.Tasks.Task.FromResult\")\n" +
    "@externStatic\n" +
    "async func fromResultAsync(value: Int): Int = ()\n\n" +
    "func main(): Unit {\n" +
    "  val r = await fromResultAsync(42)\n" +
    "  println(r)\n" +
    "}\n"
}

test "async extern wrapper over a BCL method with its own generics fails the build cleanly, no thrown Bug (#7022)" {
  val dir = freshTempDir("async-generic-method")
  defer {
    cleanup(dir)
  }
  val dllPath = Path.join(dir, "AsyncGenericMethodFixture.dll")
  val srcs: List[String] = newList()
  srcs.add(asyncGenericMethodExternSource())
  val paths: List[String] = newList()
  paths.add("")
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "AsyncGenericMethodFixture", sources = srcs, paths = paths))
  val req = Emitter.EmitProjectRequest(
    packages = pkgs,
    assemblyName = "AsyncGenericMethodFixture",
    outputPath = dllPath,
    target = Emitter.Dotnet,
    restoredDllPaths = newList(),
    activeFeatures = newList(),
    declaredFeatures = newList(),
    packageVersion = "",
    depTemplateSrcs = newList(),
    nugetAssemblyPaths = newList(),
    defines = newList()
  )
  var threw = false
  var produced = false
  var diagText = ""
  try {
    val res = Emitter.emitProject(req)
    match res.outputPath {
      case Some(_) -> {
        produced = true
      }
      case None -> ()
    }
    var di = 0
    while di < res.diagnostics.count {
      diagText = diagText + res.diagnostics[di].code + ": " + res.diagnostics[di].message + "\n"
      di = di + 1
    }
  } catch Bug as b {
    threw = true
  }
  assertFalse(
    threw,
    "async generic-method extern: the codegen refusal must be contained inside emitProject, never thrown to the caller"
  )
  assertFalse(
    produced,
    "async generic-method extern: emitProject reports build failure (no output artifact), not success"
  )
  assertTrue(
    Str.contains(diagText, "async wrapper over a BCL method that is itself declared with its own generics"),
    "async generic-method extern: the diagnostic names the unsupported shape (got: " + diagText + ")"
  )
}
