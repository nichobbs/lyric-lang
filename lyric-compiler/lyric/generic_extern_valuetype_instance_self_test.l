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
//! #6449 (D-progress-762): `Msil.Bridge`'s `codegenMPackage` call sites now
//! contain every codegen panic as a printed `T0119`/`T0120` diagnostic plus
//! a failed build, so the refusal no longer escapes `emitProject` as a
//! catchable `Bug` — this test asserts the CONTAINED-failure contract
//! (no throw, no output artifact), the same shape as
//! `msil_project_bridge_self_test.l`'s updated twin. The refusal message
//! itself still reaches stderr through the T0120 wrapper; asserting on its
//! text from here needs the stderr-capture seam tracked in #6455.
//!
//! Pulls in `Lyric.Emitter`, so `LYRIC_LOAD_COMPILER=1` is needed for
//! `lyric test` to resolve it:
//!
//!   LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/generic_extern_valuetype_instance_self_test.l
//!
//! `msil_project_bridge_self_test.l` ("instance call on a value-type
//! generic-declaring extern fails the build cleanly, no thrown Bug")
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
  val pkgs: List[Emitter.ProjectPackage] = newList()
  pkgs.add(Emitter.ProjectPackage(name = "ValueTaskInstanceFixture", sources = srcs))
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
  try {
    val res = Emitter.emitProject(req)
    match res.outputPath {
      case Some(_) -> {
        produced = true
      }
      case None -> ()
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
}
