// jvm/self_test_b120.l — Stage B120: lowerScopeBlock (StructuredTaskScope).
//
// Creates two Callable classes `TaskA` and `TaskB`, each writes to a static
// String field. A Main method uses lowerScopeBlock to fork them, join, and then
// reads both results.
//
// Java output (java -jar):
//   a=hello
//   b=world

package Jvm.SelfTestB120

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build ResultHolder class with static String fields ────────────────────────

func makeHolderBytes(pool: in Pool): List[Byte] {
  val fa: List[Attribute] = newList()
  val fb: List[Attribute] = newList()
  val fields: List[FieldInfo] = newList()
  fields.add(makeFieldInfo(ACC_PUBLIC + ACC_STATIC, "a", "Ljava/lang/String;", fa))
  fields.add(makeFieldInfo(ACC_PUBLIC + ACC_STATIC, "b", "Ljava/lang/String;", fb))

  // <clinit>: a = "", b = ""
  val clinitAsm = newAssembler(pool)
  emitPushString(clinitAsm, "")
  emitPutstatic(clinitAsm, poolFieldref(pool, "Holder", "a", "Ljava/lang/String;"))
  emitPushString(clinitAsm, "")
  emitPutstatic(clinitAsm, poolFieldref(pool, "Holder", "b", "Ljava/lang/String;"))
  emitReturn(clinitAsm)
  val clinitCode = assembleCode(clinitAsm, 1, 0)
  val clinitAttrs: List[Attribute] = newList()
  clinitAttrs.add(clinitCode)
  val clinitPs: List[JvmType] = newList()
  val methods: List[MethodInfo] = newList()
  methods.add(makeMethodInfo(ACC_STATIC, "<clinit>", buildDescriptor(clinitPs, JVoid), clinitAttrs))

  val cf = makeFinalClass("Holder", fields, methods)
  serializeClassWithPool(cf, pool)
}

// ── Build TaskA: Callable that sets Holder.a = "hello" ───────────────────────

func makeTaskABytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)
  val aRef = poolFieldref(pool, "Holder", "a", "Ljava/lang/String;")
  emitPushString(asm, "hello")
  emitPutstatic(asm, aRef)
  // Callable.call() returns Object; return null (placeholder)
  emitAconstNull(asm)
  emitAreturn(asm)

  val callCode = assembleCode(asm, 1, 1)
  val callAttrs: List[Attribute] = newList()
  callAttrs.add(callCode)
  val callPs: List[JvmType] = newList()
  val callMethod = makeMethodInfo(ACC_PUBLIC, "call", buildDescriptor(callPs, JRef(className = "java/lang/Object")), callAttrs)

  // <init>
  val ctorAsm = newAssembler(pool)
  emitAload(ctorAsm, 0)
  val initPs: List[JvmType] = newList()
  emitInvokespecial(ctorAsm, poolMethodref(pool, "java/lang/Object", "<init>", "()V"))
  emitReturn(ctorAsm)
  val ctorCode = assembleCode(ctorAsm, 1, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorPs: List[JvmType] = newList()
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorPs, JVoid), ctorAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(ctorMethod)
  methods.add(callMethod)
  val ifaces: List[String] = newList()
  ifaces.add("java/util/concurrent/Callable")
  val cf = makeClassWithInterfaces("TaskA", ifaces, methods)
  serializeClassWithPool(cf, pool)
}

// ── Build TaskB: Callable that sets Holder.b = "world" ───────────────────────

func makeTaskBBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)
  val bRef = poolFieldref(pool, "Holder", "b", "Ljava/lang/String;")
  emitPushString(asm, "world")
  emitPutstatic(asm, bRef)
  emitAconstNull(asm)
  emitAreturn(asm)

  val callCode = assembleCode(asm, 1, 1)
  val callAttrs: List[Attribute] = newList()
  callAttrs.add(callCode)
  val callPs: List[JvmType] = newList()
  val callMethod = makeMethodInfo(ACC_PUBLIC, "call", buildDescriptor(callPs, JRef(className = "java/lang/Object")), callAttrs)

  val ctorAsm = newAssembler(pool)
  emitAload(ctorAsm, 0)
  emitInvokespecial(ctorAsm, poolMethodref(pool, "java/lang/Object", "<init>", "()V"))
  emitReturn(ctorAsm)
  val ctorCode = assembleCode(ctorAsm, 1, 1)
  val ctorAttrs: List[Attribute] = newList()
  ctorAttrs.add(ctorCode)
  val ctorPs: List[JvmType] = newList()
  val ctorMethod = makeMethodInfo(ACC_PUBLIC, "<init>", buildDescriptor(ctorPs, JVoid), ctorAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(ctorMethod)
  methods.add(callMethod)
  val ifaces: List[String] = newList()
  ifaces.add("java/util/concurrent/Callable")
  val cf = makeClassWithInterfaces("TaskB", ifaces, methods)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class using lowerScopeBlock ────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val aRef       = poolFieldref(pool,  "Holder", "a", "Ljava/lang/String;")
  val bRef       = poolFieldref(pool,  "Holder", "b", "Ljava/lang/String;")

  // Use lowerScopeBlock: scopeSlot=1, tasks at slots 2 and 3
  val callableNames: List[String] = newList()
  callableNames.add("TaskA")
  callableNames.add("TaskB")
  lowerScopeBlock(asm, callableNames, 1, 2)

  // println("a=" + Holder.a)
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "a=")
  emitGetstatic(asm, aRef)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("b=" + Holder.b)
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "b=")
  emitGetstatic(asm, bRef)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 6, 4)
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
  val outDir = "/tmp/lyric-jvm-b120"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Holder", bytes = makeHolderBytes(pool)))
  classes.add(BuiltClass(binaryName = "TaskA",  bytes = makeTaskABytes(pool)))
  classes.add(BuiltClass(binaryName = "TaskB",  bytes = makeTaskBBytes(pool)))
  classes.add(BuiltClass(binaryName = "Main",   bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB120",
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
