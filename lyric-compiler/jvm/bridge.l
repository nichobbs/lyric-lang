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
/// JAR write fails.  `packageName` is the Lyric package identifier the F# CLI
/// derives from the source filename — it is used as the `Lyric-Package`
/// manifest attribute.  The JVM `Main-Class` attribute is derived from the
/// source's actual `package` declaration so a Lyric program saved as
/// `hello_jvm.l` but declaring `package Hello` still produces a runnable
/// `java -jar` artefact.
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

  // Derive the JVM `Main-Class` from the source's `package` declaration.
  // ModulePath segments are joined with "." (JVM manifest convention).
  // Falls back to the F#-supplied packageName when the file has no package
  // declaration (only the synthetic stdlib bootstrap can hit that path).
  val segs = parseResult.file.packageDecl.path.segments
  var mainClassName: String = packageName
  if segs.count > 0 {
    var k = 0
    var acc = ""
    while k < segs.count {
      if k > 0 { acc = acc + "." }
      acc = acc + segs[k]
      k = k + 1
    }
    mainClassName = acc
  }

  val req = BuildRequest(
    packageName = packageName,
    mainClass   = mainClassName,
    version     = "0.1.0",
    outPath     = outputPath
  )

  writeJarFromClasses(req, classes)
}
