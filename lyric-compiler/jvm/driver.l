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
  val meta = PackageMeta(packageName = req.packageName, mainClass = req.mainClass, version = req.version)

  val mfBytes = stringToUtf8Bytes(makeManifestMf(meta))

  val jarEntries: List[ZipEntry] = newList()
  jarEntries.add(ZipEntry(name = "META-INF/MANIFEST.MF", data = mfBytes))

  var i = 0
  while i < classes.count {
    val bc = classes[i]
    jarEntries.add(ZipEntry(name = bc.binaryName + ".class", data = bc.bytes))
    i = i + 1
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
