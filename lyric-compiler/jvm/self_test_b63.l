// jvm/self_test_b63.l — Stage B63: static fields (putstatic / getstatic) on user class.
//
// Generates Counter.class with a static int field `count` and two methods:
//   increment()V   — count = count + 1  (getstatic, iconst_1, iadd, putstatic)
//   getCount()I    — return count        (getstatic, ireturn)
//
// Main calls increment() three times then prints getCount() → 3.
//
// Exercises: putstatic on a user-defined class field, static int field declaration,
//            getstatic for read-back, using same pool fieldref for both.

package Jvm.SelfTestB63

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeCounterBytes(): List[Byte] {
  val pool     = poolNew()
  val countRef = poolFieldref(pool, "Counter", "count", "I")

  // increment()V
  val asmInc = newAssembler(pool)
  emitGetstatic(asmInc, countRef)
  emitIconst(asmInc, 1)
  emitIadd(asmInc)
  emitPutstatic(asmInc, countRef)
  emitReturn(asmInc)
  val incCode = assembleCode(asmInc, 2, 0)
  val incAttrs: List[Attribute] = newList()
  incAttrs.add(incCode)
  val incMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "increment", "()V", incAttrs)

  // getCount()I
  val asmGet = newAssembler(pool)
  emitGetstatic(asmGet, countRef)
  emitIreturn(asmGet)
  val getCode = assembleCode(asmGet, 1, 0)
  val getAttrs: List[Attribute] = newList()
  getAttrs.add(getCode)
  val getMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "getCount", "()I", getAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(incMethod)
  methods.add(getMethod)
  val countField = makeFieldInfo(ACC_PUBLIC + ACC_STATIC, "count", "I", newList())
  val fields: List[FieldInfo] = newList()
  fields.add(countField)
  val cf = makeClassFull("Counter", fields, methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val incRef    = poolMethodref(pool, "Counter", "increment", "()V")
  val getRef    = poolMethodref(pool, "Counter", "getCount",  "()I")

  // Counter.increment() x3
  emitInvokestatic(asm, incRef)
  emitInvokestatic(asm, incRef)
  emitInvokestatic(asm, incRef)

  // println(Counter.getCount())  → 3
  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, getRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+invokestatic→int(2) = 2 peak
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
  val outDir = "/tmp/lyric-jvm-b63"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val counterBytes = makeCounterBytes()
  val mainBytes    = makeMainClassBytes()

  val counterClass = BuiltClass(binaryName = "Counter", bytes = counterBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(counterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB63",
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
