//! jvm/self_test_b26.l — Stage B26: long arithmetic (ldc2_w, lload, lmul, lreturn).
//!
//! Generates LongMath.class with a static product(J,J)J method that multiplies
//! two longs and returns the result.  Main calls product(1000000L, 1000000L)
//! and prints 1000000000000 (one trillion).
//!
//! Exercises: emitPushLong (ldc2_w), lload (wide slot semantics), lmul, lreturn,
//! and println(J) for long output.
package Jvm.SelfTestB26

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeLongMathClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // product(J,J)J
  //   lload_0   (first  long param — occupies slots 0-1)
  //   lload_2   (second long param — occupies slots 2-3)
  //   lmul
  //   lreturn
  emitLload(asm, 0)
  emitLload(asm, 2)
  emitLmul(asm)
  emitLreturn(asm)

  // longs take 2 stack slots each; max_stack = 4 (two longs before lmul)
  val codeAttr = assembleCode(asm, 4, 4)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val productMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "product", "(JJ)J", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(productMethod)
  val cf = makeClassWithMethods("LongMath", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val productRef = poolMethodref(pool, "LongMath", "product", "(JJ)J")
  val printlnJ = poolMethodref(pool, "java/io/PrintStream", "println", "(J)V")

  // System.out.println(LongMath.product(1000000L, 1000000L))
  emitGetstatic(asm, sysOut)
  emitPushLong(asm, 1000000i64)
  emitPushLong(asm, 1000000i64)
  emitInvokestatic(asm, productRef)
  emitInvokevirtual(asm, printlnJ)
  emitReturn(asm)

  // Stack: [ps, long(2), long(2)] before invokestatic = 5 slots; result long = 2 slots
  // max_stack = 5 (ps + two longs), max_locals = 1
  val codeAttr = assembleCode(asm, 5, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b26"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val longMathBytes = makeLongMathClassBytes()
  val mainBytes = makeMainClassBytes()

  val longMathClass = BuiltClass(binaryName = "LongMath", bytes = longMathBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(longMathClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB26",
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
