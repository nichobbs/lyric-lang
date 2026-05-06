// jvm/self_test_b20.l — Stage B20: interface implementation + invokeinterface.
//
// Generates three class files:
//   Printable.class  — interface with abstract print(Ljava/lang/String;)V
//   Printer.class    — concrete class implementing Printable
//   Main.class       — calls Printer.print() via invokeinterface
//
// Exercises: makeInterface, ClassFile with interfaces list, ACC_ABSTRACT
// on interface methods, invokeinterface + argcount, areturn from interface call.

package Jvm.SelfTestB20

import Std.Core
import Std.Collections
import Std.File
import Jvm.Classfile
import Jvm.Bytecode
import Jvm.Driver

func makePrintableBytes(): List[Byte] {
  val pool = poolNew()

  // Abstract method print(Ljava/lang/String;)V — no Code attribute for interface methods.
  val noAttrs: List[Attribute] = newList()
  val printMethod = makeMethodInfo(ACC_PUBLIC + ACC_ABSTRACT, "print", "(Ljava/lang/String;)V", noAttrs)
  val methods: List[MethodInfo] = newList()
  methods.add(printMethod)

  val ifaces: List[String]    = newList()
  val fields: List[FieldInfo] = newList()
  val attrs:  List[Attribute] = newList()
  val cf = ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags        = ACC_PUBLIC + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass    = "Printable",
    superClass   = "java/lang/Object",
    interfaces   = ifaces,
    fields       = fields,
    methods      = methods,
    attrs        = attrs
  )
  serializeClassWithPool(cf, pool)
}

func makePrinterBytes(): List[Byte] {
  val pool = poolNew()

  // <init>()V
  val asmInit = newAssembler(pool)
  val objInit  = poolMethodref(pool, "java/lang/Object", "<init>", "()V")
  emitAload(asmInit, 0)
  emitInvokespecial(asmInit, objInit)
  emitReturn(asmInit)
  val initCode = assembleCode(asmInit, 1, 1)
  val initAttrs: List[Attribute] = newList()
  initAttrs.add(initCode)
  val initMethod = makeMethodInfo(ACC_PUBLIC, "<init>", "()V", initAttrs)

  // print(Ljava/lang/String;)V — getstatic System.out, aload_1, invokevirtual println
  val asmPrint = newAssembler(pool)
  val sysOut   = poolFieldref(pool, "java/lang/System", "out", "Ljava/io/PrintStream;")
  val println_ = poolMethodref(pool, "java/io/PrintStream", "println", "(Ljava/lang/String;)V")
  emitGetstatic(asmPrint, sysOut)
  emitAload(asmPrint, 1)
  emitInvokevirtual(asmPrint, println_)
  emitReturn(asmPrint)
  val printCode = assembleCode(asmPrint, 2, 2)
  val printAttrs: List[Attribute] = newList()
  printAttrs.add(printCode)
  val printMethod = makeMethodInfo(ACC_PUBLIC, "print", "(Ljava/lang/String;)V", printAttrs)

  val methods: List[MethodInfo] = newList()
  methods.add(initMethod)
  methods.add(printMethod)

  val ifaces: List[String]    = newList()
  ifaces.add("Printable")
  val fields: List[FieldInfo] = newList()
  val attrs:  List[Attribute] = newList()

  val cf = ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags        = ACC_PUBLIC + ACC_SUPER,
    thisClass    = "Printer",
    superClass   = "java/lang/Object",
    interfaces   = ifaces,
    fields       = fields,
    methods      = methods,
    attrs        = attrs
  )
  serializeClassWithPool(cf, pool)
}

func makeMainClassBytes(): List[Byte] {
  val pool = poolNew()
  val asm  = newAssembler(pool)

  val printerClass = poolClass(pool, "Printer")
  val printerInit  = poolMethodref(pool, "Printer", "<init>", "()V")
  val printIface   = poolIfaceMethodref(pool, "Printable", "print", "(Ljava/lang/String;)V")

  emitNew(asm, printerClass)
  emitDup(asm)
  emitInvokespecial(asm, printerInit)
  emitPushString(asm, "hello from b20")
  emitInvokeinterface(asm, printIface, 2)
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
  val outDir = "/tmp/lyric-jvm-b20"
  match createDir(outDir) {
    case Ok(_)  -> ()
    case Err(_) -> ()
  }

  val printableBytes = makePrintableBytes()
  val printerBytes   = makePrinterBytes()
  val mainBytes      = makeMainClassBytes()

  val printableClass = BuiltClass(binaryName = "Printable", bytes = printableBytes)
  val printerClass   = BuiltClass(binaryName = "Printer",   bytes = printerBytes)
  val mainClass      = BuiltClass(binaryName = "Main",      bytes = mainBytes)
  val classes: List[BuiltClass] = newList()
  classes.add(printableClass)
  classes.add(printerClass)
  classes.add(mainClass)

  val req = BuildRequest(
    packageName = "Jvm.SelfTestB20",
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
