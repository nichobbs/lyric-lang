//! jvm/self_test_b90.l — Stage B90: lowerFunc + Java 21 (B5 stack-map proof).
//!
//! Generates IntUtils.class (Java 21, major=65) via lowerFunc.  The max(II)I
//! method has an if_icmpge branch; lowerFunc's B5 path auto-computes the
//! StackMapTable for "take_b" and "done".
//!
//! Main prints:
//!   max(3,7)=7
//!   max(9,2)=9
package Jvm.SelfTestB90

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeIntUtilsBytes(): List[Byte] {
  val pool = poolNew()

  // max(int a, int b): int — result stored to slot 2 before any branch target
  // so the stack is always empty at "skip_update" (B5 invariant satisfied).
  //   slot 0=a, slot 1=b, slot 2=result
  //   result = a;
  //   if a >= b goto skip_update;
  //   result = b;
  // skip_update:
  //   return result;
  val maxInsns: List[LInsn] = newList()
  maxInsns.add(LIload(slot = 0))
  maxInsns.add(LIstore(slot = 2))
  maxInsns.add(LIload(slot = 0))
  maxInsns.add(LIload(slot = 1))
  maxInsns.add(LIfIcmpge(label = "skip_update"))
  maxInsns.add(LIload(slot = 1))
  maxInsns.add(LIstore(slot = 2))
  maxInsns.add(LLabel(name = "skip_update"))
  maxInsns.add(LIload(slot = 2))
  maxInsns.add(LIreturn)

  val maxParams: List[JvmType] = newList()
  maxParams.add(JInt)
  maxParams.add(JInt)

  val maxFn = LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "max",
    params = maxParams,
    ret = JInt,
    insns = maxInsns,
    maxStack = 2,
    maxLocals = 3
  )

  val methods: List[MethodInfo] = newList()
  methods.add(lowerFunc(maxFn, pool))

  // Java 21 class file — StackMapTable auto-computed by lowerFunc
  val cf = makeClassWithMethods("IntUtils", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val maxIdx = poolMethodref(pool, "IntUtils", "max", "(II)I")

  // System.out.println("max(3,7)=" + String.valueOf(IntUtils.max(3, 7)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "max(3,7)=")
  emitPushInt(asm, 3)
  emitPushInt(asm, 7)
  emitInvokestatic(asm, maxIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // System.out.println("max(9,2)=" + String.valueOf(IntUtils.max(9, 2)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "max(9,2)=")
  emitPushInt(asm, 9)
  emitPushInt(asm, 2)
  emitInvokestatic(asm, maxIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

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
  val outDir = "/tmp/lyric-jvm-b90"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val intUtilsClass = BuiltClass(binaryName = "IntUtils", bytes = makeIntUtilsBytes())
  val mainClass = BuiltClass(binaryName = "Main", bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(intUtilsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB90",
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
