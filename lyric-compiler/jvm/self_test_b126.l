//! jvm/self_test_b126.l — Stage B126: @LyricTest annotation + lowerTestModuleClass.
//!
//! Demonstrates:
//!   1. `lyricTestAnnotationClass(pool)` — serialises the
//!      `lyric/runtime/jvm/LyricTest` annotation interface.
//!   2. `lowerTestModuleClass(...)` — serialises a test-module class with two
//!      `@LyricTest`-annotated `public static void __lyric_test_<i>()` stubs.
//!   3. A reflection-based TestVerifier Main class (Java 5 format to avoid
//!      StackMapTable) that loads the test module, reads `@LyricTest` from
//!      `__lyric_test_0`, and prints the annotation type name.
//!
//! Expected Java output (via `java -jar`):
//!   annotation_count=1
//!   annotation_type=lyric.runtime.jvm.LyricTest
package Jvm.SelfTestB126

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.TestEngine
import Jvm.Driver

// ── Build @LyricTest annotation class bytes ───────────────────────────────────
func makeAnnotationBytes(): List[Byte] {
  val pool = poolNew()
  val cf = lyricTestAnnotationClass(pool)
  serializeClassWithPool(cf, pool)
}

// ── Build test-module class bytes ─────────────────────────────────────────────
func makeTestModuleBytes(): List[Byte] {
  val pool = poolNew()
  val slots: List[TestMethodSlot] = newList()
  slots.add(
    TestMethodSlot(
      funcName = "__lyric_test_0",
      displayName = "addition works",
      sourceFile = "math_tests.l",
      sourceLine = 7
    )
  )
  slots.add(
    TestMethodSlot(
      funcName = "__lyric_test_1",
      displayName = "subtraction is inverse of addition",
      sourceFile = "math_tests.l",
      sourceLine = 14
    )
  )
  val cf = lowerTestModuleClass("math_tests", slots, pool)
  serializeClassWithPool(cf, pool)
}

// ── Build reflection-based TestVerifier class bytes ───────────────────────────
//
// Uses Java 5 class format (major=49) to avoid needing a StackMapTable for
// the conditional branch.  The verifier:
//   1. Loads lyric.runtime.jvm.LyricTest via Class.forName.
//   2. Gets math_tests.__lyric_test_0 via getDeclaredMethod.
//   3. Calls Method.getDeclaredAnnotations().
//   4. Prints annotation_count=N.
//   5. Prints annotation_type=<name of first annotation>.
func makeVerifierBytes(): List[Byte] {
  val pool = poolNew()
  val asm = newAssembler(pool)

  // Pool refs
  val classForName = poolMethodref(pool, "java/lang/Class", "forName", "(Ljava/lang/String;)Ljava/lang/Class;")
  val classGetMethod = poolMethodref(
    pool,
    "java/lang/Class",
    "getDeclaredMethod",
    "(Ljava/lang/String;[Ljava/lang/Class;)Ljava/lang/reflect/Method;"
  )
  val methodGetAnns = poolMethodref(
    pool,
    "java/lang/reflect/Method",
    "getDeclaredAnnotations",
    "()[Ljava/lang/annotation/Annotation;"
  )
  val annType = poolMethodref(pool, "java/lang/annotation/Annotation", "annotationType", "()Ljava/lang/Class;")
  val classGetName = poolMethodref(pool, "java/lang/Class", "getName", "()Ljava/lang/String;")
  val strValueOf = poolMethodref(pool, "java/lang/String", "valueOf", "(I)Ljava/lang/String;")
  val strConcat = poolMethodref(pool, "java/lang/String", "concat", "(Ljava/lang/String;)Ljava/lang/String;")
  val sysOut = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val println = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val classClassIdx = poolClass(pool, "java/lang/Class")
  val annIfaceIdx = poolIfaceMethodref(pool, "java/lang/annotation/Annotation", "annotationType", "()Ljava/lang/Class;")

  // --- Load the annotation class so the JVM's annotation machinery can
  //     resolve @LyricTest at runtime.
  // Class.forName("lyric.runtime.jvm.LyricTest") -> annClass (slot 1)
  emitPushString(asm, "lyric.runtime.jvm.LyricTest")
  emitInvokestatic(asm, classForName)
  emitAstore(asm, 1)

  // --- Get the test method
  // Class.forName("math_tests") -> testClass (slot 2)
  emitPushString(asm, "math_tests")
  emitInvokestatic(asm, classForName)
  emitAstore(asm, 2)

  // testClass.getDeclaredMethod("__lyric_test_0", new Class[0]) -> m (slot 3)
  emitAload(asm, 2)
  emitPushString(asm, "__lyric_test_0")
  emitPushInt(asm, 0)
  emitAnewarray(asm, classClassIdx)
  emitInvokevirtual(asm, classGetMethod)
  emitAstore(asm, 3)

  // m.getDeclaredAnnotations() -> anns (slot 4)
  emitAload(asm, 3)
  emitInvokevirtual(asm, methodGetAnns)
  emitAstore(asm, 4)

  // --- Print annotation_count=N
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "annotation_count=")
  emitAload(asm, 4)
  emitArraylength(asm)
  emitInvokestatic(asm, strValueOf)
  emitInvokevirtual(asm, strConcat)
  emitInvokevirtual(asm, println)

  // --- Print annotation_type=<name>
  // anns[0].annotationType().getName()
  emitGetstatic(asm, sysOut)
  emitPushString(asm, "annotation_type=")
  emitAload(asm, 4)
  emitPushInt(asm, 0)
  emitAaload(asm)
  emitInvokeinterface(asm, annIfaceIdx, 1)
  emitInvokevirtual(asm, classGetName)
  emitInvokevirtual(asm, strConcat)
  emitInvokevirtual(asm, println)

  emitReturn(asm)

  // maxStack: deepest is 5 (out + prefix + anns + 0 + elem at aaload)
  // maxLocals: 5 (slot 0=args, 1=annClass, 2=testClass, 3=method, 4=anns)
  val codeAttr = assembleCode(asm, 5, 5)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)

  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)

  // Use Java 5 (major=49) to skip StackMapTable.
  val cf = makeClassWithMethodsV49("TestVerifier", methods)
  serializeClassWithPool(cf, pool)
}

// ── Main: assemble JAR and print result ───────────────────────────────────────
func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b126"
  match createDir(outDir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  // The annotation class must be at the JVM path lyric/runtime/jvm/LyricTest.class
  classes.add(BuiltClass(binaryName = "lyric/runtime/jvm/LyricTest", bytes = makeAnnotationBytes()))
  classes.add(BuiltClass(binaryName = "math_tests", bytes = makeTestModuleBytes()))
  classes.add(BuiltClass(binaryName = "TestVerifier", bytes = makeVerifierBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB126",
    mainClass = "TestVerifier",
    version = "0.1.0",
    outPath = outDir + "/test_engine.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
