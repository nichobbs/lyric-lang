// jvm/bridge.l — Self-hosted JVM compilation pipeline (Phase R4).
//
// Public entry point that chains the self-hosted Lyric pipeline to produce a
// JAR file from Lyric source text.  Calls parse → codegen → lower → write.

package Jvm.Bridge

import Std.Core
import Std.Collections
import Lyric.Lexer
import Lyric.Parser
import Jvm.Kernel
import Jvm.Classfile
import Jvm.Lowering
import Jvm.Codegen
import Jvm.Driver

/// Compile `source` to a JAR at `outputPath`.
///
/// Returns true on success; false if the source contains parse errors or the
/// JAR write fails.  `packageName` is used as both the Lyric package name and
/// the JVM main-class attribute in the manifest.
pub func compileToJar(source: in String, outputPath: in String, packageName: in String): Bool {
  val parseResult = parse(source)

  // Abort on any error-severity diagnostic.
  var hasErrors = false
  var i = 0
  while i < parseResult.diagnostics.count {
    val diag = parseResult.diagnostics[i]
    match diag.severity {
      case DiagError   -> { hasErrors = true }
      case DiagWarning -> { () }
    }
    i = i + 1
  }
  if hasErrors { return false }

  val pkg    = codegenPackage(parseResult.file)
  val pool   = poolNew()
  val classFiles = lowerPackage(pkg, pool)

  val classes: List[BuiltClass] = newList()
  var j = 0
  while j < classFiles.count {
    val cf = classFiles[j]
    classes.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
    j = j + 1
  }

  val req = BuildRequest(
    packageName = packageName,
    mainClass   = packageName,
    version     = "0.1.0",
    outPath     = outputPath
  )

  writeJarFromClasses(req, classes)
}
