// jvm/self_test_b43.l — Stage B43: Math.max and Math.min (static JDK utility).
//
// Generates MathUtils.class with:
//   clamp(I,I,I)I — clamps a value to [lo, hi]: Math.max(lo, Math.min(value, hi))
//
// Main:
//   clamp(5,  1, 10)  → 5   (within range)
//   clamp(0,  1, 10)  → 1   (below lo)
//   clamp(15, 1, 10)  → 10  (above hi)
//
// Expected output:
//   5
//   1
//   10
//
// Exercises: invokestatic Math.max(II)I and Math.min(II)I.

package Jvm.SelfTestB43

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeMathUtilsClassBytes(): List[Byte] {
  val pool = poolNew()

  val mathMaxRef = poolMethodref(pool, "java/lang/Math", "max", "(II)I")
  val mathMinRef = poolMethodref(pool, "java/lang/Math", "min", "(II)I")

  // ── clamp(I value, I lo, I hi)I ──────────────────────────────────────────────
  // slot 0 = value, slot 1 = lo, slot 2 = hi
  // Math.max(lo, Math.min(value, hi))
  // = iload_1; iload_0; iload_2; invokestatic Math.min; invokestatic Math.max; ireturn
  val asmC = newAssembler(pool)
  emitIload(asmC, 1)              // push lo
  emitIload(asmC, 0)              // push value
  emitIload(asmC, 2)              // push hi
  emitInvokestatic(asmC, mathMinRef)  // Math.min(value, hi) → capped
  emitInvokestatic(asmC, mathMaxRef)  // Math.max(lo, capped) → clamped
  emitIreturn(asmC)

  val cCode = assembleCode(asmC, 3, 3)
  val cAttrs: List[Attribute] = newList()
  cAttrs.add(cCode)
  val clampMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "clamp",
    "(III)I",
    cAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(clampMethod)
  val cf = makeClassWithMethods("MathUtils", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val clampRef  = poolMethodref(pool, "MathUtils", "clamp", "(III)I")
  val printlnI  = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")

  // clamp(5, 1, 10) → 5
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 5)
  emitPushInt(asm, 1)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, clampRef)
  emitInvokevirtual(asm, printlnI)

  // clamp(0, 1, 10) → 1
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 0)
  emitPushInt(asm, 1)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, clampRef)
  emitInvokevirtual(asm, printlnI)

  // clamp(15, 1, 10) → 10
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 15)
  emitPushInt(asm, 1)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, clampRef)
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
  val outDir = "/tmp/lyric-jvm-b43"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val mathUtilsBytes = makeMathUtilsClassBytes()
  val mainBytes      = makeMainClassBytes()

  val mathUtilsClass = BuiltClass(binaryName = "MathUtils", bytes = mathUtilsBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(mathUtilsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB43",
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
