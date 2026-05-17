// jvm/self_test_b16.l — Stage B16: instance fields with putfield + getfield.
//
// Generates two class files:
//   Counter.class — field `int count`, constructor sets it, getValue() reads it
//   Main.class    — creates Counter(42), calls getValue(), prints result
//
// Exercises: FieldInfo declaration, putfield, getfield, bipush, integer returns.
// Assembled into /tmp/lyric-jvm-b16/hello.jar; verified by JvmLoweringB16Test.

package Jvm.SelfTestB16

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeCounterClassBytes(): List[Byte] {
  val pool = poolNew()

  // Declare the `count` field.
  val noAttrs: List[Attribute] = newList()
  val countField = makeFieldInfo(ACC_PUBLIC, "count", "I", noAttrs)

  // <init>(I)V: aload_0, invokespecial Object.<init>, aload_0, iload_1, putfield count, return
  val asmInit = newAssembler(pool)
  val objInit    = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  val countFieldref = poolFieldref(pool, "Counter", "count", "I")
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitAload(asmInit, 0)
  emitIload(asmInit, 1)
  emitPutfield(asmInit, countFieldref)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 2, 2)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "(I)V", initAttrs)

  // getValue()I: aload_0, getfield count, ireturn
  val asmGet = newAssembler(pool)
  emitAload(asmGet, 0)
  emitGetfield(asmGet, countFieldref)
  emitIreturn(asmGet)
  val getCode = assembleCode(asmGet, 1, 1)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC, "getValue", "()I", getAttrs)

  val fields: List[FieldInfo] = newList()
  fields.add(countField)
  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(getMethod)
  val cf = makeClassFull("Counter", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut      = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val counterCls  = poolClass(pool, "Counter")
  val counterInit = poolMethodref(pool, "Counter", "<init>", "(I)V")
  val getValue_   = poolMethodref(pool, "Counter", "getValue", "()I")
  val printlnI    = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  emitGetstatic(asm, sysOut)
  emitNew(asm, counterCls)
  emitDup(asm)
  emitPushInt(asm, 42)
  emitInvokespecial(asm, counterInit)
  emitInvokevirtual(asm, getValue_)
  emitInvokevirtual(asm, printlnI)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 4, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b16"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val counterBytes = makeCounterClassBytes()
  val mainBytes    = makeMainClassBytes()

  val counterClass = BuiltClass(binaryName = "Counter", bytes = counterBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(counterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB16",
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
