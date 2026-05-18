// jvm/self_test_b87.l — Stage B87: invokedynamic via StringConcatFactory.makeConcat.
//
// Generates ConcatDemo.class with:
//   concat(String a, String b)String
//     — uses invokedynamic (StringConcatFactory.makeConcat) to concatenate.
//
// Main prints:
//   Hello World
//
// Exercises: CONSTANT_InvokeDynamic (tag 18), BootstrapMethods class attribute,
//            CONSTANT_MethodHandle (tag 15, REF_invokeStatic=6),
//            poolMethodHandle, poolInvokeDynamic, emitInvokedynamic.

package Jvm.SelfTestB87

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makeConcatDemoBytes(): List[Byte] {
  val pool = poolNew()

  // StringConcatFactory.makeConcat bootstrap descriptor
  val bsmDesc =
    "(Ljava/lang/invoke/MethodHandles$Lookup;Ljava/lang/String;Ljava/lang/invoke/MethodType;)Ljava/lang/invoke/CallSite;"
  val callSiteDesc = "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;"

  // InvokeDynamic pool entry: bmIdx=0, name="concat", desc=callSiteDesc
  val dynIdx = poolInvokeDynamic(pool, 0, "concat", callSiteDesc)

  // concat(String a, String b)String  — slot 0=a; slot 1=b
  val asm = newAssembler(pool)
  emitAload(asm, 0)
  emitAload(asm, 1)
  emitInvokedynamic(asm, dynIdx)
  emitAreturn(asm)
  val code = assembleCode(asm, 2, 2)
  val attrs: List[Attribute] = newList()
  attrs.add(code)
  val method = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "concat",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;", attrs)

  val methods: List[MethodInfo] = newList()
  methods.add(method)

  // BootstrapMethods class attribute (entry 0 = makeConcat)
  val bootAttr = makeBootstrapMethodsSingle(pool, 6,
    "java/lang/invoke/StringConcatFactory", "makeConcat", bsmDesc)
  val classAttrs: List[Attribute] = newList()
  classAttrs.add(bootAttr)

  val cf = makeClassWithMethodsAndAttrs("ConcatDemo", methods, classAttrs)
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool      = poolNew()
  val asm       = newAssembler(pool)

  val sysOut    = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val printlnS  = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  val concatRef = poolMethodref(pool, "ConcatDemo", "concat",
    "(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;")

  emitGetstatic(asm, sysOut)
  emitPushString(asm, "Hello")
  emitPushString(asm, " World")
  emitInvokestatic(asm, concatRef)
  emitInvokevirtual(asm, printlnS)
  emitReturn(asm)

  val codeAttr = assembleCode(asm, 3, 1)
  val attrs: List[Attribute] = newList()
  attrs.add(codeAttr)
  val mainMethod = makeMethodInfo(ACC_PUBLIC + ACC_STATIC, "main", "([Ljava/lang/String;)V", attrs)
  val methods: List[MethodInfo] = newList()
  methods.add(mainMethod)
  val cf = makeClassWithMethods("Main", methods)
  serializeClassWithPool(cf, pool)
}

func main(): Unit {
  val outDir = "/tmp/lyric-jvm-b87"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val concatDemoBytes = makeConcatDemoBytes()
  val mainBytes       = makeMainClassBytes()

  val concatDemoClass = BuiltClass(binaryName = "ConcatDemo", bytes = concatDemoBytes)
  val mainClass       = BuiltClass(binaryName = "Main",       bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(concatDemoClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB87",
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
