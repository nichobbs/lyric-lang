//! jvm/self_test_b9.l — Stage B9 smoke test: class-file reader round-trip.
//!
//! Builds a minimal Hello.class in memory (same construction as Jvm.SelfTest),
//! then feeds the raw bytes to Jvm.Reader.parseClassSummary and prints the
//! parsed summary fields.  No filesystem access is needed for the read-back.
//!
//! The Expecto test (JvmLoweringB9Test.fs) compiles and runs this program,
//! then verifies:
//!   magic_valid=true  (0xCAFEBABE confirmed by reader)
//!   major=65          (Java 21)
//!   method_count=1    (Hello declares exactly one method: main)
package Jvm.SelfTestB9

import Std.Core
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Reader

func makeHelloBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  val outRef = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  emitGetstatic(asm, outRef)
  emitPushString(asm, "hello from b9")
  val printRef = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  emitInvokevirtual(asm, printRef)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 2, 1)
  val mainAttrs: List[Attribute] = newList()
  mainAttrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", mainAttrs)
  val cfMethods: List[MethodInfo] = newList()
  cfMethods.add(mainMethod)
  val cf = makeClassWithMethods("Hello", cfMethods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val bytes = makeHelloBytes()
  val summary = parseClassSummary(bytes)

  if summary.magicValid {
    println("magic_valid=true")
  } else {
    println("magic_valid=false")
  }
  println("major=" + toString(summary.majorVersion))
  println("pool_count=" + toString(summary.poolCount))
  println("access_flags=" + toString(summary.accessFlags))
  println("method_count=" + toString(summary.methodCount))
}
