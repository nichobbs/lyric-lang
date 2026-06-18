//! jvm/self_test_b74.l — Stage B74: if_acmpeq / if_acmpne (reference equality).
//!
//! Generates RefEq.class with:
//!   same(Object,Object)I  — returns 1 if a == b (same reference), else 0
//!   different(Object,Object)I — returns 1 if a != b, else 0
//!
//! Main prints:
//!   val s = "hello"
//!   same(s, s)      → 1  (same reference)
//!   same(s, "world")→ 0  (different references)
//!   different(s, s) → 0
//!   different(s, "world") → 1
//!
//! Exercises: if_acmpeq, if_acmpne.
package Jvm.SelfTestB74

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeRefEqBytes(): List[Byte] {
  val pool = poolNew()

  // same(Object,Object)I
  val asmSame = newAssembler(pool)
  emitAload(asmSame, 0)
  emitAload(asmSame, 1)
  emitIfAcmpeq(asmSame, "SAME_YES")
  emitIconst(asmSame, 0)
  emitIreturn(asmSame)
  emitLabel(asmSame, "SAME_YES")
  emitIconst(asmSame, 1)
  emitIreturn(asmSame)
  val sameCode = assembleCode(asmSame, 2, 2)
  val sameAttrs: List[Attribute] = newList()
  sameAttrs.add(sameCode)
  val sameMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "same", "(Ljava/lang/Object;Ljava/lang/Object;)I", sameAttrs)

  // different(Object,Object)I
  val asmDiff = newAssembler(pool)
  emitAload(asmDiff, 0)
  emitAload(asmDiff, 1)
  emitIfAcmpne(asmDiff, "DIFF_YES")
  emitIconst(asmDiff, 0)
  emitIreturn(asmDiff)
  emitLabel(asmDiff, "DIFF_YES")
  emitIconst(asmDiff, 1)
  emitIreturn(asmDiff)
  val diffCode = assembleCode(asmDiff, 2, 2)
  val diffAttrs: List[Attribute] = newList()
  diffAttrs.add(diffCode)
  val diffMethod = makeMethodInfo(
    ACC_PUBLIC + ACC_STATIC,
    "different",
    "(Ljava/lang/Object;Ljava/lang/Object;)I",
    diffAttrs
  )

  val methods: List[MethodInfo] = newList()
  methods.add(sameMethod)
  methods.add(diffMethod)
  val cf = makeClassWithMethodsV49("RefEq", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val sameRef = poolMethodref(pool, "RefEq", "same", "(Ljava/lang/Object;Ljava/lang/Object;)I")
  val diffRef = poolMethodref(pool, "RefEq", "different", "(Ljava/lang/Object;Ljava/lang/Object;)I")

  // Store a single interned string in slot 0
  emitPushString(asm, "hello")
  emitAstore(asm, 0)

  // println(RefEq.same(s, s)) → 1
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitAload(asm, 0)
  emitInvokestatic(asm, sameRef)
  emitInvokevirtual(asm, printlnI)

  // println(RefEq.same(s, "world")) → 0
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitPushString(asm, "world")
  emitInvokestatic(asm, sameRef)
  emitInvokevirtual(asm, printlnI)

  // println(RefEq.different(s, s)) → 0
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitAload(asm, 0)
  emitInvokestatic(asm, diffRef)
  emitInvokevirtual(asm, printlnI)

  // println(RefEq.different(s, "world")) → 1
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitPushString(asm, "world")
  emitInvokestatic(asm, diffRef)
  emitInvokevirtual(asm, printlnI)

  emitReturn(asm)

  // maxStack: getstatic(1)+aload(2)+str(3) = 3 peak
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
  val outDir = "/tmp/lyric-jvm-b74"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val refEqBytes = makeRefEqBytes()
  val mainBytes = makeMainClassBytes()

  val refEqClass = BuiltClass(binaryName = "RefEq", bytes = refEqBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(refEqClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB74",
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
