// jvm/self_test_b69.l — Stage B69: java.util.LinkedList as a stack/queue.
//
// Generates QueueDemo.class with:
//   buildQueue()LinkedList  — creates LinkedList, addLast("a"), addLast("b"), addLast("c")
//   peekFirst(LinkedList)String — calls list.peekFirst()
//   pollFirst(LinkedList)String — calls list.pollFirst()
//
// Main:
//   q = buildQueue()
//   println(peekFirst(q))   → "a"  (peek doesn't remove)
//   println(pollFirst(q))   → "a"  (removes "a")
//   println(pollFirst(q))   → "b"  (removes "b")
//   println(peekFirst(q))   → "c"  (only "c" remains)
//
// Exercises: new java/util/LinkedList, invokevirtual LinkedList.addLast/peekFirst/pollFirst,
//            checkcast String on Object return value.

package Jvm.SelfTestB69

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeQueueDemoBytes(): List[Byte] {
  val pool         = poolNew()
  val llClass      = poolClass(pool, "java/util/LinkedList")
  val llInit       = poolMethodref(pool, "java/util/LinkedList", "<init>", "()V")
  val addLastRef   = poolMethodref(pool, "java/util/LinkedList", "addLast",  "(Ljava/lang/Object;)V")
  val peekFirstRef = poolMethodref(pool, "java/util/LinkedList", "peekFirst","()Ljava/lang/Object;")
  val pollFirstRef = poolMethodref(pool, "java/util/LinkedList", "pollFirst","()Ljava/lang/Object;")
  val strClass     = poolClass(pool, "java/lang/String")

  // buildQueue()LinkedList
  val asmBuild = newAssembler(pool)
  emitNew(asmBuild, llClass)
  emitDup(asmBuild)
  emitInvokespecial(asmBuild, llInit)
  emitAstore(asmBuild, 0)
  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "a")
  emitInvokevirtual(asmBuild, addLastRef)
  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "b")
  emitInvokevirtual(asmBuild, addLastRef)
  emitAload(asmBuild, 0)
  emitPushString(asmBuild, "c")
  emitInvokevirtual(asmBuild, addLastRef)
  emitAload(asmBuild, 0)
  emitAreturn(asmBuild)
  // maxStack: new(1)+dup(2) = 2 peak for constructor
  val buildCode = assembleCode(asmBuild, 2, 1)
  val buildAttrs: List[Attribute] = newList()
  buildAttrs.add(buildCode)
  val buildMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "buildQueue",
    "()Ljava/util/LinkedList;", buildAttrs)

  // peekFirst(LinkedList)String
  val asmPeek = newAssembler(pool)
  emitAload(asmPeek, 0)
  emitInvokevirtual(asmPeek, peekFirstRef)
  emitCheckcast(asmPeek, strClass)
  emitAreturn(asmPeek)
  val peekCode = assembleCode(asmPeek, 1, 1)
  val peekAttrs: List[Attribute] = newList()
  peekAttrs.add(peekCode)
  val peekMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "peekFirst",
    "(Ljava/util/LinkedList;)Ljava/lang/String;", peekAttrs)

  // pollFirst(LinkedList)String
  val asmPoll = newAssembler(pool)
  emitAload(asmPoll, 0)
  emitInvokevirtual(asmPoll, pollFirstRef)
  emitCheckcast(asmPoll, strClass)
  emitAreturn(asmPoll)
  val pollCode = assembleCode(asmPoll, 1, 1)
  val pollAttrs: List[Attribute] = newList()
  pollAttrs.add(pollCode)
  val pollMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "pollFirst",
    "(Ljava/util/LinkedList;)Ljava/lang/String;", pollAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(buildMethod)
  methods.add(peekMethod)
  methods.add(pollMethod)
  val cf = makeClassWithMethods("QueueDemo", methods)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool       = poolNew()
  val asm        = newAssembler(pool)

  val sysOut     = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS   = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val buildRef   = poolMethodref(pool, "QueueDemo", "buildQueue", "()Ljava/util/LinkedList;")
  val peekRef    = poolMethodref(pool, "QueueDemo", "peekFirst", "(Ljava/util/LinkedList;)Ljava/lang/String;")
  val pollRef    = poolMethodref(pool, "QueueDemo", "pollFirst", "(Ljava/util/LinkedList;)Ljava/lang/String;")

  // q = QueueDemo.buildQueue()
  emitInvokestatic(asm, buildRef)
  emitAstore(asm, 0)

  // println(QueueDemo.peekFirst(q)) → "a"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokestatic(asm, peekRef)
  emitInvokevirtual(asm, printlnS)

  // println(QueueDemo.pollFirst(q)) → "a"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokestatic(asm, pollRef)
  emitInvokevirtual(asm, printlnS)

  // println(QueueDemo.pollFirst(q)) → "b"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokestatic(asm, pollRef)
  emitInvokevirtual(asm, printlnS)

  // println(QueueDemo.peekFirst(q)) → "c"
  emitGetstatic(asm, sysOut)
  emitAload(asm, 0)
  emitInvokestatic(asm, peekRef)
  emitInvokevirtual(asm, printlnS)

  emitReturn(asm)

  // maxStack: getstatic(1)+aload(2) = 2 peak
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
  val outDir = "/tmp/lyric-jvm-b69"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val queueDemoBytes = makeQueueDemoBytes()
  val mainBytes      = makeMainClassBytes()

  val queueDemoClass = BuiltClass(binaryName = "QueueDemo", bytes = queueDemoBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(queueDemoClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB69",
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
