//! jvm/self_test.l — Stage B2 smoke test for the JVM classfile / bytecode packages.
//!
//! Builds a minimal JVM class file for:
//!
//!   public class Hello {
//!     public static void main(String[] args) {
//!       System.out.println("hello from lyric-jvm");
//!     }
//!   }
//!
//! Serializes it to the path given as argv[0], then prints a one-line summary.
//! The Expecto test in Lyric.Emitter.Tests compiles this program, runs it,
//! then runs `javap -c Hello.class` to verify the bytes are JVM-loadable.
package Jvm.SelfTest

import Std.Core
import Std.File
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode

pub func makeHelloClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // getstatic java/lang/System.out : Ljava/io/PrintStream;
  val outRef = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  emitGetstatic(asm, outRef)

  // ldc "hello from lyric-jvm"
  emitPushString(asm, "hello from lyric-jvm")

  // invokevirtual java/io/PrintStream.println:(Ljava/lang/String;)V
  val printRef = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  emitInvokevirtual(asm, printRef)

  // return (void)
  emitReturn(asm)

  // Code attribute: maxStack=2 (out + string), maxLocals=1 (String[] args)
  val codeAttr = assembleCode(asm, 2, 1)

  // Build MethodInfo for main
  val mainAttrs: List[Attribute] = newList()
  mainAttrs.add(codeAttr)

  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", mainAttrs)

  // Build ClassFile via makeClassWithMethods (defaults: major=65,
  // ACC_PUBLIC|ACC_SUPER) — accepts the methods list up-front so we
  // don't need post-construction field access on the imported record.
  val cfMethods: List[MethodInfo] = newList()
  cfMethods.add(mainMethod)
  val cf = makeClassWithMethods("Hello", cfMethods)

  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val bytes = makeHelloClassBytes()
  val outPath = "/tmp/lyric-jvm-selftest/Hello.class"
  val _ = createDir("/tmp/lyric-jvm-selftest")
  match writeBytes(outPath, bytes) {
    case Ok(_) -> println("wrote " + toString(bytes.count) + " bytes to " + outPath)
    case Err(err) -> println("writeBytes failed")
  }
}
