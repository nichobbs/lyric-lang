//! jvm/self_test_b119.l — Stage B119: lowerHotAsync (CompletableFuture two-stage chain).
//!
//! Creates a host class `Compute` with a static async method `doubleOne()`:
//!   - Stage 1: returns Integer.valueOf(1) (wrapped in completedFuture)
//!   - Stage 2: receives Integer(1), unboxes, multiplies by 2, boxes result
//! Main calls Compute.doubleOne().get() and prints result=2.
//!
//! Java output (java -jar):
//!   result=2
package Jvm.SelfTestB119

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Compute class with async doubleOne() ────────────────────────────────
func makeComputeClasses(pool: in Pool): List[BuiltClass] {
  val integerType = JRef(className = "java/lang/Integer")
  val objectType = JRef(className = "java/lang/Object")

  // Stage 1: push Integer.valueOf(1) onto stack
  val intValOfPs: List[JvmType] = newList()
  intValOfPs.add(JInt)
  val stage1: List[LInsn] = newList()
  stage1.add(LIconst(v = 1))
  stage1.add(LInvokestatic(owner = "java/lang/Integer", name = "valueOf", params = intValOfPs, ret = integerType))

  // Stage 2: stack has Object(Integer(1)); cast, unbox, *2, box
  val intValuePs: List[JvmType] = newList()
  val intValOf2Ps: List[JvmType] = newList()
  intValOf2Ps.add(JInt)
  val stage2: List[LInsn] = newList()
  stage2.add(LCheckcast(className = "java/lang/Integer"))
  stage2.add(LInvokevirtual(owner = "java/lang/Integer", name = "intValue", params = intValuePs, ret = JInt))
  stage2.add(LIconst(v = 2))
  stage2.add(LImul)
  stage2.add(LInvokestatic(owner = "java/lang/Integer", name = "valueOf", params = intValOf2Ps, ret = integerType))

  val h = LHotFunc(
    className = "Compute",
    methodName = "doubleOne",
    resultType = objectType,
    stage1Insns = stage1,
    stage2Insns = stage2
  )
  val cfs = lowerHotAsync(h, pool)

  val result: List[BuiltClass] = newList()
  for cf in cfs.toArray() {
    result.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
  }
  result
}

// ── Build Main class ──────────────────────────────────────────────────────────
func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(Ljava/lang/Object;)Ljava/lang/String;")

  val cfType = "java/util/concurrent/CompletableFuture"
  val doubleOne = poolMethodref(pool, "Compute", "doubleOne", "()Ljava/util/concurrent/CompletableFuture;")
  val getPs: List[JvmType] = newList()
  val cfGetRef = poolMethodref(pool, cfType, "get", "()Ljava/lang/Object;")

  // CompletableFuture cf = Compute.doubleOne()
  emitInvokestatic(asm, doubleOne)
  emitAstore(asm, 1)

  // Object result = cf.get()
  emitAload(asm, 1)
  emitInvokevirtual(asm, cfGetRef)
  emitAstore(asm, 2)

  // println("result=" + result.toString())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "result=")
  emitAload(asm, 2)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 4, 3)
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
  val outDir = "/tmp/lyric-jvm-b119"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  for bc in makeComputeClasses(pool).toArray() {
    classes.add(bc)
  }
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB119",
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
