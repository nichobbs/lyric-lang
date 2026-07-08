//! jvm/manifest.l — Stage B10: JAR manifest and lyric-contract metadata emission.
//!
//! Generates the two text artefacts that accompany a Lyric JVM package:
//!   META-INF/MANIFEST.MF            — standard JAR manifest (RFC 822-style key-value text)
//!   META-INF/lyric/<P>.lyric-contract — package public-contract stub (JSON)
//!
//! Both outputs are pure string generation; file I/O is the Driver's job.
//! The four native-image JSON configs are handled separately by Jvm.NativeImage.
package Jvm.Manifest

import Std.Core
import Std.Collections

// Metadata about a Lyric package being lowered to a JAR.
pub record PackageMeta {
  packageName: String
  // dotted Lyric name, e.g. "Jvm.Classfile"
  mainClass: String
  // JVM binary name, e.g. "jvm/classfile/Program"
  version: String
  // semver string, e.g. "0.1.0"
  // Absolute paths to Maven/non-JDK JARs the compiled package's auto-FFI
  // resolved against (from LYRIC_FFI_JARS, itself populated from a
  // restored project's `target/restore/jvm-classpath.txt`).  Embedded as
  // a manifest `Class-Path:` attribute so `java -jar` (used by both
  // `lyric run --target jvm` and `lyric test --target jvm`, neither of
  // which passes `-cp`) can actually load them at runtime — without this,
  // any `[maven]` dependency compiles fine but throws NoClassDefFoundError
  // the moment the compiled JAR is run.  Empty for packages with no Maven
  // deps, in which case no `Class-Path:` line is emitted at all.
  classpathJars: List[String] = []
  // Description of one exported function in a lyric-contract.
}

pub record ExportedFunc {
  name: String
  // unqualified name, e.g. "parseClassSummary"
  descriptor: String
  // JVM method descriptor, e.g. "([B)Ljvm/reader/ClassSummary;"
  // Build a MANIFEST.MF string for the given package.
  // Produces standard JAR manifest format: one "Key: Value\n" pair per line
  // followed by a blank line (required by the JAR spec).
}

// Wrap a "Key: value" manifest line at 72 bytes per the JAR spec (§Notes on
// Manifest and Signature Files): a line longer than 72 bytes continues onto
// following lines, each prefixed with a single space (which itself counts
// toward that line's 72-byte budget).  Byte-chunked with no regard for word
// boundaries, matching the reference `jar` tool's own behaviour.
func wrapManifestLine(key: in String, value: in String): String {
  val full = key + ": " + value
  if full.length <= 72 {
    return full + "\n"
  }
  var result = ""
  var remaining = full
  var first = true
  while remaining.length > 0 {
    val limit = if first { 72 } else { 71 }
    val prefix = if first { "" } else { " " }
    if remaining.length <= limit {
      result = result + prefix + remaining + "\n"
      remaining = ""
    } else {
      result = result + prefix + remaining.substring(0, limit) + "\n"
      remaining = remaining.substring(limit, remaining.length - limit)
    }
    first = false
  }
  result
}

func joinWithSpace(items: in List[String]): String {
  var result = ""
  var i = 0
  while i < items.count {
    if i > 0 {
      result = result + " "
    }
    result = result + items[i]
    i = i + 1
  }
  result
}

pub func makeManifestMf(meta: in PackageMeta): String {
  val classPathLine = if meta.classpathJars.count > 0 {
    wrapManifestLine("Class-Path", joinWithSpace(meta.classpathJars))
  } else {
    ""
  }
  "Manifest-Version: 1.0\n" + "Main-Class: " + meta.mainClass + "\n" + "Lyric-Package: " + meta.packageName + "\n" +
    "Lyric-Version: " +
    meta.version +
    "\n" +
    classPathLine +
    "\n"
}

// Build a lyric-contract JSON stub listing exported functions.
// Format mirrors the .NET emitter's embedded Lyric.Contract resource.
pub func makeLyricContractJson(meta: in PackageMeta, exports: in List[ExportedFunc]): String {
  var body = "{\n  \"package\": \"" + meta.packageName + "\",\n  \"version\": \"" + meta.version +
    "\",\n  \"exports\": ["
  var i = 0
  while i < exports.count {
    val f = exports[i]
    if i > 0 {
      body = body + ","
    }
    body = body + "\n    {\"name\": \"" + f.name + "\", \"descriptor\": \"" + f.descriptor + "\"}"
    i = i + 1
  }
  body = body + "\n  ]\n}\n"
  body
}
