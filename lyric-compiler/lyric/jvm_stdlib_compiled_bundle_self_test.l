//! jvm_stdlib_compiled_bundle_self_test.l — regression coverage for #4994:
//! the JVM counterpart of #4980. When no raw `lyric-stdlib/std/` source
//! tree is reachable (the common case for an installed release, which only
//! ships compiled bundles), `Lyric.Emitter.findStdlibSourcesForTarget`
//! returned an empty source list on `--target jvm` — `Std.Core`'s declared
//! types (`Option`, `Result`, …) never resolved, and there was no JVM/JAR
//! equivalent of the `.NET`-side `stdlibSourcesFromCompiledBundle` fallback
//! (`Lyric.ContractMeta.readAllContractsFromFile`, PE/CLI-metadata-only via
//! `Msil.MetadataReader`).
//!
//! This exercises the two new pieces end to end: the WRITER side
//! (`Jvm.Bridge.compileProjectToJarBundledWithFeatures` embeds a
//! `Lyric.Contract.<Pkg>` ZIP entry per project package — the JAR-resident
//! analog of the MSIL bridge's `embedLyricContract`) and the READER side
//! (`Lyric.ContractMeta.readAllContractsFromJarFile` +
//! `Lyric.Emitter.stdlibSourcesFromCompiledBundleJvm`, mirroring
//! `Lyric.RestoredPackages.loadRestoredPackageJvm` +
//! `stdlibSourcesFromCompiledBundle`).
//!
//! Uses a small SYNTHETIC `Std.Core`-shaped fixture (an `Option[T]` /
//! `Result[T, E]` union pair, the exact shape #4980's own dotnet-side test —
//! `msil_project_bridge_self_test.l`, "stdlib types reconstruct from
//! compiled bundle contract metadata" — asserts on) rather than the real
//! 73-package stdlib: whether the REAL stdlib's every package currently
//! compiles cleanly end-to-end on `--target jvm` is an orthogonal,
//! much larger pre-existing question (docs/44/docs/59) this fix does not
//! itself need to answer to prove the metadata-embed/read/reconstruct
//! mechanism is correct.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/jvm_stdlib_compiled_bundle_self_test.l
@test_module
package Lyric.JvmStdlibCompiledBundleSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Std.ProcessCapture as Capture
import Lyric.ContractMeta as Meta
import Lyric.Emitter as Emitter
import Jvm.Bridge

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-jvm-stdlib-bundle-" + label + "-" + uuidToString(newUuid()))
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

// The `unwrapOr[T]` generic function has NO call site anywhere in this
// fixture file, deliberately: `Lyric.Mono` (shared, target-agnostic) strips
// a same-file generic `pub func` once every LOCAL call site is specialised
// — with zero local call sites, it strips `unwrapOr` unconditionally. This
// is exactly the #4994-review-caught gap: a fixture with only non-generic
// unions could never exercise `withGenericFuncsForContract`'s re-attachment
// path at all, since there is nothing for mono to strip. A real consumer
// package (unrelated to this file) is what actually calls `unwrapOr` —
// mirroring how `Std.Core.unwrapOr`/`Std.Collections.mapKeys` etc. are
// consumed in practice: never from within `core.l`/`collections.l` itself.
func fixtureStdCoreSource(): String {
  "package Std.Core\n\n" + "pub union Option[T] {\n" + "  case Some(value: T)\n" + "  case None\n" + "}\n" + "\n" +
    "pub union Result[T, E] {\n" +
    "  case Ok(value: T)\n" +
    "  case Err(error: E)\n" +
    "}\n" +
    "\n" +
    "pub func unwrapOr[T](o: Option[T], default: T): T {\n" +
    "  match o {\n" +
    "    case Some(v) -> v\n" +
    "    case None -> default\n" +
    "  }\n" +
    "}\n"
}

test "compileProjectToJarBundledWithFeatures embeds Lyric.Contract.<Pkg>, readable back via readAllContractsFromJarFile (#4994)" {
  val dir = freshTempDir("writer-reader")
  defer {
    cleanup(dir)
  }
  val jarPath = Path.join(dir, "fixture.jar")
  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(fixtureStdCoreSource())
  val noSrcs: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noDeps: List[String] = newList()
  val noDefines: List[String] = newList()
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    "Std.Core",
    noSrcs,
    noFeatures,
    noFeatures,
    noDeps,
    noDefines,
    "0.1.0"
  )
  assertTrue(ok, "compile: fixture Std.Core package compiles to a JAR")
  assertTrue(File.fileExists(jarPath), "compile: JAR file exists")

  val entries = Meta.readAllContractsFromJarFile(jarPath)
  assertEqualInt(entries.count, 1, "readAllContractsFromJarFile: one Lyric.Contract.<Pkg> entry")
  assertEqual(
    entries[0].packageName,
    "Std.Core",
    "readAllContractsFromJarFile: package name recovered from the entry name"
  )
  assertTrue(Str.contains(entries[0].json, "Option"), "readAllContractsFromJarFile: contract JSON mentions Option")
  assertTrue(Str.contains(entries[0].json, "Result"), "readAllContractsFromJarFile: contract JSON mentions Result")
  // #4994 review finding: the monomorphizer strips a same-file generic pub
  // func with no local call site (see fixtureStdCoreSource's comment) —
  // without `withGenericFuncsForContract`'s re-attachment, `unwrapOr` would
  // be silently absent here even though it compiled and codegen'd fine.
  assertTrue(
    Str.contains(entries[0].json, "unwrapOr"),
    "readAllContractsFromJarFile: contract JSON retains the generic pub func unwrapOr, " +
      "which Lyric.Mono strips from the post-mono file (#4994 review finding)"
  )
}

test "readAllContractsFromJarFile is graceful on a missing file and a non-Lyric JAR (#4994)" {
  val dir = freshTempDir("graceful")
  defer {
    cleanup(dir)
  }
  val missing = Path.join(dir, "does-not-exist.jar")
  assertEqualInt(
    Meta.readAllContractsFromJarFile(missing).count,
    0,
    "readAllContractsFromJarFile: missing file -> empty list"
  )

  // A non-Lyric JAR: valid ZIP, no `Lyric.Contract*` entry.
  val plainJar = Path.join(dir, "plain.jar")
  match File.writeText(plainJar, "not actually a zip, but must not crash the reader") {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + plainJar + ": " + IOError.message(e))
  }
  assertEqualInt(
    Meta.readAllContractsFromJarFile(plainJar).count,
    0,
    "readAllContractsFromJarFile: malformed/non-ZIP file -> empty list, no panic"
  )
}

test "stdlibSourcesFromCompiledBundleJvm reconstructs Std.Core from an installed Lyric.Stdlib.Jvm.jar, and a real consumer compiles against it (#4994)" {
  val dir = freshTempDir("fallback")
  defer {
    cleanup(dir)
  }
  val libDir = Path.join(dir, "lib")
  match File.createDir(libDir) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create lib dir: " + IOError.message(e))
  }
  val jarPath = Path.join(libDir, "Lyric.Stdlib.Jvm.jar")

  val pkgSrcs: List[String] = newList()
  pkgSrcs.add(fixtureStdCoreSource())
  val noSrcs: List[String] = newList()
  val noFeatures: List[String] = newList()
  val noDeps: List[String] = newList()
  val noDefines: List[String] = newList()
  val ok = compileProjectToJarBundledWithFeatures(
    pkgSrcs,
    jarPath,
    "Std.Core",
    noSrcs,
    noFeatures,
    noFeatures,
    noDeps,
    noDefines,
    "0.1.0"
  )
  assertTrue(ok, "compile: fixture Lyric.Stdlib.Jvm.jar compiles")

  val prevStdlibBin = match Environment.getVar("LYRIC_STDLIB_BIN") { case Ok(v) -> v; case Err(_) -> "" }
  Environment.setVar("LYRIC_STDLIB_BIN", libDir)
  val sources = Emitter.stdlibSourcesFromCompiledBundleJvm()
  Environment.setVar("LYRIC_STDLIB_BIN", prevStdlibBin)

  assertEqualInt(sources.count, 1, "stdlibSourcesFromCompiledBundleJvm: one reconstructed package source")
  assertTrue(
    Str.contains(sources[0], "Option"),
    "stdlibSourcesFromCompiledBundleJvm: reconstructed source declares Option"
  )
  assertTrue(
    Str.contains(sources[0], "Result"),
    "stdlibSourcesFromCompiledBundleJvm: reconstructed source declares Result"
  )
  assertTrue(
    Str.contains(sources[0], "unwrapOr"),
    "stdlibSourcesFromCompiledBundleJvm: reconstructed source retains the generic pub func unwrapOr " +
      "(#4994 review finding — Lyric.Mono strips it from the compiled bundle's post-mono file without " +
      "Jvm.Bridge's withGenericFuncsForContract re-attachment)"
  )

  // Prove the reconstructed declaration-only source is actually usable, not
  // merely string-shaped: a real consumer package referencing `Option[Int]`
  // / `Some` / `None` through `import Std.Core` must compile and codegen
  // cleanly against it — exactly what a real `--target jvm` build against
  // only an installed SDK (no raw stdlib source tree reachable) needs this
  // fallback to do for `Std.Core`. Also CALLS the cross-package generic
  // `unwrapOr[Int]` (not just references a type) — the consumer-side
  // monomorphizer specialises it from `sources`' declaration via the same
  // `collectStdlibGenericFuncsJvm` path a real `Std.Core` import uses, so a
  // dropped `unwrapOr` declaration would fail this call with an unknown-name
  // error, not merely a missing substring.
  val consumerSrc = "package Consumer\n\n" + "import Std.Core\n\n" + "func main(): Int {\n" +
    "  val o: Option[Int] = None\n" +
    "  unwrapOr(o, 42)\n" +
    "}\n"
  val consumerPkgs: List[String] = newList()
  consumerPkgs.add(consumerSrc)
  val consumerOut = Path.join(dir, "consumer.jar")
  val consumerOk = compileProjectToJarBundledWithFeatures(
    consumerPkgs,
    consumerOut,
    "Consumer",
    sources,
    noFeatures,
    noFeatures,
    noDeps,
    noDefines,
    "0.1.0"
  )
  assertTrue(
    consumerOk,
    "stdlibSourcesFromCompiledBundleJvm: the reconstructed Std.Core source lets a real consumer using " +
      "Option/Some/None compile and codegen cleanly (previously Std.Core resolved to an empty source list on jvm)"
  )

  val args: List[String] = newList()
  args.add("-jar")
  args.add(consumerOut)
  val result = Capture.runCaptureWithDiagnostics("java", args, "")
  assertEqualInt(
    result.exitCode,
    42,
    "stdlibSourcesFromCompiledBundleJvm: the consumer actually RUNS and its call into the reconstructed " +
      "generic unwrapOr[Int] produces the right value (None -> default 42), not just a build-time pass (stderr=" +
      result.stderr +
      ")"
  )
}
