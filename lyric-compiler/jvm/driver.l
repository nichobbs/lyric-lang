//! jvm/driver.l — Stage B12: build driver skeleton.
//!
//! Ties together Jvm.Manifest, Jvm.Zip, and Std.File to produce a runnable
//! JAR from pre-assembled class bytes.  This is the bootstrap-grade driver
//! (§23.9): synchronous, no subprocess invocation, no dependency resolution.
//! The async full driver (parallel file emission, native-image invocation)
//! is a Phase 6 deliverable once the language has structured concurrency on JVM.
package Jvm.Driver

import Std.Core
import Std.Collections
import Std.File
import Jvm.Manifest
import Jvm.Zip

// Request record for a single-package JAR build.
pub record BuildRequest {
  packageName: String
  // dotted Lyric name,  e.g. "Hello"
  mainClass: String
  // JVM binary name,    e.g. "Hello"
  version: String
  // semver,              e.g. "0.1.0"
  outPath: String
  // destination path,   e.g. "/tmp/out/hello.jar"
  classpathJars: List[String] = []
  // absolute Maven/non-JDK JAR paths; see PackageMeta.classpathJars
  // One compiled class file to include in the JAR.
}

pub record BuiltClass {
  binaryName: String
  // JVM binary name without ".class", e.g. "Hello"
  bytes: List[Byte]
  // raw class-file bytes
  // Assemble a JAR from pre-built class files and write it to outPath.
  // Returns true on success, false if writeBytes fails.
}

pub func writeJarFromClasses(req: in BuildRequest, classes: in List[BuiltClass]): Bool {
  val noNames: List[String] = newList()
  val noDatas: List[List[Byte]] = newList()
  writeJarFromClassesWithResources(req, classes, noNames, noDatas)
}

// Like `writeJarFromClasses`, but also stores extra raw resource entries —
// e.g. `Lyric.Contract.<Pkg>` metadata (#4994) — alongside the class files.
// `extraNames[i]` / `extraDatas[i]` are parallel (same count): a ZIP entry
// name and its raw byte content. Plain parallel lists rather than a
// `Jvm.Zip.ZipEntry` list: passing that record across the `Jvm.Bridge` →
// `Jvm.Driver` boundary used to hit a cross-file nominal-type-identity
// mismatch (`Jvm.Bridge` also imports `Jvm.AutoFfi`, which imports
// `Jvm.ZipReader` — a DIFFERENT, same-named `ZipEntry` record — and a
// qualified `Jvm.Zip.ZipEntry` reference at the `Jvm.Bridge` call site
// resolved to the wrong one). Root-caused and fixed in #6689
// (D-progress-880): `Msil.Codegen.typeExprToMsilCtx`'s `TRef` case
// discarded a qualified type reference's owner package entirely, resolving
// purely by the referencing file's own scope-priority. This parallel-list
// representation is kept regardless — it remains a legitimate, harmless
// representation on its own merits, not a workaround needed for the fix. A
// separate entry point rather than widening `writeJarFromClasses` itself:
// that function has ~100 direct self-test call sites across
// `jvm/self_test_b*.l`, none of which need resource embedding.
pub func writeJarFromClassesWithResources(
  req: in BuildRequest,
  classes: in List[BuiltClass],
  extraNames: in List[String],
  extraDatas: in List[List[Byte]],
): Bool {
  val meta = PackageMeta(
    packageName = req.packageName,
    mainClass = req.mainClass,
    version = req.version,
    classpathJars = req.classpathJars
  )

  val mfBytes = stringToUtf8Bytes(makeManifestMf(meta))

  val jarEntries: List[Jvm.Zip.ZipEntry] = newList()
  jarEntries.add(Jvm.Zip.ZipEntry(name = "META-INF/MANIFEST.MF", data = mfBytes))

  var i = 0
  while i < classes.count {
    val bc = classes[i]
    jarEntries.add(Jvm.Zip.ZipEntry(name = bc.binaryName + ".class", data = bc.bytes))
    i = i + 1
  }

  var ei = 0
  while ei < extraNames.count {
    jarEntries.add(ZipEntry(name = extraNames[ei], data = extraDatas[ei]))
    ei = ei + 1
  }

  val jarBytes = buildJar(jarEntries)

  var wrote = false
  match writeBytes(req.outPath, jarBytes) {
    case Ok(_) -> {
      wrote = true
    }
    case Err(_) -> ()
  }
  wrote
}
