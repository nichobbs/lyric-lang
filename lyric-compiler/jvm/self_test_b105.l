//! jvm/self_test_b105.l — Stage B105: lowerMatchInt and lowerMatchStr helpers.
//!
//! Adds `LIntArm`/`lowerMatchInt` (lookupswitch dispatch) and
//! `LStrArm`/`lowerMatchStr` (String.equals chain dispatch) to lowering.l.
//!
//! Creates an IntOp class (emitted as Java 5 / V49 to avoid StackMapTable
//! complexity at merge points) with two static methods:
//!   intName(int n): String   — 1→"one", 2→"two", 3→"three", else "?"
//!   strCode(String s): int   — "a"→1, "b"→2, "c"→3, else 0
//!
//! Java output (java -jar):
//!   intName(1)=one
//!   intName(2)=two
//!   intName(4)=?
//!   strCode(a)=1
//!   strCode(b)=2
//!   strCode(x)=0
package Jvm.SelfTestB105

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build IntOp class (V49) ───────────────────────────────────────────────────
func makeIntNameMethod(pool: in Pool): MethodInfo {
  val asm = newAssembler(pool)

  val oneBody: List[LInsn] = newList()
  oneBody.add(LPushString(s = "one"))
  oneBody.add(LAreturn)

  val twoBody: List[LInsn] = newList()
  twoBody.add(LPushString(s = "two"))
  twoBody.add(LAreturn)

  val threeBody: List[LInsn] = newList()
  threeBody.add(LPushString(s = "three"))
  threeBody.add(LAreturn)

  val defaultBody: List[LInsn] = newList()
  defaultBody.add(LPushString(s = "?"))
  defaultBody.add(LAreturn)

  val arms: List[LIntArm] = newList()
  arms.add(LIntArm(key = 1, caseLabel = "case_one", bodyInsns = oneBody))
  arms.add(LIntArm(key = 2, caseLabel = "case_two", bodyInsns = twoBody))
  arms.add(LIntArm(key = 3, caseLabel = "case_three", bodyInsns = threeBody))

  lowerMatchInt(asm, 0, arms, "case_default", defaultBody, "end_int")
  // end_int: unreachable fallback required to resolve dead goto targets
  lowerInsn(LLabel(name = "end_int"), asm)
  lowerInsn(LAreturn, asm)

  // maxLocals = 1 (slot 0 = int arg)
  val codeAttr = assembleCodeInferred(asm, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)

  val ps: List[JvmType] = newList()
  ps.add(JInt)
  makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "intName", buildDescriptor(ps, JRef(className = "java/lang/String")), attrs)
}

func makeStrCodeMethod(pool: in Pool): MethodInfo {
  val asm = newAssembler(pool)

  val aBody: List[LInsn] = newList()
  aBody.add(LIconst(v = 1))
  aBody.add(LIreturn)

  val bBody: List[LInsn] = newList()
  bBody.add(LIconst(v = 2))
  bBody.add(LIreturn)

  val cBody: List[LInsn] = newList()
  cBody.add(LIconst(v = 3))
  cBody.add(LIreturn)

  val defaultBody: List[LInsn] = newList()
  defaultBody.add(LIconst(v = 0))
  defaultBody.add(LIreturn)

  val arms: List[LStrArm] = newList()
  arms.add(LStrArm(key = "a", skipLabel = "skip_a", bodyInsns = aBody))
  arms.add(LStrArm(key = "b", skipLabel = "skip_b", bodyInsns = bBody))
  arms.add(LStrArm(key = "c", skipLabel = "skip_c", bodyInsns = cBody))

  lowerMatchStr(asm, 0, arms, defaultBody, "end_str")
  // end_str: unreachable fallback required to resolve dead goto targets
  lowerInsn(LLabel(name = "end_str"), asm)
  lowerInsn(LIreturn, asm)

  // maxLocals = 1 (slot 0 = String arg)
  val codeAttr = assembleCodeInferred(asm, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)

  val ps: List[JvmType] = newList()
  ps.add(JRef(className = "java/lang/String"))
  makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "strCode", buildDescriptor(ps, JInt), attrs)
}

func makeIntOpBytes(): List[Byte] {
  val pool = poolNew()
  val methods: List[MethodInfo] = newList()
  methods.add(makeIntNameMethod(pool))
  methods.add(makeStrCodeMethod(pool))
  val cf = makeClassWithMethodsV49("IntOp", methods)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────
func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val intNameIdx = poolMethodref(pool, "IntOp", "intName", "(I)Ljava/lang/String;")
  val strCodeIdx = poolMethodref(pool, "IntOp", "strCode", "(Ljava/lang/String;)I")

  // println("intName(1)=" + IntOp.intName(1))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "intName(1)=")
  emitPushInt(asm, 1)
  emitInvokestatic(asm, intNameIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("intName(2)=" + IntOp.intName(2))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "intName(2)=")
  emitPushInt(asm, 2)
  emitInvokestatic(asm, intNameIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("intName(4)=" + IntOp.intName(4))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "intName(4)=")
  emitPushInt(asm, 4)
  emitInvokestatic(asm, intNameIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("strCode(a)=" + String.valueOf(IntOp.strCode("a")))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "strCode(a)=")
  emitPushString(asm, "a")
  emitInvokestatic(asm, strCodeIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("strCode(b)=" + String.valueOf(IntOp.strCode("b")))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "strCode(b)=")
  emitPushString(asm, "b")
  emitInvokestatic(asm, strCodeIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // println("strCode(x)=" + String.valueOf(IntOp.strCode("x")))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "strCode(x)=")
  emitPushString(asm, "x")
  emitInvokestatic(asm, strCodeIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

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

// ── Entry point ───────────────────────────────────────────────────────────────
func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b105"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "IntOp", bytes = makeIntOpBytes()))
  classes.add(BuiltClass(binaryName = "Main", bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB105",
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
