//! jvm/self_test_b129.l — Stage B129: lowerAsyncGenerator (eager Iterable+Iterator).
//!
//! Validates the bytecode shape that lowerAsyncGenerator emits for a generator
//! function `doubles(a: int, b: int): int` that yields `a * 2` and `b * 2`:
//!
//!   1. Creates a generator class `Doubles$Gen` implementing Iterable+Iterator
//!      with an eager RunBody that populates an ArrayList.
//!   2. Creates a host class `Doubles` with a static kickoff method `doubles(II)`.
//!   3. Main calls `Doubles.doubles(10, 21)`, iterates via hasNext()/next(),
//!      and prints each element.
//!
//! Java output (java -jar):
//!   20
//!   42
package Jvm.SelfTestB129

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Doubles$Gen + Doubles classes via lowerAsyncGenerator ───────────────
func makeDoublesClasses(pool: in Pool): List[BuiltClass] {
  val genClass = "Doubles$Gen"
  val hostClass = "Doubles"

  // Body: load this.a, * 2, yield; load this.b, * 2, yield
  val bodyInsns: List[LInsn] = newList()

  // yield a * 2
  bodyInsns.add(LAload(slot = 0))
  bodyInsns.add(LGetfield(owner = genClass, name = "a", t = JInt))
  bodyInsns.add(LIconst(v = 2))
  bodyInsns.add(LImul)
  bodyInsns.add(LYield)

  // yield b * 2
  bodyInsns.add(LAload(slot = 0))
  bodyInsns.add(LGetfield(owner = genClass, name = "b", t = JInt))
  bodyInsns.add(LIconst(v = 2))
  bodyInsns.add(LImul)
  bodyInsns.add(LYield)

  val paramA = LGenParam(paramName = "a", paramType = JInt)
  val paramB = LGenParam(paramName = "b", paramType = JInt)
  val params: List[LGenParam] = newList()
  params.add(paramA)
  params.add(paramB)

  val g = LGenFunc(
    generatorClass = genClass,
    hostClass = hostClass,
    methodName = "doubles",
    elemType = JInt,
    params = params,
    bodyInsns = bodyInsns
  )
  val cfs = lowerAsyncGenerator(g, pool)

  val result: List[BuiltClass] = newList()
  var i = 0
  while i < cfs.count {
    val cf = cfs[i]
    result.add(BuiltClass(binaryName = cf.thisClass, bytes = serializeClassWithPool(cf, pool)))
    i = i + 1
  }
  result
}

// ── Build Main class ──────────────────────────────────────────────────────────
//
// Calls Doubles.doubles(10, 21), iterates via hasNext()/next(),
// and prints Integer.intValue() for each element.
func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  val doublesIdx = poolMethodref(pool, "Doubles", "doubles", "(II)Ljava/lang/Object;")

  val iterableClass = "java/lang/Iterable"
  val iteratorClass = "java/util/Iterator"
  val iteratorIdx = poolIfaceMethodref(pool, iterableClass, "iterator", "()Ljava/util/Iterator;")
  val hasNextIdx = poolIfaceMethodref(pool, iteratorClass, "hasNext", "()Z")
  val nextIdx = poolIfaceMethodref(pool, iteratorClass, "next", "()Ljava/lang/Object;")
  val integerClass = poolClass(pool, "java/lang/Integer")
  val intValueIdx = poolMethodref(pool, "java/lang/Integer", "intValue", "()I")
  val iterableIdx = poolClass(pool, iterableClass)
  val iteratorClsIdx = poolClass(pool, iteratorClass)

  // slot 0 = String[] args
  // slot 1 = gen Object (Iterable)
  // slot 2 = iter Object (Iterator)
  // slot 3 = element int

  // gen = Doubles.doubles(10, 21)
  emitPushInt(asm, 10)
  emitPushInt(asm, 21)
  emitInvokestatic(asm, doublesIdx)
  emitAstore(asm, 1)

  // iter = ((Iterable) gen).iterator()
  emitAload(asm, 1)
  emitCheckcast(asm, iterableIdx)
  emitInvokeinterface(asm, iteratorIdx, 1)
  emitAstore(asm, 2)

  // while (iter.hasNext()) { print(((Integer)iter.next()).intValue()); }
  emitLabel(asm, "loop_start")
  emitAload(asm, 2)
  emitInvokeinterface(asm, hasNextIdx, 1)
  emitIfeq(asm, "loop_end")

  emitAload(asm, 2)
  emitInvokeinterface(asm, nextIdx, 1)
  emitCheckcast(asm, integerClass)
  emitInvokevirtual(asm, intValueIdx)
  emitIstore(asm, 3)

  emitGetstatic(asm, sysOutIdx)
  emitIload(asm, 3)
  emitInvokevirtual(asm, printlnIdx)

  emitGoto(asm, "loop_start")
  emitLabel(asm, "loop_end")

  emitReturn(asm)

  // maxStack=3 (invokeinterface 2 args = iter+arg); maxLocals=4
  val codeAttr = assembleCode(asm, 3, 4)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  // V49 to avoid StackMapTable for the loop branch
  val cf = makeClassWithMethodsV49("Main", methods)
  serializeClassWithPool(cf, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────
func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b129"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()

  for dc in makeDoublesClasses(pool).toArray() {
    classes.add(dc)
  }
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB129",
    mainClass = "Main",
    version = "0.1.0",
    outPath = outDir + "/gen.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
