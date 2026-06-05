//! jvm/self_test_b8.l — Stage B8 smoke test: differential fuzzing corpus.
//!
//! Calls makeFuzzCorpus, lowers all methods, adds a no-op main() so the
//! class is loadable, writes B8Corpus.class to /tmp/lyric-jvm-b8/, and
//! prints the byte count and method count.
//!
//! The Expecto test (JvmLoweringB8Test.fs) runs this program to produce the
//! class file, then executes `java -Xverify:all -cp /tmp/lyric-jvm-b8 B8Corpus`
//! and verifies exit code 0, proving that all 13 corpus methods plus main()
//! pass the JVM verifier.
package Jvm.SelfTestB8

import Std.Core
import Std.File
import Std.Collections
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Fuzzer

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b8"
  val _ = createDir(outDir)

  val pool = poolNew()
  val corpus = makeFuzzCorpus(pool)

  val methods: List[MethodInfo] = newList()
  var i = 0
  while i < corpus.count {
    methods.add(lowerFunc(corpus[i], pool))
    i = i + 1
  }

  // Add a main(String[] args)V so `java B8Corpus` can load and verify all methods.
  val mainInsns: List[LInsn] = newList()
  mainInsns.add(LReturn)
  val mainParamsList: List[JvmType] = newList()
  mainParamsList.add(JArray(elem = JRef(className = "java/lang/String")))
  val mainFunc = LFunc(
    flags = ACC_PUBLIC + ACC_STATIC,
    name = "main",
    params = mainParamsList,
    ret = JVoid,
    insns = mainInsns,
    maxStack = 0,
    maxLocals = 1
  )
  methods.add(lowerFunc(mainFunc, pool))

  val fields: List[FieldInfo] = newList()
  val cf = makeClassFull("B8Corpus", fields, methods)
  val bytes = serializeClassWithPool(cf, pool)
  match writeBytes(outDir + "/B8Corpus.class", bytes) {
    case Ok(_) -> println("wrote B8Corpus.class (" + toString(bytes.count) + " bytes, " + toString(methods.count) + " methods)")
    case Err(_) -> println("writeBytes failed for B8Corpus.class")
  }
}
