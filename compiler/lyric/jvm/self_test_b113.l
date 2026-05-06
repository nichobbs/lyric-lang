// jvm/self_test_b113.l — Stage B113: out-parameter lowering via int[] arrays.
//
// Demonstrates emitOutAllocInt / emitOutStoreInt / emitOutLoadInt helpers.
// A static method `addAndReturn(int a, int[] result)` stores a+1 into result[0].
// Main allocates int[1], calls addAndReturn(5, slot), reads back, prints result=6.
//
// Java output (java -jar):
//   result=6

package Jvm.SelfTestB113

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Helper class with addAndReturn(int a, int[] result): void ───────────

func makeHelperBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  // addAndReturn(int a, int[] result): void
  // slot 0 = a, slot 1 = result (int[])
  // Compute a+1, store to local slot 2, then result[0] = slot2
  emitIload(asm, 0)
  emitIconst(asm, 1)
  emitIadd(asm)
  emitIstore(asm, 2)

  emitAload(asm, 1)     // result array
  emitIconst(asm, 0)    // index
  emitIload(asm, 2)     // a+1
  emitIastore(asm)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 3, 3)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val methods: List[MethodInfo] = newList()
  methods.add(makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "addAndReturn", "(I[I)V", attrs))
  val cf = makeClassWithMethods("Helper", methods)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")
  val helperRef  = poolMethodref(pool, "Helper", "addAndReturn", "(I[I)V")

  // slot 0 = args[], slot 1 = result (int[])
  // int[] result = new int[1]
  emitOutAllocInt(asm, 1)

  // Helper.addAndReturn(5, result)
  emitIconst(asm, 5)
  emitAload(asm, 1)
  emitInvokestatic(asm, helperRef)

  // println("result=" + result[0])
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "result=")
  emitOutLoadInt(asm, 1)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 4, 2)
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
  val outDir = "/tmp/lyric-jvm-b113"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Helper", bytes = makeHelperBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main",   bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB113",
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
