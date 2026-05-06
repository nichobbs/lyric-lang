// jvm/self_test_b34.l — Stage B34: iinc (increment local variable in-place).
//
// Generates IncrOps.class with:
//   addFive(I)I  — uses iinc to add 1 to slot 0 five times, then iload+ireturn
//   addTen(I)I   — uses iinc with delta=10 to add 10 at once
//
// Main prints:
//   addFive(10)  = 15
//   addTen(100)  = 110
//
// Exercises: emitIinc with delta=1 and delta=10 (no branches needed).

package Jvm.SelfTestB34

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeIncrOpsClassBytes(): List[Byte] {
  val pool = poolNew()

  // ── addFive(I)I ───────────────────────────────────────────────────────────
  val asmFive = newAssembler(pool)
  emitIinc(asmFive, 0, 1)
  emitIinc(asmFive, 0, 1)
  emitIinc(asmFive, 0, 1)
  emitIinc(asmFive, 0, 1)
  emitIinc(asmFive, 0, 1)
  emitIload(asmFive, 0)
  emitIreturn(asmFive)
  val fiveCode = assembleCode(asmFive, 1, 1)
  val fiveAttrs: List[Attribute] = newList()
  fiveAttrs.add(fiveCode)
  val addFiveMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "addFive", "(I)I", fiveAttrs)

  // ── addTen(I)I ────────────────────────────────────────────────────────────
  val asmTen = newAssembler(pool)
  emitIinc(asmTen, 0, 10)
  emitIload(asmTen, 0)
  emitIreturn(asmTen)
  val tenCode = assembleCode(asmTen, 1, 1)
  val tenAttrs: List[Attribute] = newList()
  tenAttrs.add(tenCode)
  val addTenMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "addTen", "(I)I", tenAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(addFiveMethod)
  methods.add(addTenMethod)
  val cf = makeClassWithMethods("IncrOps", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut       = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val addFiveRef   = poolMethodref(pool, "IncrOps", "addFive", "(I)I")
  val addTenRef    = poolMethodref(pool, "IncrOps", "addTen",  "(I)I")
  val printlnI     = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // addFive(10) = 15
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, addFiveRef)
  emitInvokevirtual(asm, printlnI)

  // addTen(100) = 110
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 100)
  emitInvokestatic(asm, addTenRef)
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
  val outDir = "/tmp/lyric-jvm-b34"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val incrOpsBytes = makeIncrOpsClassBytes()
  val mainBytes    = makeMainClassBytes()

  val incrOpsClass = BuiltClass(binaryName = "IncrOps", bytes = incrOpsBytes)
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(incrOpsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB34",
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
