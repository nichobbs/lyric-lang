// jvm/self_test_b93.l — Stage B93: lowerProtected smoke test.
//
// Builds a Counter protected type (ReentrantLock-guarded) via lowerProtected.
// Entry methods: increment()V (inc count field) and get():int (read count).
//
// Main creates a Counter, increments it 3 times, and prints the value.
//
// Main prints:
//   count=3

package Jvm.SelfTestB93

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Lowering
import Jvm.Driver

func makeCounterBytes(): List[Byte] {
  val pool = poolNew()

  // "count" field (private, managed by protected-type semantics)
  val countField = LField(flags = ACC_PRIVATE, name = "count", fieldType = JInt)
  val fields: List[LField] = newList()
  fields.add(countField)

  // increment()V — body: this.count = this.count + 1; stack empty at end
  val incInsns: List[LInsn] = newList()
  incInsns.add(LAload(slot = 0))
  incInsns.add(LAload(slot = 0))
  incInsns.add(LGetfield(owner = "Counter", name = "count", t = JInt))
  incInsns.add(LIconst(v = 1))
  incInsns.add(LIadd)
  incInsns.add(LPutfield(owner = "Counter", name = "count", t = JInt))
  val incParams: List[JvmType] = newList()
  val incFn = LFunc(
    flags     = ACC_PUBLIC,
    name      = "increment",
    params    = incParams,
    ret       = JVoid,
    insns     = incInsns,
    maxStack  = 3,
    maxLocals = 1
  )

  // get():int — body: push this.count; stack has 1 int at end
  val getInsns: List[LInsn] = newList()
  getInsns.add(LAload(slot = 0))
  getInsns.add(LGetfield(owner = "Counter", name = "count", t = JInt))
  val getParams: List[JvmType] = newList()
  val getFn = LFunc(
    flags     = ACC_PUBLIC,
    name      = "get",
    params    = getParams,
    ret       = JInt,
    insns     = getInsns,
    maxStack  = 1,
    maxLocals = 1
  )

  val entries: List[LFunc] = newList()
  entries.add(incFn)
  entries.add(getFn)

  val prot = LProtected(className = "Counter", fields = fields, entries = entries)
  val cf   = lowerProtected(prot, pool)
  serializeClassWithPool(cf, pool)
}

func makeMainBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val sysOutIdx  = poolFieldref(pool, "java/lang/System",    "out",     "Ljava/io/PrintStream;")
  val printlnIdx = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatIdx  = poolMethodref(pool, "java/lang/String",    "concat",  "(Ljava/lang/String;)Ljava/lang/String;")
  val valueOfIdx = poolMethodref(pool, "java/lang/String",    "valueOf", "(I)Ljava/lang/String;")

  val ctrInitIdx = poolMethodref(pool, "Counter", "<init>",    "()V")
  val incIdx     = poolMethodref(pool, "Counter", "increment", "()V")
  val getIdx     = poolMethodref(pool, "Counter", "get",       "()I")
  val ctrClassIdx = poolClass(pool, "Counter")

  // Counter ctr = new Counter();  [slot 0]
  emitNew(asm, ctrClassIdx)
  emitDup(asm)
  emitInvokespecial(asm, ctrInitIdx)
  emitAstore(asm, 0)

  // ctr.increment(); ctr.increment(); ctr.increment();
  emitAload(asm, 0)
  emitInvokevirtual(asm, incIdx)
  emitAload(asm, 0)
  emitInvokevirtual(asm, incIdx)
  emitAload(asm, 0)
  emitInvokevirtual(asm, incIdx)

  // System.out.println("count=" + String.valueOf(ctr.get()))
  emitGetstatic(asm, sysOutIdx)
  emitPushString(asm, "count=")
  emitAload(asm, 0)
  emitInvokevirtual(asm, getIdx)
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
  val outDir = "/tmp/lyric-jvm-b93"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val counterClass = BuiltClass(binaryName = "Counter", bytes = makeCounterBytes())
  val mainClass    = BuiltClass(binaryName = "Main",    bytes = makeMainBytes())
  val classes: List[BuiltClass] = newList()
  classes.add(counterClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB93",
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
