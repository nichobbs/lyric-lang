// jvm/self_test_b27.l — Stage B27: double arithmetic (ldc2_w, dload, dadd, ddiv, dreturn).
//
// Generates DoubleMath.class with a static average(D,D)D method that returns
// (a + b) / 2.0.  Main calls average(3.0, 7.0) and prints 5.0.
//
// Exercises: emitPushDouble (ldc2_w), dload (wide-slot params, 2 slots each),
// dadd, ddiv, dreturn, and println(D) for double output.

package Jvm.SelfTestB27

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeDoubleMathClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // average(D,D)D
  //   dload_0   (first  double param — occupies slots 0-1)
  //   dload_2   (second double param — occupies slots 2-3)
  //   dadd
  //   ldc2_w 2.0
  //   ddiv
  //   dreturn
  emitDload(asm, 0)
  emitDload(asm, 2)
  emitDadd(asm)
  emitPushDouble(asm, 2.0)
  emitDdiv(asm)
  emitDreturn(asm)

  // doubles take 2 stack slots each; max_stack = 4 (two doubles before dadd)
  val codeAttr = assembleCode(asm, 4, 4)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val avgMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "average",
    "(DD)D",
    attrs
  )
  val methods: List[MethodInfo] = newList()
  methods.add(avgMethod)
  val cf = makeClassWithMethods("DoubleMath", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val avgRef   = poolMethodref(pool, "DoubleMath", "average", "(DD)D")
  val printlnD = poolMethodref(pool, "java/io/PrintStream", "println", "(D)V")

  // System.out.println(DoubleMath.average(3.0, 7.0))
  emitGetstatic(asm, sysOut)
  emitPushDouble(asm, 3.0)
  emitPushDouble(asm, 7.0)
  emitInvokestatic(asm, avgRef)
  emitInvokevirtual(asm, printlnD)
  emitReturn(asm)

  // Stack: [ps, double(2), double(2)] before invokestatic = 5 slots
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
  val outDir = "/tmp/lyric-jvm-b27"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val doubleMathBytes = makeDoubleMathClassBytes()
  val mainBytes       = makeMainClassBytes()

  val doubleMathClass = BuiltClass(binaryName = "DoubleMath", bytes = doubleMathBytes)
  val mainClass       = BuiltClass(binaryName = "Main",       bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(doubleMathClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB27",
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
