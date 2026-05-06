// jvm/self_test_b37.l — Stage B37: aconst_null, ifnull, ifnonnull.
//
// Generates NullCheck.class with:
//   isNull(Ljava/lang/Object;)Z  — returns 1 if arg is null, 0 otherwise
//   orDefault(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;
//       — returns first arg if non-null, second arg otherwise
//
// Main:
//   isNull(null)         → 1
//   isNull("hello")      → 0
//   orDefault(null,"default") → "default"
//   orDefault("hi","x")  → "hi"
//
// Exercises: emitAconstNull, emitIfnull, emitIfnonnull (branches with V49 to skip StackMapTable).

package Jvm.SelfTestB37

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeNullCheckClassBytes(): List[Byte] {
  val pool = poolNew()

  // ── isNull(Ljava/lang/Object;)Z ───────────────────────────────────────────
  // aload_0; ifnonnull lbl_notnull; iconst_1; ireturn; lbl_notnull: iconst_0; ireturn
  val asmIN = newAssembler(pool)
  emitAload(asmIN, 0)
  emitIfnonnull(asmIN, "lbl_notnull")
  emitPushInt(asmIN, 1)
  emitIreturn(asmIN)
  emitLabel(asmIN, "lbl_notnull")
  emitPushInt(asmIN, 0)
  emitIreturn(asmIN)
  val inCode = assembleCode(asmIN, 1, 1)
  val inAttrs: List[Attribute] = newList()
  inAttrs.add(inCode)
  val isNullMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "isNull",
    "(Ljava/lang/Object;)Z",
    inAttrs
  )

  // ── orDefault(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String; ─────
  // aload_0; ifnull lbl_isnull; aload_0; areturn; lbl_isnull: aload_1; areturn
  val asmOD = newAssembler(pool)
  emitAload(asmOD, 0)
  emitIfnull(asmOD, "lbl_isnull")
  emitAload(asmOD, 0)
  emitAreturn(asmOD)
  emitLabel(asmOD, "lbl_isnull")
  emitAload(asmOD, 1)
  emitAreturn(asmOD)
  val odCode = assembleCode(asmOD, 1, 2)
  val odAttrs: List[Attribute] = newList()
  odAttrs.add(odCode)
  val orDefaultMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "orDefault",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;",
    odAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(isNullMethod)
  methods.add(orDefaultMethod)
  // Use Java 5 (major=49) to avoid StackMapTable for branching methods
  val cf = makeClassWithMethodsV49("NullCheck", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOut        = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val isNullRef     = poolMethodref(pool, "NullCheck", "isNull",    "(Ljava/lang/Object;)Z")
  val orDefaultRef  = poolMethodref(pool, "NullCheck", "orDefault", "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")
  val printlnI      = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val printlnS      = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")

  // isNull(null) → 1
  emitGetstatic(asm, sysOut)
  emitAconstNull(asm)
  emitInvokestatic(asm, isNullRef)
  emitInvokevirtual(asm, printlnI)

  // isNull("hello") → 0
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hello")
  emitInvokestatic(asm, isNullRef)
  emitInvokevirtual(asm, printlnI)

  // orDefault(null, "default") → "default"
  emitGetstatic(asm, sysOut)
  emitAconstNull(asm)
  emitPushString(asm, "default")
  emitInvokestatic(asm, orDefaultRef)
  emitInvokevirtual(asm, printlnS)

  // orDefault("hi", "x") → "hi"
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "hi")
  emitPushString(asm, "x")
  emitInvokestatic(asm, orDefaultRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

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
  val outDir = "/tmp/lyric-jvm-b37"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val nullCheckBytes = makeNullCheckClassBytes()
  val mainBytes      = makeMainClassBytes()

  val nullCheckClass = BuiltClass(binaryName = "NullCheck", bytes = nullCheckBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(nullCheckClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB37",
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
