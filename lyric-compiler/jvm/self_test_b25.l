//! jvm/self_test_b25.l — Stage B25: static fields (putstatic + getstatic).
//!
//! Generates Counter.class with a static int field `count` and two methods:
//!   increment()V: reads count, adds 1, writes count back (getstatic/putstatic)
//!   getCount()I:  returns current value of count (getstatic/ireturn)
//!
//! Main calls increment() three times then prints getCount() → 3.
//! Exercises: makeFieldInfo, makeClassFull with fields, putstatic, getstatic.
package Jvm.SelfTestB25

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeCounterClassBytes(): List[Byte] {
  val pool = poolNew()

  // Fieldref for Counter.count (used by both methods)
  val countRef = poolFieldref(pool, "Counter", "count", "I")

  // ── increment()V ──────────────────────────────────────────────────────────
  val incAsm = newAssembler(pool)
  // getstatic Counter.count
  emitGetstatic(incAsm, countRef)
  // iconst_1; iadd; putstatic Counter.count; return
  emitPushInt(incAsm, 1)
  emitIadd(incAsm)
  emitPutstatic(incAsm, countRef)
  emitReturn(incAsm)
  val incCode = assembleCode(incAsm, 2, 0)
  val incAttrs: List[Attribute] = newList()
  incAttrs.add(incCode)
  val incrementMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "increment", "()V", incAttrs)

  // ── getCount()I ───────────────────────────────────────────────────────────
  val getAsm = newAssembler(pool)
  emitGetstatic(getAsm, countRef)
  emitIreturn(getAsm)
  val getCode = assembleCode(getAsm, 1, 0)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getCountMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getCount", "()I", getAttrs)

  // ── Field declaration ─────────────────────────────────────────────────────
  val noAttrs: List[Attribute] = newList()
  val countField = makeFieldInfo(ACC_PUBLIC + ACC_STATIC, "count", "I", noAttrs)

  val fields: List[FieldInfo] = newList()
  fields.add(countField)
  val methods: List[MethodInfo] = newList()
  methods.add(incrementMethod)
  methods.add(getCountMethod)
  val cf = makeClassFull("Counter", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val incRef = poolMethodref(pool, "Counter", "increment", "()V")
  val getRef = poolMethodref(pool, "Counter", "getCount", "()I")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // Call increment() three times
  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, incRef)
  emitInvokestatic(asm, incRef)
  emitInvokestatic(asm, incRef)
  // Print getCount()
  emitInvokestatic(asm, getRef)
  emitInvokevirtual(asm, printlnI)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 2, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b25"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val counterBytes = makeCounterClassBytes()
  val mainBytes = makeMainClassBytes()

  val counterClass = BuiltClass(binaryName = "Counter", bytes = counterBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(counterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB25",
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
