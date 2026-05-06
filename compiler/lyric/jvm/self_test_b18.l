// jvm/self_test_b18.l — Stage B18: StackMapTable generation for manual assembly.
//
// Repeats the abs(I)I test from B17 but targets Java 21 (major=65) by using
// assembleCodeWithFrames instead of assembleCode.  Verifies that the JVM
// verifier accepts the generated class file without -noverify.
//
// Exercises: VerifierType.VInteger, assembleCodeWithFrames, full_frame entries.

package Jvm.SelfTestB18

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMathClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // abs(I)I with conditional branch — now generates StackMapTable
  emitIload(asm, 0)
  emitIfge(asm, "positive")
  emitIload(asm, 0)
  emitIneg(asm)
  emitIreturn(asm)
  emitLabel(asm, "positive")
  emitIload(asm, 0)
  emitIreturn(asm)

  // Frame at "positive": one local slot (slot 0) of type VInteger.
  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VInteger)
  val codeAttr = assembleCodeWithFrames(asm, 1, 1, frameLocals)

  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val absMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "abs", "(I)I", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(absMethod)
  // Java 21 (major=65) — verifier now accepts the StackMapTable.
  val cf = makeClassWithMethods("MathB18", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val absRef   = poolMethodref(pool, "MathB18", "abs", "(I)I")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -7)
  emitInvokestatic(asm, absRef)
  emitInvokevirtual(asm, printlnI)

  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 3)
  emitInvokestatic(asm, absRef)
  emitInvokevirtual(asm, printlnI)

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

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b18"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val mathBytes = makeMathClassBytes()
  val mainBytes = makeMainClassBytes()

  val mathClass = BuiltClass(binaryName = "MathB18", bytes = mathBytes)
  val mainClass = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(mathClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB18",
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
