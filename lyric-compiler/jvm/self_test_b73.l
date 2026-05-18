// jvm/self_test_b73.l — Stage B73: ifnull / ifnonnull / aconst_null.
//
// Generates NullCheck.class with:
//   isNull(Object)I    — returns 1 if ref is null, else 0  (ifnull branch)
//   orDefault(Object,String)String — returns ref if non-null, else "default"
//   makeNull()Object   — returns aconst_null
//
// Main prints:
//   isNull(null)         → 1
//   isNull("hi")         → 0
//   orDefault(null,"x")  → "x"
//   orDefault("y","x")   → "y"
//   isNull(makeNull())   → 1
//
// Exercises: emitIfnull, emitIfnonnull, emitAconstNull, areturn of null.

package Jvm.SelfTestB73

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeNullCheckBytes(): List[Byte] {
  val pool = poolNew()

  // isNull(Object)I  — slot 0 = ref
  val asmIsNull = newAssembler(pool)
  emitAload(asmIsNull, 0)
  emitIfnull(asmIsNull, "IS_NULL")
  emitIconst(asmIsNull, 0)
  emitIreturn(asmIsNull)
  emitLabel(asmIsNull, "IS_NULL")
  emitIconst(asmIsNull, 1)
  emitIreturn(asmIsNull)
  val isNullCode = assembleCode(asmIsNull, 1, 1)
  val isNullAttrs: List[Attribute] = newList()
  isNullAttrs.add(isNullCode)
  val isNullMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "isNull",
    "(Ljava/lang/Object;)I", isNullAttrs)

  // orDefault(Object,String)String  — slot 0=ref, slot 1=def
  val strClass = poolClass(pool, "java/lang/String")
  val asmOr = newAssembler(pool)
  emitAload(asmOr, 0)
  emitIfnonnull(asmOr, "NOT_NULL")
  emitAload(asmOr, 1)
  emitAreturn(asmOr)
  emitLabel(asmOr, "NOT_NULL")
  emitAload(asmOr, 0)
  emitCheckcast(asmOr, strClass)
  emitAreturn(asmOr)
  val orCode = assembleCode(asmOr, 1, 2)
  val orAttrs: List[Attribute] = newList()
  orAttrs.add(orCode)
  val orMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "orDefault",
    "(Ljava/lang/Object;Ljava/lang/String;)Ljava/lang/String;", orAttrs)

  // makeNull()Object
  val asmMakeNull = newAssembler(pool)
  emitAconstNull(asmMakeNull)
  emitAreturn(asmMakeNull)
  val makeNullCode = assembleCode(asmMakeNull, 1, 0)
  val makeNullAttrs: List[Attribute] = newList()
  makeNullAttrs.add(makeNullCode)
  val makeNullMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "makeNull",
    "()Ljava/lang/Object;", makeNullAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(isNullMethod)
  methods.add(orMethod)
  methods.add(makeNullMethod)
  val cf = makeClassWithMethodsV49("NullCheck", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool       = poolNew()
  val asm        = newAssembler(pool)

  val sysOut     = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI   = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val printlnS   = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val isNullRef  = poolMethodref(pool, "NullCheck", "isNull",    "(Ljava/lang/Object;)I")
  val orRef      = poolMethodref(pool, "NullCheck", "orDefault", "(Ljava/lang/Object;Ljava/lang/String;)Ljava/lang/String;")
  val makeRef    = poolMethodref(pool, "NullCheck", "makeNull",  "()Ljava/lang/Object;")

  // println(NullCheck.isNull(null)) → 1
  emitGetstatic(asm, sysOut)
  emitAconstNull(asm)
  emitInvokestatic(asm, isNullRef)
  emitInvokevirtual(asm, printlnI)

  // println(NullCheck.isNull("hi")) → 0
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hi")
  emitInvokestatic(asm, isNullRef)
  emitInvokevirtual(asm, printlnI)

  // println(NullCheck.orDefault(null, "x")) → "x"
  emitGetstatic(asm, sysOut)
  emitAconstNull(asm)
  emitPushString(asm, "x")
  emitInvokestatic(asm, orRef)
  emitInvokevirtual(asm, printlnS)

  // println(NullCheck.orDefault("y", "x")) → "y"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "y")
  emitPushString(asm, "x")
  emitInvokestatic(asm, orRef)
  emitInvokevirtual(asm, printlnS)

  // println(NullCheck.isNull(NullCheck.makeNull())) → 1
  emitGetstatic(asm, sysOut)
  emitInvokestatic(asm, makeRef)
  emitInvokestatic(asm, isNullRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+null(2)+str(3) = 3 peak for orDefault
  val codeAttr = assembleCode(asm, 3, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b73"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val nullCheckBytes = makeNullCheckBytes()
  val mainBytes      = makeMainClassBytes()

  val nullCheckClass = BuiltClass(binaryName = "NullCheck", bytes = nullCheckBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(nullCheckClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB73",
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
