// jvm/self_test_b124.l — Stage B124: lowerPackage (top-level integration entry point).
//
// Builds a package with three items:
//   1. LPRecord: Pair(a: JInt, b: JInt)
//   2. LPDistinctType: Weight wrapping JInt
//   3. LPFuncs: "Utils" with add(x: int, y: int): int = x + y
//
// A Main class exercises all three items:
//   - Pair(5, 7): prints "sum=12" (sum of fields via $a() and $b() accessors)
//   - Weight(100): prints "weight=100" (via $value() accessor)
//   - Utils.add(3, 4): prints "add=7"
//
// Java output (java -jar):
//   sum=12
//   weight=100
//   add=7

package Jvm.SelfTestB124

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build package items ───────────────────────────────────────────────────────

func makePackageClasses(pool: in Pool): List[BuiltClass] {
  // LPRecord: Pair with two int fields
  val pairFields: List[LField] = newList()
  pairFields.add(LField(flags = ACC_PRIVATE, name = "a", fieldType = JInt))
  pairFields.add(LField(flags = ACC_PRIVATE, name = "b", fieldType = JInt))
  val pairRec = LRecord(className = "Pair", fields = pairFields, methods = newList(), implementsIfaces = newList())

  // LPDistinctType: Weight wrapping JInt
  val weightDt = LDistinctType(wrapperClass = "Weight", underlyingType = JInt)

  // LPFuncs: Utils with add(x, y) = x + y
  val addParams: List[JvmType] = newList()
  addParams.add(JInt)
  addParams.add(JInt)
  val addInsns: List[LInsn] = newList()
  addInsns.add(LIload(slot = 0))
  addInsns.add(LIload(slot = 1))
  addInsns.add(LIadd)
  addInsns.add(LIreturn)
  val addFunc = LFunc(
    flags     = ACC_PUBLIC + ACC_STATIC,
    name      = "add",
    params    = addParams,
    ret       = JInt,
    insns     = addInsns,
    maxStack  = 2,
    maxLocals = 2
  )
  val addFuncList: List[LFunc] = newList()
  addFuncList.add(addFunc)

  val items: List[LPackageItem] = newList()
  items.add(LPRecord(rec = pairRec))
  items.add(LPDistinctType(dt = weightDt))
  items.add(LPFuncs(funcsClass = "Utils", fns = addFuncList))

  val pkg = LPackage(packageName = "test", items = items)
  val cfs = lowerPackage(pkg, pool)

  val result: List[BuiltClass] = newList()
  for cf in cfs.toArray() {
    result.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
  }
  result
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val vofIIdx    = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")

  val pairClass = poolClass(pool, "Pair")
  val pairCtor  = poolMethodref(pool, "Pair",  "<init>", "(II)V")
  val pairA     = poolFieldref(pool,  "Pair",  "a",      "I")
  val pairB     = poolFieldref(pool,  "Pair",  "b",      "I")

  val wtClass   = poolClass(pool, "Weight")
  val wtCtor    = poolMethodref(pool, "Weight", "<init>",  "(I)V")
  val wtValue   = poolMethodref(pool, "Weight", "$value",  "()I")

  val utilAdd   = poolMethodref(pool, "Utils",  "add",     "(II)I")

  // Pair pair = new Pair(5, 7)
  emitNew(asm, pairClass)
  emitDup(asm)
  emitPushInt(asm, 5)
  emitPushInt(asm, 7)
  emitInvokespecial(asm, pairCtor)
  emitAstore(asm, 1)

  // println("sum=" + (pair.a + pair.b))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "sum=")
  emitAload(asm, 1)
  emitGetfield(asm, pairA)
  emitAload(asm, 1)
  emitGetfield(asm, pairB)
  emitIadd(asm)
  emitInvokestatic(asm, vofIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // Weight w = new Weight(100)
  emitNew(asm, wtClass)
  emitDup(asm)
  emitPushInt(asm, 100)
  emitInvokespecial(asm, wtCtor)
  emitAstore(asm, 2)

  // println("weight=" + w.$value())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "weight=")
  emitAload(asm, 2)
  emitInvokevirtual(asm, wtValue)
  emitInvokestatic(asm, vofIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("add=" + Utils.add(3, 4))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "add=")
  emitIconst(asm, 3)
  emitIconst(asm, 4)
  emitInvokestatic(asm, utilAdd)
  emitInvokestatic(asm, vofIIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 3)
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
  val outDir = "/tmp/lyric-jvm-b124"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  for bc in makePackageClasses(pool).toArray() {
    classes.add(bc)
  }
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB124",
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
