// jvm/self_test_b109.l — Stage B109: lowerRangeType.
//
// Creates two range-subtype wrapper classes (§6.4 bootstrap form):
//   Age    — wraps int, range [0, 150]  (type Age = Int range 0 ..= 150)
//   Score  — wraps int, range [0, 100]  (type Score = Int range 0 ..= 100)
//
// A Main class:
//   - Constructs Age(42)  → succeeds, prints age.$value=42
//   - Constructs Score(99) → succeeds, prints score.$value=99
//   - Constructs Age(200)  → throws IllegalArgumentException, caught; prints age_bad=caught
//
// Main uses V49 (Java 5) via a raw assembly to avoid StackMapTable at
// the exception-handler entry point.
//
// Java output (java -jar):
//   age.$value=42
//   score.$value=99
//   age_bad=caught

package Jvm.SelfTestB109

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

// ── Build wrapper classes ─────────────────────────────────────────────────────

func makeAgeBytes(): List[Byte] {
  val pool = poolNew()
  val cf = lowerRangeType(LRangeType(wrapperClass = "Age",   underlyingType = JInt, lo = 0, hi = 150), pool)
  serializeClassWithPool(cf, pool)
}

func makeScoreBytes(): List[Byte] {
  val pool = poolNew()
  val cf = lowerRangeType(LRangeType(wrapperClass = "Score", underlyingType = JInt, lo = 0, hi = 100), pool)
  serializeClassWithPool(cf, pool)
}

// ── Build Main class (V49, manual try-catch) ──────────────────────────────────

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool,  "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")

  val ageNewIdx    = poolClass(pool, "Age")
  val ageCtorIdx   = poolMethodref(pool, "Age",   "<init>", "(I)V")
  val ageAccIdx    = poolMethodref(pool, "Age",   "$value", "()I")
  val scoreNewIdx  = poolClass(pool, "Score")
  val scoreCtorIdx = poolMethodref(pool, "Score", "<init>", "(I)V")
  val scoreAccIdx  = poolMethodref(pool, "Score", "$value", "()I")

  // Age age = new Age(42); println("age.$value=" + age.$value())
  emitNew(asm, ageNewIdx)
  emitDup(asm)
  emitPushInt(asm, 42)
  emitInvokespecial(asm, ageCtorIdx)
  emitAstore(asm, 1)

  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "age.$value=")
  emitAload(asm, 1)
  emitInvokevirtual(asm, ageAccIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // Score score = new Score(99); println("score.$value=" + score.$value())
  emitNew(asm, scoreNewIdx)
  emitDup(asm)
  emitPushInt(asm, 99)
  emitInvokespecial(asm, scoreCtorIdx)
  emitAstore(asm, 2)

  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "score.$value=")
  emitAload(asm, 2)
  emitInvokevirtual(asm, scoreAccIdx)
  emitInvokestatic(asm, valueOfIdx)
  emitInvokevirtual(asm, concatIdx)
  emitInvokevirtual(asm, printlnIdx)

  // try { new Age(200); pop; } catch(IAE) { println("age_bad=caught"); }
  // Label structure: try_start → new Age(200) → pop → goto try_ok
  //                  try_end (= try_handler entry point)
  //                  try_handler: pop exception; print "age_bad=caught"
  //                  try_ok: return
  emitLabel(asm, "try_start")
  emitNew(asm, ageNewIdx)
  emitDup(asm)
  emitPushInt(asm, 200)
  emitInvokespecial(asm, ageCtorIdx)
  emitPop(asm)
  emitLabel(asm, "try_end")
  emitGoto(asm, "try_ok")
  emitLabel(asm, "try_handler")
  emitPop(asm)
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "age_bad=caught")
  emitInvokevirtual(asm, printlnIdx)
  emitLabel(asm, "try_ok")
  emitReturn(asm)

  val iaeClass = "java/lang/IllegalArgumentException"
  val iaeIdx   = poolClass(pool, iaeClass)

  // maxStack=3 (new+dup+push or getstatic+ldc+concat), maxLocals=3 (args, age, score)
  val codeAttr = assembleCodeWith1Handler(asm, 3, 3,
    "try_start", "try_end", "try_handler", iaeIdx)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)

  // V49 class file to avoid StackMapTable requirement at handler entry point.
  // Use makeClassWithMethodsV49 rather than direct ClassFile record construction
  // since the Lyric emitter has a known limitation with cross-package record
  // construction of types with List[TyUser] fields (D035 erasure).
  val cf = makeClassWithMethodsV49("Main", methods)
  serializeClassWithPool(cf, pool)
}

// ── Entry point ───────────────────────────────────────────────────────────────

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b109"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val classes: List[BuiltClass] = newList()
  classes.add(BuiltClass(binaryName = "Age",   bytes = makeAgeBytes()))
  classes.add(BuiltClass(binaryName = "Score", bytes = makeScoreBytes()))
  classes.add(BuiltClass(binaryName = "Main",  bytes = makeMainBytes()))

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB109",
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
