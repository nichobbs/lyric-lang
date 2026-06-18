// jvm/self_test_b121.l — Stage B121: lowerFuncWithContract (inline requires/ensures guards).
//
// Creates a `safeDivide(a: int, b: int): int` method with:
//   requires: b != 0  (push b; lowerFuncWithContract checks ifne; throws AssertionError if 0)
//   ensures:  (empty — no post-condition check)
// Main calls safeDivide(10, 2) → result=5 and safeDivide(15, 3) → result=5.
//
// Java output (java -jar):
//   result=5
//   result=5

package Jvm.SelfTestB121

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Divider class with safeDivide (with contract) ───────────────────────

func makeDividerBytes(pool: in Pool): List[Byte] {
  // requires: b != 0 — push b directly; lowerFuncWithContract uses LIfne to check
  val reqInsns: List[LInsn] = newList()
  reqInsns.add(LIload(slot = 1))

  // No ensures check
  val ensInsns: List[LInsn] = newList()

  // body: a / b
  val bodyInsns: List[LInsn] = newList()
  bodyInsns.add(LIload(slot = 0))
  bodyInsns.add(LIload(slot = 1))
  bodyInsns.add(LIdiv)

  val params: List[JvmType] = newList()
  params.add(JInt)
  params.add(JInt)

  val f = LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "safeDivide",
    params    = params,
    ret       = JInt,
    insns     = bodyInsns,
    maxStack  = 4,
    maxLocals = 2
  )

  val contract = LContract(
    requiresInsns = reqInsns,
    ensuresInsns  = ensInsns
  )

  val method = lowerFuncWithContract(f, contract, pool)
  val methods: List[MethodInfo] = newList()
  methods.add(method)
  val cf = makeClassWithMethods("Divider", methods)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx   = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx   = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx  = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")
  val divideRef   = poolMethodref(pool, "Divider", "safeDivide", "(II)I")

  // result1 = safeDivide(10, 2)  →  5
  emitPushInt(asm, 10)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, divideRef)
  emitIstore(asm, 1)

  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "result=")
  emitIload(asm, 1)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // result2 = safeDivide(15, 3)  →  5
  emitPushInt(asm, 15)
  emitPushInt(asm, 3)
  emitInvokestatic(asm, divideRef)
  emitIstore(asm, 1)

  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "result=")
  emitIload(asm, 1)
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
  val outDir = "/tmp/lyric-jvm-b121"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Divider", bytes = makeDividerBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main",    bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB121",
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
