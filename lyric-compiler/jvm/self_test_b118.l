// jvm/self_test_b118.l — Stage B118: lowerProtectedWithBarriers (when: Condition-variable barriers).
//
// Creates a `Box` protected type with:
//   - int value field (zero-initialised)
//   - put(v: int): void  — barrier predicate always-true; body stores v into value
//   - take(): int        — barrier predicate always-true; body loads value
//
// Using always-true predicates means barriers never block, allowing single-threaded testing.
//
// Java output (java -jar):
//   result=42

package Jvm.SelfTestB118

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Box protected type with barriers ────────────────────────────────────

func makeBoxBytes(pool: in Pool): List[Byte] {
  val valueField: List[LField] = newList()
  valueField.add(LField(flags = ACC_PRIVATE, name = "value", fieldType = JInt))

  // put(v: JInt): void — predicate: always 1; body: this.value = v
  val putParams: List[JvmType] = newList()
  putParams.add(JInt)
  val putBodyInsns: List[LInsn] = newList()
  putBodyInsns.add(LAload(slot = 0))
  putBodyInsns.add(LIload(slot = 1))
  putBodyInsns.add(LPutfield(owner = "Box", name = "value", t = JInt))

  val putPredInsns: List[LInsn] = newList()
  putPredInsns.add(LIconst(v = 1))   // always-true predicate

  val putFunc = LFunc(
    flags     = ACC_PUBLIC,
    name      = "put",
    params    = putParams,
    ret       = JVoid,
    insns     = putBodyInsns,
    maxStack  = 3,
    maxLocals = 2
  )

  // take(): JInt — predicate: always 1; body: push this.value
  val takeParams: List[JvmType] = newList()
  val takeBodyInsns: List[LInsn] = newList()
  takeBodyInsns.add(LAload(slot = 0))
  takeBodyInsns.add(LGetfield(owner = "Box", name = "value", t = JInt))

  val takePredInsns: List[LInsn] = newList()
  takePredInsns.add(LIconst(v = 1))   // always-true predicate

  val takeFunc = LFunc(
    flags     = ACC_PUBLIC,
    name      = "take",
    params    = takeParams,
    ret       = JInt,
    insns     = takeBodyInsns,
    maxStack  = 2,
    maxLocals = 1
  )

  val barriers: List[LBarrierEntry] = newList()
  barriers.add(LBarrierEntry(
    entryFunc      = putFunc,
    conditionName  = "_cond_put",
    predicateInsns = putPredInsns
  ))
  barriers.add(LBarrierEntry(
    entryFunc      = takeFunc,
    conditionName  = "_cond_take",
    predicateInsns = takePredInsns
  ))

  val p = LProtectedWithBarriers(
    className = "Box",
    fields    = valueField,
    barriers  = barriers
  )
  val cf = lowerProtectedWithBarriers(p, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")

  val boxClass  = poolClass(pool, "Box")
  val boxCtor   = poolMethodref(pool, "Box", "<init>", "()V")
  val boxPut    = poolMethodref(pool, "Box", "put",    "(I)V")
  val boxTake   = poolMethodref(pool, "Box", "take",   "()I")

  // Box box = new Box()
  emitNew(asm, boxClass)
  emitDup(asm)
  emitInvokespecial(asm, boxCtor)
  emitAstore(asm, 1)

  // box.put(42)
  emitAload(asm, 1)
  emitPushInt(asm, 42)
  emitInvokevirtual(asm, boxPut)

  // int v = box.take()
  emitAload(asm, 1)
  emitInvokevirtual(asm, boxTake)
  emitIstore(asm, 2)

  // println("result=" + v)
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "result=")
  emitIload(asm, 2)
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
  val outDir = "/tmp/lyric-jvm-b118"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Box",  bytes = makeBoxBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB118",
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
