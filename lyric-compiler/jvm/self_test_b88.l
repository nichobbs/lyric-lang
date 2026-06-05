//! jvm/self_test_b88.l — Stage B88: monitorenter / monitorexit (synchronized block).
//!
//! Generates Monitor.class with:
//!   syncAdd(Object lock, int[] counter, int delta)void
//!     — synchronized(lock) { counter[0] += delta }
//!
//! Main:
//!   int[] cnt = {0}
//!   Object lock = new Object()
//!   syncAdd(lock, cnt, 5)
//!   syncAdd(lock, cnt, 3)
//!   println("count=" + cnt[0])  → "count=8"
//!
//! Exercises: monitorenter, monitorexit, synchronized-block pattern
//!            (monitorenter / try { body } finally { monitorexit }).
package Jvm.SelfTestB88

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMonitorBytes(): List[Byte] {
  val pool = poolNew()

  // syncAdd(Object lock, int[] counter, int delta)void
  // slot 0=lock; slot 1=counter; slot 2=delta
  //
  // Pattern (simplified — no finally for brevity, Java 5 class file):
  //   aload lock
  //   monitorenter
  //   aload counter
  //   iconst_0
  //   aload counter
  //   iconst_0
  //   iaload          // counter[0]
  //   iload delta
  //   iadd
  //   iastore         // counter[0] += delta
  //   aload lock
  //   monitorexit
  //   return
  val asm = newAssembler(pool)
  emitAload(asm, 0)
  emitMonitorenter(asm)
  emitAload(asm, 1)
  emitIconst(asm, 0)
  emitAload(asm, 1)
  emitIconst(asm, 0)
  emitIaload(asm)
  emitIload(asm, 2)
  emitIadd(asm)
  emitIastore(asm)
  emitAload(asm, 0)
  emitMonitorexit(asm)
  emitReturn(asm)
  val code = assembleCode(asm, 4, 3)
  val attrs: List[Attribute] = newList()
  attrs.add(code)
  val method = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "syncAdd", "(Ljava/lang/Object;[II)V", attrs)

  val methods: List[MethodInfo] = newList()
  methods.add(method)
  val cf = makeClassWithMethods("Monitor", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfI = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val objClass = poolClass(pool, "java/lang/Object")
  val objInit = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  val syncRef = poolMethodref(pool, "Monitor", "syncAdd", "(Ljava/lang/Object;[II)V")

  // cnt = new int[1]  (slot 0)
  emitIconst(asm, 1)
  emitNewarray(asm, T_INT)
  emitAstore(asm, 0)

  // lock = new Object()  (slot 1)
  emitNew(asm, objClass)
  emitDup(asm)
  emitInvokespecial(asm, objInit)
  emitAstore(asm, 1)

  // Monitor.syncAdd(lock, cnt, 5)
  emitAload(asm, 1)
  emitAload(asm, 0)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, syncRef)

  // Monitor.syncAdd(lock, cnt, 3)
  emitAload(asm, 1)
  emitAload(asm, 0)
  emitIconst(asm, 3)
  emitInvokestatic(asm, syncRef)

  // println("count=" + cnt[0])
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "count=")
  emitAload(asm, 0)
  emitIconst(asm, 0)
  emitIaload(asm)
  emitInvokestatic(asm, valueOfI)
  emitInvokevirtual(asm, concatRef)
  emitInvokevirtual(asm, printlnS)

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

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b88"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val monitorBytes = makeMonitorBytes()
  val mainBytes = makeMainClassBytes()

  val monitorClass = BuiltClass(binaryName = "Monitor", bytes = monitorBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(monitorClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB88",
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
