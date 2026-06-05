//! jvm/self_test_b107.l — Stage B107: lowerSpawnVirtualThread + lowerThreadJoin.
//!
//! Demonstrates the default async lowering strategy (§14.1):
//!   `async func` body runs synchronously; callsite spawns a virtual thread.
//!
//! Creates:
//!   Squarer — a Runnable closure (via lowerClosure) that captures (n: int, arr: int[])
//!             and in run() sets arr[0] = n * n.
//!   Main    — allocates int[1], creates Squarer(5, arr), spawns a virtual thread,
//!             joins it, then prints the result.
//!
//! Java output (java -jar):
//!   sq(5)=25
//!   sq(7)=49
package Jvm.SelfTestB107

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build Squarer closure class ───────────────────────────────────────────────
func makeSquarerBytes(): List[Byte] {
  val pool = poolNew()

  val captures: List[LClosureCapture] = newList()
  captures.add(LClosureCapture(captureName = "n", captureType = JInt))
  captures.add(LClosureCapture(captureName = "arr", captureType = JArray(JInt)))

  // run() body: arr[0] = n * n
  val body: List[LInsn] = newList()
  body.add(LAload(slot = 0))
  body.add(LGetfield(owner = "Squarer", name = "arr", t = JArray(JInt)))
  body.add(LIconst(v = 0))
  body.add(LAload(slot = 0))
  body.add(LGetfield(owner = "Squarer", name = "n", t = JInt))
  body.add(LAload(slot = 0))
  body.add(LGetfield(owner = "Squarer", name = "n", t = JInt))
  body.add(LImul)
  body.add(LIastore)
  body.add(LReturn)

  val noParams: List[JvmType] = newList()
  val c = LClosure(
    closureClass = "Squarer",
    ifaceClass = "java/lang/Runnable",
    ifaceMethod = "run",
    captures = captures,
    methodParams = noParams,
    methodRet = JVoid,
    bodyInsns = body
  )
  val cf = lowerClosure(c, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────
func squarerCallSeq(
  asm: in MethodAssembler,
  squarerNewIdx: in Int,
  squarerCtorIdx: in Int,
  arrSlot: in Int,
  n: in Int,
  resSlot: in Int,
  sysOutIdx: in Int,
  printlnIdx: in Int,
  concatIdx: in Int,
  valueOfIdx: in Int,
  label: in String,
): Unit {
  // int[] arr = new int[1]
  emitPushInt(asm, 1)
  emitNewarray(asm, 10)
  emitAstore(asm, arrSlot)

  // Squarer sq = new Squarer(n, arr)
  emitNew(asm, squarerNewIdx)
  emitDup(asm)
  emitPushInt(asm, n)
  emitAload(asm, arrSlot)
  emitInvokespecial(asm, squarerCtorIdx)
  emitAstore(asm, resSlot)

  // Thread t = Thread.startVirtualThread(sq)
  emitAload(asm, resSlot)
  lowerSpawnVirtualThread(asm)
  emitAstore(asm, resSlot + 1)

  // t.join()
  emitAload(asm, resSlot + 1)
  lowerThreadJoin(asm)

  // println(label + arr[0])
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, label)
  emitAload(asm, arrSlot)
  emitPushInt(asm, 0)
  emitIaload(asm)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")

  val ctorPs: List[JvmType] = newList()
  ctorPs.add(JInt)
  ctorPs.add(JArray(JInt))
  val squarerCtorIdx = poolMethodref(pool, "Squarer", "<init>", buildDescriptor(ctorPs, JVoid))
  val squarerNewIdx = poolClass(pool, "Squarer")

  // sq(5) → 25  (arr slot=1, sq slot=2, thread slot=3)
  squarerCallSeq(asm, squarerNewIdx, squarerCtorIdx, 1, 5, 2, sysOutIdx, printlnIdx, concatIdx, valueOfIdx, "sq(5)=")

  // sq(7) → 49  (arr slot=4, sq slot=5, thread slot=6)
  squarerCallSeq(asm, squarerNewIdx, squarerCtorIdx, 4, 7, 5, sysOutIdx, printlnIdx, concatIdx, valueOfIdx, "sq(7)=")

  emitReturn(asm)

  // maxStack=4 (new+dup+int+aload for ctor), maxLocals=7 (0=args,1-3 for first call,4-6 for second)
  val codeAttr = assembleCode(asm, 4, 7)
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
  val outDir = "/tmp/lyric-jvm-b107"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Squarer", bytes = makeSquarerBytes()))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB107",
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
