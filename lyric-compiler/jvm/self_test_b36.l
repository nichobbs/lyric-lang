// jvm/self_test_b36.l — Stage B36: lookupswitch (sparse integer dispatch).
//
// Generates Classify.class with static classify(I)Ljava/lang/String; that
// uses lookupswitch over sparse keys {1, 10, 100}:
//   1   → "one"
//   10  → "ten"
//   100 → "hundred"
//   otherwise → "other"
//
// Main calls classify(10), classify(1), classify(7) and prints results.
// Exercises: emitLookupSwitch, SwitchPair, assembleCodeWithFrames with VInteger.

package Jvm.SelfTestB36

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeClassifyClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  // classify(I)Ljava/lang/String;
  //   iload_0
  //   lookupswitch 3 pairs (sorted by key):
  //     1   → lbl_one
  //     10  → lbl_ten
  //     100 → lbl_hundred
  //     default → lbl_other

  val pairs: List[SwitchPair] = newList()
  pairs.add(SwitchPair(key = 1,   label = "lbl_one"))
  pairs.add(SwitchPair(key = 10,  label = "lbl_ten"))
  pairs.add(SwitchPair(key = 100, label = "lbl_hundred"))

  emitIload(asm, 0)
  emitLookupSwitch(asm, "lbl_other", pairs)

  emitLabel(asm, "lbl_one")
  emitPushString(asm, "one")
  emitAreturn(asm)

  emitLabel(asm, "lbl_ten")
  emitPushString(asm, "ten")
  emitAreturn(asm)

  emitLabel(asm, "lbl_hundred")
  emitPushString(asm, "hundred")
  emitAreturn(asm)

  emitLabel(asm, "lbl_other")
  emitPushString(asm, "other")
  emitAreturn(asm)

  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VInteger)
  val codeAttr = assembleCodeWithFrames(asm, 1, 1, frameLocals)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val classifyMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "classify",
    "(I)Ljava/lang/String;",
    attrs
  )
  val methods: List[MethodInfo] = newList()
  methods.add(classifyMethod)
  val cf = makeClassWithMethods("Classify", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut       = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val classifyRef  = poolMethodref(pool, "Classify", "classify", "(I)Ljava/lang/String;")
  val printlnS     = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  // classify(10) → "ten"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, classifyRef)
  emitInvokevirtual(asm, printlnS)

  // classify(1) → "one"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 1)
  emitInvokestatic(asm, classifyRef)
  emitInvokevirtual(asm, printlnS)

  // classify(7) → "other"
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 7)
  emitInvokestatic(asm, classifyRef)
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
  val outDir = "/tmp/lyric-jvm-b36"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val classifyBytes = makeClassifyClassBytes()
  val mainBytes     = makeMainClassBytes()

  val classifyClass = BuiltClass(binaryName = "Classify", bytes = classifyBytes)
  val mainClass     = BuiltClass(binaryName = "Main",     bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(classifyClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB36",
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
