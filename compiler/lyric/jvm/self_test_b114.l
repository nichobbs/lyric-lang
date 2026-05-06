// jvm/self_test_b114.l — Stage B114: lowerNatTag (phantom nat-tag classes for value generics).
//
// Creates two nat-tag phantom classes: N_42 and N_100.
// Each has a public static final long VALUE and a value() accessor.
//
// A Main class calls value() on each and prints the result.
//
// Java output (java -jar):
//   n=42
//   n=100

package Jvm.SelfTestB114

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build nat-tag classes ─────────────────────────────────────────────────────

func makeNatTagBytes(className: in String, value: in Long, pool: in Pool): List[Byte] {
  val cf = lowerNatTag(LNatTag(className = className, value = value), pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class ──────────────────────────────────────────────────────────

func makeMainBytes(pool: in Pool): List[Byte] {
  val asm = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val vofLIdx    = poolMethodref(pool, "java/lang/String",    "valueOf", "(J)Ljava/lang/String;")

  val n42Ctor    = poolMethodref(pool, "N_42",  "<init>", "()V")
  val n42Value   = poolMethodref(pool, "N_42",  "value",  "()J")
  val n100Ctor   = poolMethodref(pool, "N_100", "<init>", "()V")
  val n100Value  = poolMethodref(pool, "N_100", "value",  "()J")
  val n42Class   = poolClass(pool, "N_42")
  val n100Class  = poolClass(pool, "N_100")

  // N_42 tag42 = new N_42()
  emitNew(asm, n42Class)
  emitDup(asm)
  emitInvokespecial(asm, n42Ctor)
  emitAstore(asm, 1)

  // println("n=" + tag42.value())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "n=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, n42Value)
  emitInvokestatic(asm, vofLIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // N_100 tag100 = new N_100()
  emitNew(asm, n100Class)
  emitDup(asm)
  emitInvokespecial(asm, n100Ctor)
  emitAstore(asm, 2)

  // println("n=" + tag100.value())
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "n=")
  emitAload(asm, 2)
  emitInvokevirtual(asm, n100Value)
  emitInvokestatic(asm, vofLIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  emitReturn(asm)

  val codeAttr = assembleCode(asm, 5, 3)
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
  val outDir = "/tmp/lyric-jvm-b114"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val pool = poolNew()
  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "N_42",  bytes = makeNatTagBytes("N_42",  42i64,  pool)))
  classes.add(BuiltClass(binaryName = "N_100", bytes = makeNatTagBytes("N_100", 100i64, pool)))
  classes.add(BuiltClass(binaryName = "Main",  bytes = makeMainBytes(pool)))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB114",
    mainClass   = "Main",
    version     = "0.1.0",
    outPath     = outDir + "/hello.jar"
  )

  if writeJarFromClasses(req, classes) {
    println("jar_written=true")
  } else {
    println("jar_written=false")
  }
}
