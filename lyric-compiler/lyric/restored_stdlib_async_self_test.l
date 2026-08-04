//! restored_stdlib_async_self_test.l — regression test for #6372: a
//! restored-stdlib `async func`'s reconstructed signature silently lost
//! its `async` marker, so a release-installed toolchain (one with no
//! `lyric-stdlib/std/` source tree to compile Std.* from — the normal case
//! for `dotnet tool install -g lyric` / the SDK distribution) mis-encoded
//! every `Std.*` async function's cross-assembly call site as synchronous.
//!
//! `Lyric.Emitter.stdlibSourcesFromCompiledBundle` is the exact fallback a
//! release-installed CLI takes when no stdlib source is reachable: it reads
//! `Lyric.Stdlib.dll`'s embedded contract metadata and reconstructs each
//! package's source from the `repr` strings (`Lyric.RestoredPackages.synthesiseSource`).
//! `Msil.Codegen.registerStdlibFunc` then trusts the reconstructed
//! `FunctionDecl.isAsync` flag directly to decide whether to Task-wrap the
//! cross-assembly `MemberRef` return type — unlike the general restored-package
//! path (`registerRestoredFunc`), which independently re-derives asyncness from
//! the producer DLL's real MethodDef metadata (`Mdr.dllTaskReturningFuncs`,
//! #5561, covered by `restored_async_self_test.l`) and so was never affected by
//! this bug. Before the fix, `Lyric.ContractMeta.reprForFunc` never emitted the
//! `async` keyword, so every restored `Std.*` async function (e.g.
//! `Std.Http.sendAsync`) reconstructed here as a *synchronous* function,
//! producing a `MissingMethodException` at runtime once actually consumed by a
//! release-installed toolchain (the exact shape reported in #6372, verified by
//! reproducing it against a stage0-seeded stage-1 build).
//!
//! This test drives `stdlibSourcesFromCompiledBundle` directly against the
//! REAL `Lyric.Stdlib.dll` this checkout's own bootstrap produced (found via
//! the same `findCompiledStdlibDir` search a release install uses), re-parses
//! the reconstructed `Std.Http` source, and asserts `sendAsync`'s `isAsync`
//! flag survives the round-trip.
//!
//! Run via `LYRIC_LOAD_COMPILER=1 lyric test lyric-compiler/lyric/restored_stdlib_async_self_test.l`
//! (imports `Lyric.Emitter`, a compiler package).
@test_module
package Lyric.RestoredStdlibAsyncSelfTest

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Lyric.Emitter as Emitter
import Lyric.Parser

// Find the reconstructed `Std.Http` source among every reconstructed stdlib
// package source, or panic — a miss here means `Lyric.Stdlib.dll` could not
// be located at all (an environment problem, not the bug under test).
func findReconstructedPackage(sources: in List[String], pkgName: in String): SourceFile {
  var i = 0
  while i < sources.count {
    val pr = parse(sources[i])
    if modulePathJoin(pr.file.packageDecl.path.segments) == pkgName {
      return pr.file
    }
    i = i + 1
  }
  panic(
    "findReconstructedPackage: '" + pkgName + "' not among " + toString(sources.count) + " reconstructed stdlib sources"
  )
}

func findFunc(file: in SourceFile, name: in String): FunctionDecl {
  var i = 0
  while i < file.items.count {
    match file.items[i].kind {
      case IFunc(decl) -> if decl.name == name { return decl }
      case _ -> ()
    }
    i = i + 1
  }
  panic("findFunc: '" + name + "' not found in reconstructed source")
}

test "stdlib compiled-bundle fallback preserves async on Std.Http.sendAsync (#6372)" {
  val sources = Emitter.stdlibSourcesFromCompiledBundle()
  assertTrue(
    sources.count > 0,
    "restored_stdlib_async: stdlib bundle sources non-empty (Lyric.Stdlib.dll must be findable via findCompiledStdlibDir — run `make lyric` first)"
  )
  val httpFile = findReconstructedPackage(sources, "Std.Http")
  val sendAsync = findFunc(httpFile, "sendAsync")
  assertTrue(
    sendAsync.isAsync,
    "restored_stdlib_async: reconstructed Std.Http.sendAsync must carry isAsync = true — " +
      "before the #6372 fix this was silently false, causing registerStdlibFunc to encode " +
      "a synchronous (non-Task-wrapped) cross-assembly MemberRef against the real async DLL method"
  )
}

test "stdlib compiled-bundle fallback preserves async on Std.Http.HttpResponse.bodyText (#6372)" {
  val sources = Emitter.stdlibSourcesFromCompiledBundle()
  val httpFile = findReconstructedPackage(sources, "Std.Http")
  val bodyText = findFunc(httpFile, "HttpResponse.bodyText")
  assertTrue(
    bodyText.isAsync,
    "restored_stdlib_async: reconstructed Std.Http.HttpResponse.bodyText must carry isAsync = true"
  )
}
