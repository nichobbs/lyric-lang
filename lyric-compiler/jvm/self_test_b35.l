//! jvm/self_test_b35.l — Stage B35: tableswitch integer dispatch.
//!
//! Generates Categorize.class with static category(I)Ljava/lang/String; that
//! uses tableswitch over the range [0..3]:
//!   0 → "zero", 1 → "one", 2 → "two", 3 → "three", otherwise → "other"
//!
//! Main calls category(0), category(2), and category(5) and prints the results.
//! Exercises: emitTableSwitch, assembleCodeWithFrames with VInteger local frame.
package Jvm.SelfTestB35

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeCategorizeClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // category(I)Ljava/lang/String;
  //   iload_0
  //   tableswitch low=0 high=3 default=lbl_default
  //     case 0 → lbl_0, case 1 → lbl_1, case 2 → lbl_2, case 3 → lbl_3
  //
  //   lbl_0: ldc "zero";  areturn
  //   lbl_1: ldc "one";   areturn
  //   lbl_2: ldc "two";   areturn
  //   lbl_3: ldc "three"; areturn
  //   lbl_default: ldc "other"; areturn

  val cases: List[String] = newList()
  cases.add("lbl_0")
  cases.add("lbl_1")
  cases.add("lbl_2")
  cases.add("lbl_3")

  emitIload(asm, 0)
  emitTableSwitch(asm, 0, 3, "lbl_default", cases)

  emitLabel(asm, "lbl_0")
  emitPushString(asm, "zero")
  emitAreturn(asm)

  emitLabel(asm, "lbl_1")
  emitPushString(asm, "one")
  emitAreturn(asm)

  emitLabel(asm, "lbl_2")
  emitPushString(asm, "two")
  emitAreturn(asm)

  emitLabel(asm, "lbl_3")
  emitPushString(asm, "three")
  emitAreturn(asm)

  emitLabel(asm, "lbl_default")
  emitPushString(asm, "other")
  emitAreturn(asm)

  // StackMapTable: all 5 targets have [VInteger] locals, empty stack
  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VInteger)
  val codeAttr = assembleCodeWithFrames(asm, 1, 1, frameLocals)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val categoryMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "category", "(I)Ljava/lang/String;", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(categoryMethod)
  val cf = makeClassWithMethods("Categorize", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val categoryRef = poolMethodref(pool, "Categorize", "category", "(I)Ljava/lang/String;")
  val printlnS = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  // category(0) → "zero"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 0)
  emitInvokestatic(asm, categoryRef)
  emitInvokevirtual(asm, printlnS)

  // category(2) → "two"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, categoryRef)
  emitInvokevirtual(asm, printlnS)

  // category(5) → "other"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, categoryRef)
  emitInvokevirtual(asm, printlnS)

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
  val outDir = "/tmp/lyric-jvm-b35"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val categorizeBytes = makeCategorizeClassBytes()
  val mainBytes = makeMainClassBytes()

  val categorizeClass = BuiltClass(binaryName = "Categorize", bytes = categorizeBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(categorizeClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB35",
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
