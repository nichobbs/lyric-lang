//! jvm/self_test_b54.l — Stage B54: while-loop accumulation (iinc, if_icmpgt, goto back).
//!
//! Generates Sums.class (Java 5 / major=49) with:
//!   sum(I)I — computes 1+2+...+n via a while loop
//!
//! Main prints:
//!   sum(5)  → 15
//!   sum(10) → 55
//!
//! Exercises: istore/iload for multiple locals, if_icmpgt for loop guard,
//!            iinc for counter, backward goto for loop body, iadd for accumulation.
package Jvm.SelfTestB54

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeSumsClassBytes(): List[Byte] {
  val pool = poolNew()

  // ── sum(I)I ──────────────────────────────────────────────────────────────────
  // slot 0 = n, slot 1 = total, slot 2 = i
  // total = 0; i = 1
  // LOOP: if i > n goto DONE; total += i; i++; goto LOOP
  // DONE: return total
  val asm = newAssembler(pool)
  emitIconst(asm, 0)
  emitIstore(asm, 1)
  // total = 0
  emitIconst(asm, 1)
  emitIstore(asm, 2)
  // i = 1
  emitLabel(asm, "LOOP")
  emitIload(asm, 2)
  emitIload(asm, 0)
  emitIfIcmpgt(asm, "DONE")
  // if i > n: done
  emitIload(asm, 1)
  emitIload(asm, 2)
  emitIadd(asm)
  emitIstore(asm, 1)
  // total += i
  emitIinc(asm, 2, 1)
  // i++
  emitGoto(asm, "LOOP")
  emitLabel(asm, "DONE")
  emitIload(asm, 1)
  emitIreturn(asm)

  // maxStack: iload_2(1) + iload_0(2) peak; or iload_1(1) + iload_2(2) peak = 2
  val sumCode = assembleCode(asm, 2, 3)
  val sumAttrs: List[Attribute] = newList()
  sumAttrs.add(sumCode)
  val sumMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "sum", "(I)I", sumAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(sumMethod)
  val cf = makeClassWithMethodsV49("Sums", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnI = poolMethodref(pool, "java/io/PrintStream", "println", "(I)V")
  val sumRef = poolMethodref(pool, "Sums", "sum", "(I)I")

  // println(Sums.sum(5))   → 15
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 5)
  emitInvokestatic(asm, sumRef)
  emitInvokevirtual(asm, printlnI)

  // println(Sums.sum(10))  → 55
  emitGetstatic(asm, sysOut)
  emitPushInt(asm, 10)
  emitInvokestatic(asm, sumRef)
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
  val outDir = "/tmp/lyric-jvm-b54"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val sumsBytes = makeSumsClassBytes()
  val mainBytes = makeMainClassBytes()

  val sumsClass = BuiltClass(binaryName = "Sums", bytes = sumsBytes)
  val mainClass = BuiltClass(binaryName = "Main", bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(sumsClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB54",
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
