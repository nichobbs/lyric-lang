// jvm/self_test_b115.l — Stage B115: makeLyricSignatureAttr (vendor class-file attribute).
//
// Builds a class with a LyricSignature class-level attribute carrying the string
// "Map[String, List[Int]]". Serializes the bytes, round-trips through
// parseClassSummary to verify the class-file structure is valid, then builds a
// JAR with a Main that prints the verification result.
//
// Java output (java -jar):
//   sig_class_valid=true

package Jvm.SelfTestB115

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver
import Jvm.Reader

// ── Build a class with a LyricSignature attribute ─────────────────────────────

func makeSignedClassBytes(pool: in Pool): List[Byte] {
  val sig = "Map[String, List[Int]]"
  val sigAttr = makeLyricSignatureAttr(sig)
  val classAttrs: List[Attribute] = newList()
  classAttrs.add(sigAttr)
  val cf = makeClassWithAttrs("Signed", classAttrs)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(signedBytes: in List[Byte], pool: in Pool): List[Byte] {
  // Round-trip: verify the serialized class is structurally valid
  val summary = parseClassSummary(signedBytes)
  val isValid = summary.magicValid and summary.majorVersion == 65

  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  emitGetstatic(asm, sysOutIdx)
  if isValid {
    emitPushString(asm, "sig_class_valid=true")
  } else {
    emitPushString(asm, "sig_class_valid=false")
  }
  emitInvokevirtual(asm, printlnIdx)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 2, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b115"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val signedBytes = makeSignedClassBytes(pool)
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Signed", bytes = signedBytes))
  classes.add(BuiltClass(binaryName = "Main",   bytes = makeMainBytes(signedBytes, pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB115",
    mainClass   = "Main",
    version     = "0.1.0",
    outPath     = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
