//! jvm/self_test_b96.l — Stage B96: reader round-trip smoke test.
//!
//! Builds a simple class (Hello.class with one static main method) via
//! Jvm.Classfile + Jvm.Bytecode, serializes it to bytes, then parses it
//! back with Jvm.Reader.parseClassSummary and verifies the structural fields.
//!
//! This validates the Jvm.Reader implementation against the Jvm.Classfile writer.
//!
//! Prints (Lyric stdout, not Java):
//!   magic_valid=true
//!   major=65
//!   method_count=1
package Jvm.SelfTestB96

import Std.Core
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Reader

func main(): Unit {
  // Build a minimal Hello.class: one static main()V that just returns.
  val pool = poolNew()
  val asm = newAssembler(pool)
  emitReturn(asm)
  val code = assembleCode(asm, 0, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(code)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Hello", methods)
  val bytes = serializeClassWithPool(cf, pool)

  // Parse the bytes back and check the structural summary.
  val summary = parseClassSummary(bytes)

  if summary.magicValid {
    println("magic_valid=true")
  } else {
    println("magic_valid=false")
  }

  println("major=" + toString(summary.majorVersion))
  println("method_count=" + toString(summary.methodCount))
}
