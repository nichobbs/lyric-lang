//! jvm/self_test_b17.l — Stage B17: conditional branching (ifeq/ifge/goto + labels).
//!
//! Generates two class files:
//!   MathB17.class — static abs(I)I implemented with ifge + goto
//!   Main.class    — calls abs(-7) and abs(3), prints both results
//!
//! Exercises: emitLabel, emitIfge, emitGoto, emitIneg, ireturn,
//! the two-pass label resolution in the assembler.
//! Assembled into /tmp/lyric-jvm-b17/hello.jar; verified by JvmLoweringB17Test.
package Jvm.SelfTestB17

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMathClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // abs(I)I:  if (arg >= 0) goto positive; else negate and return
  emitIload(asm, 0)
  emitIfge(asm, "positive")
  emitIload(asm, 0)
  emitIneg(asm)
  emitIreturn(asm)
  emitLabel(asm, "positive")
  emitIload(asm, 0)
  emitIreturn(asm)

  val codeAttr = assembleCode(asm, 1, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val absMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "abs", "(I)I", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(absMethod)
  // Use Java 5 target (major=49): no StackMapTable required for conditional branches.
  // Once B18 adds StackMap generation, this can be upgraded to major=65.
  val cf = makeClassWithMethodsV49("MathB17", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val absRef = poolMethodref(pool, "MathB17", "abs", "(I)I")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // println(abs(-7))
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, -7)
  emitInvokestatic(asm, absRef)
  emitInvokevirtual(asm, printlnI)

  // println(abs(3))
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
  val outDir = "/tmp/lyric-jvm-b17"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val mathBytes = makeMathClassBytes()
  val mainBytes = makeMainClassBytes()

  val mathClass = BuiltClass(binaryName = "MathB17", bytes = mathBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(mathClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB17",
    mainClass = "Main",
    version = "0.1.0",
    outPath = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
