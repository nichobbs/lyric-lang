//! jvm/self_test_b97.l — Stage B97: assembleCodeWithFrames (manual Java 21 loop).
//!
//! Demonstrates assembleCodeWithFrames by hand-assembling a `sum(int n)` method
//! that uses a backward branch (loop).  `assembleCodeWithFrames` requires the
//! caller to supply explicit `frameLocals` and embeds a StackMapTable so the
//! resulting class passes JVM verification at major version 65 (Java 21).
//!
//! Loop: slot 0 = n (counts down to 0), slot 1 = acc (accumulates).
//!   acc = 0
//!   loop: if n == 0 goto done
//!         acc = acc + n
//!         n--
//!         goto loop
//!   done: return acc
//!
//! Branch targets "loop" and "done" both have empty stack; both see
//! frameLocals = [VInteger, VInteger].
//!
//! Java output (java -jar):
//!   sum(10)=55
//!   sum(5)=15
package Jvm.SelfTestB97

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeSumBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // sum(int n): int
  //   slot 0 = n  (parameter, used as countdown counter)
  //   slot 1 = acc (accumulator)
  emitPushInt(asm, 0)
  emitIstore(asm, 1)
  // acc = 0

  emitLabel(asm, "loop")
  // <- branch target
  emitIload(asm, 0)
  // load n
  emitIfeq(asm, "done")
  // if n == 0 goto done
  emitIload(asm, 1)
  // load acc
  emitIload(asm, 0)
  // load n
  emitIadd(asm)
  // acc + n
  emitIstore(asm, 1)
  // store acc
  emitIinc(asm, 0, -1)
  // n--
  emitGoto(asm, "loop")

  emitLabel(asm, "done")
  // <- branch target
  emitIload(asm, 1)
  // load acc
  emitIreturn(asm)

  val frameLocals: List[VerifierType] = newList()
  frameLocals.add(VInteger)
  frameLocals.add(VInteger)

  val codeAttr = assembleCodeWithFrames(asm, 2, 2, frameLocals)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sum", "(I)I", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(sumMethod)
  val cf = makeClassWithMethods("Sum", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOutIdx = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val sumIdx = poolMethodref(pool, "Sum", "sum", "(I)I")

  // System.out.println("sum(10)=" + String.valueOf(Sum.sum(10)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "sum(10)=")
  emitPushInt(asm, 10)
  emitInvokestatic(asm, sumIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // System.out.println("sum(5)=" + String.valueOf(Sum.sum(5)))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "sum(5)=")
  emitPushInt(asm, 5)
  emitInvokestatic(asm, sumIdx)
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
  val outDir = "/tmp/lyric-jvm-b97"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val sumClass = BuiltClass(binaryName = "Sum", bytes = makeSumBytes())
  val mainClass = BuiltClass(binaryName = "Main", bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(sumClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB97",
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
