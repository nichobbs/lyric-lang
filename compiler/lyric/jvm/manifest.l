// jvm/manifest.l — Stage B10: JAR manifest and lyric-contract metadata emission.
//
// Generates the two text artefacts that accompany a Lyric JVM package:
//   META-INF/MANIFEST.MF            — standard JAR manifest (RFC 822-style key-value text)
//   META-INF/lyric/<P>.lyric-contract — package public-contract stub (JSON)
//
// Both outputs are pure string generation; file I/O is the Driver's job.
// The four native-image JSON configs are handled separately by Jvm.NativeImage.

package Jvm.Manifest

import Std.Core
import Std.Collections

// Metadata about a Lyric package being lowered to a JAR.
pub record PackageMeta {
  packageName: String   // dotted Lyric name, e.g. "Jvm.Classfile"
  mainClass:   String   // JVM binary name, e.g. "jvm/classfile/Program"
  version:     String   // semver string, e.g. "0.1.0"
}

// Description of one exported function in a lyric-contract.
pub record ExportedFunc {
  name:       String   // unqualified name, e.g. "parseClassSummary"
  descriptor: String   // JVM method descriptor, e.g. "([B)Ljvm/reader/ClassSummary;"
}

// Build a MANIFEST.MF string for the given package.
// Produces standard JAR manifest format: one "Key: Value\n" pair per line
// followed by a blank line (required by the JAR spec).
pub func makeManifestMf(meta: in PackageMeta): String {
  "Manifest-Version: 1.0\n" +
  "Main-Class: " + meta.mainClass + "\n" +
  "Lyric-Package: " + meta.packageName + "\n" +
  "Lyric-Version: " + meta.version + "\n" +
  "\n"
}

// Build a lyric-contract JSON stub listing exported functions.
// Format mirrors the .NET emitter's embedded Lyric.Contract resource.
pub func makeLyricContractJson(meta: in PackageMeta, exports: in List[ExportedFunc]): String {
  var body = "{\n  \"package\": \"" + meta.packageName + "\",\n  \"version\": \"" + meta.version + "\",\n  \"exports\": ["
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
