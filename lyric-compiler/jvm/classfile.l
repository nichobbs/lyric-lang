//! jvm/classfile.l — JVM §4 class-file data model and binary serializer.
//!
//! Provides the record types that describe a Java class (ClassFile, FieldInfo,
//! MethodInfo, Attribute) and `serializeClass`, which lowers a ClassFile to a
//! `List[Byte]` that the JVM accepts as a valid .class file (Java 21,
//! major version 65, big-endian per JVMS §4).
//!
//! Serialization strategy: two-pass.
//!   Pass 1 — intern all symbolic names into the constant pool (idempotent).
//!   Pass 2 — emit the class body using the already-interned pool indices.
//! The pool is then prepended with its count, followed by the body.
//!
//! Stage B1: ClassFile model and serializer only.  The Code attribute is
//! built externally by Jvm.Bytecode and passed in as a pre-serialised
//! List[Byte] inside an Attribute record.
package Jvm.Classfile

import Std.Core
import Std.Collections
import Jvm.Kernel

// ── Access flags (JVMS §4.1, §4.5, §4.6) ────────────────────────────────────
// Bit-mask constants; combine with addition (`+`): `ACC_PUBLIC + ACC_FINAL`.
// All JVMS flag bits are distinct, so addition is equivalent to bitwise-or.
pub val ACC_PUBLIC: Int = 0x0001

pub val ACC_PRIVATE: Int = 0x0002

pub val ACC_PROTECTED: Int = 0x0004

pub val ACC_STATIC: Int = 0x0008

pub val ACC_FINAL: Int = 0x0010

pub val ACC_SUPER: Int = 0x0020

// always set on class_info
pub val ACC_BRIDGE: Int = 0x0040

// compiler-synthesised bridge method
pub val ACC_VARARGS: Int = 0x0080

pub val ACC_NATIVE: Int = 0x0100

pub val ACC_INTERFACE: Int = 0x0200

pub val ACC_ABSTRACT: Int = 0x0400

pub val ACC_STRICT: Int = 0x0800

// strictfp (deprecated in Java 17)
pub val ACC_SYNTHETIC: Int = 0x1000

pub val ACC_ANNOTATION: Int = 0x2000

pub val ACC_ENUM: Int = 0x4000

pub val ACC_MODULE: Int = 0x8000

// ── MethodHandle reference-kind constants (JVMS §5.4.3.5) ───────────────────
pub val REF_GETFIELD: Int = 1

pub val REF_GETSTATIC: Int = 2

pub val REF_PUTFIELD: Int = 3

pub val REF_PUTSTATIC: Int = 4

pub val REF_INVOKEVIRTUAL: Int = 5

pub val REF_INVOKESTATIC: Int = 6

pub val REF_INVOKESPECIAL: Int = 7

pub val REF_NEWINVOKESPECIAL: Int = 8

pub val REF_INVOKEINTERFACE: Int = 9

// ── Data model ───────────────────────────────────────────────────────────────
/// A single class-file attribute.  `bytes` is the raw `attribute_info.info`
/// content (everything after the name_index and length).  The serializer
/// writes name_index (u2) + length (u4) + bytes verbatim.
pub record Attribute {
  name: String
  bytes: List[Byte]
}

/// A field_info entry (JVMS §4.5).
pub record FieldInfo {
  flags: Int
  name: String
  descriptor: String
  attrs: List[Attribute]
}

/// A method_info entry (JVMS §4.6).
pub record MethodInfo {
  flags: Int
  name: String
  descriptor: String
  attrs: List[Attribute]
}

/// Top-level class-file descriptor (JVMS §4.1).
/// Use `makeClass` / `makeInterface` for common defaults.
pub record ClassFile {
  minorVersion: Int           // 0 for release; 65535 = preview features
  majorVersion: Int           // 65 = Java 21
  flags: Int           // access_flags bitmask
  thisClass: String        // internal binary name, e.g. "com/example/Foo"
  superClass: String        // "" → java/lang/Object for classes; "" for interfaces
  interfaces: List[String]
  fields: List[FieldInfo]
  methods: List[MethodInfo]
  attrs: List[Attribute]
}

// ── Construction helpers ──────────────────────────────────────────────────────
/// Create an `Attribute` from a `ByteWriter` snapshot.
pub func attrFromWriter(name: in String, w: in ByteWriter): Attribute {
  Attribute(name = name, bytes = writerToList(w))
}

/// Create an `Attribute` from a pre-built `List[Byte]`.
pub func makeAttr(name: in String, bytes: in List[Byte]): Attribute {
  Attribute(name = name, bytes = bytes)
}

/// Create a `MethodInfo`.  Bootstrap-grade factory: lets callers in other
/// packages construct method records without reaching into the imported
/// record table directly (which the Phase-1 emitter doesn't expose).
pub func makeMethodInfo(flags: in Int, name: in String, descriptor: in String, attrs: in List[Attribute]): MethodInfo {
  MethodInfo(flags = flags, name = name, descriptor = descriptor, attrs = attrs)
}

/// Create a `FieldInfo` (companion factory for `makeMethodInfo`).
pub func makeFieldInfo(flags: in Int, name: in String, descriptor: in String, attrs: in List[Attribute]): FieldInfo {
  FieldInfo(flags = flags, name = name, descriptor = descriptor, attrs = attrs)
}

/// Like `makeClass`, but takes the method list directly.  Used by callers
/// in other packages that can't mutate `cf.methods` post-construction
/// (the Phase-1 emitter doesn't support field access on imported records).
pub func makeClassWithMethods(thisClass: in String, methods: in List[MethodInfo]): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = methods,
    attrs = newList()
  )
}

/// Like `makeClassWithMethods` but targets Java 5 (major=49).
/// Java 5 class files do not require StackMapTable attributes, so they can
/// contain conditional branches without pre-computing frame descriptors.
/// Use this for tests that exercise branching before full StackMap support
/// is implemented (tracked in B18+).
pub func makeClassWithMethodsV49(thisClass: in String, methods: in List[MethodInfo]): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 49,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = methods,
    attrs = newList()
  )
}

/// Minimum `ClassFile` for a concrete class.
/// Sets minor=0, major=65 (Java 21), ACC_PUBLIC|ACC_SUPER, no interfaces.
pub func makeClass(thisClass: in String): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = newList(),
    attrs = newList()
  )
}

/// Minimum `ClassFile` for an interface.
/// Sets ACC_PUBLIC|ACC_INTERFACE|ACC_ABSTRACT, superClass = "java/lang/Object".
pub func makeInterface(thisClass: in String): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = newList(),
    attrs = newList()
  )
}

// ── Internal serialization helpers ────────────────────────────────────────────
// Intern an attribute's name and data into the pool (pass 1 only).
func internAttr(attr: in Attribute, pool: in Pool): Unit {
  val _ = poolUtf8(pool, attr.name)
}

// Intern a field's names / descriptors and all its attribute names.
func internField(f: in FieldInfo, pool: in Pool): Unit {
  val _ = poolUtf8(pool, f.name)
  val _ = poolUtf8(pool, f.descriptor)
  for a in f.attrs.toArray() {
    internAttr(a, pool)
  }
}

// Intern a method's names / descriptors and all its attribute names.
func internMethod(m: in MethodInfo, pool: in Pool): Unit {
  val _ = poolUtf8(pool, m.name)
  val _ = poolUtf8(pool, m.descriptor)
  for a in m.attrs.toArray() {
    internAttr(a, pool)
  }
}

// Emit a single attribute to `buf` (pass 2).  The pool index for the name
// is already interned, so poolUtf8 just returns the cached index.
func emitAttr(attr: in Attribute, pool: in Pool, buf: in ByteWriter): Unit {
  writerU2(buf, poolUtf8(pool, attr.name))
  writerU4(buf, attr.bytes.count)
  writerByteList(buf, attr.bytes)
}

// Emit all attributes in a list.
func emitAttrs(attrs: in List[Attribute], pool: in Pool, buf: in ByteWriter): Unit {
  writerU2(buf, attrs.count)
  for a in attrs.toArray() {
    emitAttr(a, pool, buf)
  }
}

// Emit a field_info entry.
func emitField(f: in FieldInfo, pool: in Pool, buf: in ByteWriter): Unit {
  writerU2(buf, f.flags)
  writerU2(buf, poolUtf8(pool, f.name))
  writerU2(buf, poolUtf8(pool, f.descriptor))
  emitAttrs(f.attrs, pool, buf)
}

// Emit a method_info entry.
func emitMethod(m: in MethodInfo, pool: in Pool, buf: in ByteWriter): Unit {
  writerU2(buf, m.flags)
  writerU2(buf, poolUtf8(pool, m.name))
  writerU2(buf, poolUtf8(pool, m.descriptor))
  emitAttrs(m.attrs, pool, buf)
}

// ── Public serializer ─────────────────────────────────────────────────────────
/// Serialize `cf` to a JVM-loadable byte sequence using a caller-supplied pool.
///
/// Use this when methods were assembled via `Jvm.Bytecode.assembleCode` with
/// the same `pool` — the bytecode contains pool indices that must match the
/// class-file constant pool, so both must share one `Pool` object.
///
/// Algorithm:
///   1. Intern all symbolic class-level references into `pool` (idempotent).
///   2. Write the pool to a `ByteWriter` (count + entries).
///   3. Write the class body (flags, this/super, interfaces, fields,
///      methods, attributes) to a second `ByteWriter`.
///   4. Concatenate: magic (0xCAFEBABE) + minor + major + pool + body.
pub func serializeClassWithPool(cf: in ClassFile, pool: in Pool): List[Byte] {
  // ── Pass 1: populate the constant pool ───────────────────────────────────
  // Pool operations are idempotent (same key → same index), so pass 2
  // can re-call the same pool* functions and get the cached indices.

  val superName = if cf.superClass == "" then "java/lang/Object" else cf.superClass
  val _thisIdx = poolClass(pool, cf.thisClass)
  val _superIdx = poolClass(pool, superName)

  for iface in cf.interfaces.toArray() {
    val _ = poolClass(pool, iface)
  }
  for f in cf.fields.toArray() {
    internField(f, pool)
  }
  for m in cf.methods.toArray() {
    internMethod(m, pool)
  }
  for a in cf.attrs.toArray() {
    internAttr(a, pool)
  }

  // ── Pass 2: emit the class body ──────────────────────────────────────────
  val body = writerNew()

  writerU2(body, cf.flags)
  writerU2(body, poolClass(pool, cf.thisClass))
  writerU2(body, poolClass(pool, superName))

  // interfaces
  writerU2(body, cf.interfaces.count)
  for iface in cf.interfaces.toArray() {
    writerU2(body, poolClass(pool, iface))
  }

  // fields
  writerU2(body, cf.fields.count)
  for f in cf.fields.toArray() {
    emitField(f, pool, body)
  }

  // methods
  writerU2(body, cf.methods.count)
  for m in cf.methods.toArray() {
    emitMethod(m, pool, body)
  }

  // class attributes
  emitAttrs(cf.attrs, pool, body)

  // ── Combine header + pool + body ─────────────────────────────────────────
  val result = writerNew()
  // JVM class-file magic number 0xCAFEBABE, written as its signed 32-bit value
  // (-889275714).  The hex literal 0xCAFEBABE (3405691582) exceeds Int32.Max so
  // it is typed `Long`, which does not match `writerU4`'s `Int` parameter across
  // the package boundary in the self-hosted MSIL emitter (the cross-package
  // call-arg `Long -> Int` narrowing does not fire; #3943).  The low 32 bits are
  // identical, so `writerU4` still emits the four bytes 0xCA 0xFE 0xBA 0xBE.
  writerU4(result, -889275714)
  writerU2(result, cf.minorVersion)
  writerU2(result, cf.majorVersion)
  poolWriteTo(pool, result)    // constant_pool_count + entries
  writerAppend(result, body)   // access_flags … attributes
  writerToList(result)
}

/// Serialize `cf` to a JVM-loadable byte sequence with a fresh pool.
///
/// Only correct for classes whose methods carry no `Code` attribute (or whose
/// Code bytes contain no pool references).  For classes with assembled
/// bytecode, use `serializeClassWithPool` and pass the same `Pool` that was
/// given to `Jvm.Bytecode.newAssembler`.
pub func serializeClass(cf: in ClassFile): List[Byte] {
  serializeClassWithPool(cf, poolNew())
}

// ── Attribute builders ────────────────────────────────────────────────────────
/// Build a `SourceFile` attribute.
/// Used to map class files back to source for stack traces.
pub func makeSourceFileAttr(pool: in Pool, fileName: in String): Attribute {
  val w = writerNew()
  writerU2(w, poolUtf8(pool, fileName))
  attrFromWriter("SourceFile", w)
}

/// Build a minimal `Code` attribute (JVMS §4.7.3).
/// `code` is the raw bytecode byte sequence.
/// Exception table and nested attributes are empty (bootstrap-grade).
///   requires: maxStack >= 0
///   requires: maxLocals >= 0
pub func makeCodeAttr(maxStack: in Int, maxLocals: in Int, code: in List[Byte]): Attribute {
  val w = writerNew()
  writerU2(w, maxStack)
  writerU2(w, maxLocals)
  writerU4(w, code.count)      // code_length
  writerByteList(w, code)      // bytecode
  writerU2(w, 0)               // exception_table_length = 0
  writerU2(w, 0)               // attributes_count = 0
  attrFromWriter("Code", w)
}

/// Build a `Code` attribute with an inline exception handler.
/// `handlerPc` and `catchType` are the pool-index for the exception class
/// (0 means catch-all / `finally`).
pub func makeCodeAttrWithHandler(
  maxStack: in Int,
  maxLocals: in Int,
  code: in List[Byte],
  startPc: in Int,
  endPc: in Int,
  handlerPc: in Int,
  catchType: in Int,
): Attribute {
  val w = writerNew()
  writerU2(w, maxStack)
  writerU2(w, maxLocals)
  writerU4(w, code.count)
  writerByteList(w, code)
  writerU2(w, 1)           // exception_table_length = 1
  writerU2(w, startPc)
  writerU2(w, endPc)
  writerU2(w, handlerPc)
  writerU2(w, catchType)
  writerU2(w, 0)           // attributes_count = 0
  attrFromWriter("Code", w)
}

/// Build a `Code` attribute with two exception handlers.
pub func makeCodeAttrWith2Handlers(
  maxStack: in Int,
  maxLocals: in Int,
  code: in List[Byte],
  startPc1: in Int,
  endPc1: in Int,
  handlerPc1: in Int,
  catchType1: in Int,
  startPc2: in Int,
  endPc2: in Int,
  handlerPc2: in Int,
  catchType2: in Int,
): Attribute {
  val w = writerNew()
  writerU2(w, maxStack)
  writerU2(w, maxLocals)
  writerU4(w, code.count)
  writerByteList(w, code)
  writerU2(w, 2)
  writerU2(w, startPc1)
  writerU2(w, endPc1)
  writerU2(w, handlerPc1)
  writerU2(w, catchType1)
  writerU2(w, startPc2)
  writerU2(w, endPc2)
  writerU2(w, handlerPc2)
  writerU2(w, catchType2)
  writerU2(w, 0)
  attrFromWriter("Code", w)
}

/// Build a `Signature` attribute (JVMS §4.7.9) for generic type info.
pub func makeSignatureAttr(pool: in Pool, signature: in String): Attribute {
  val w = writerNew()
  writerU2(w, poolUtf8(pool, signature))
  attrFromWriter("Signature", w)
}

/// Build a `ConstantValue` attribute (JVMS §4.7.2) for static final fields.
/// `valueIdx` is a pool index for Integer, Long, Double, String, or Float.
pub func makeConstantValueAttr(valueIdx: in Int): Attribute {
  val w = writerNew()
  writerU2(w, valueIdx)
  attrFromWriter("ConstantValue", w)
}

/// Build an `Exceptions` attribute (JVMS §4.7.5) listing checked exceptions.
/// `classIndices` is a list of CONSTANT_Class pool indices.
pub func makeExceptionsAttr(classIndices: in List[Int]): Attribute {
  val w = writerNew()
  writerU2(w, classIndices.count)
  for idx in classIndices.toArray() {
    writerU2(w, idx)
  }
  attrFromWriter("Exceptions", w)
}

/// Create a `ClassFile` with explicit fields and methods lists.
/// Defaults: minor=0, major=65, ACC_PUBLIC|ACC_SUPER,
/// superClass=java/lang/Object, no interfaces, no class attributes.
pub func makeClassFull(thisClass: in String, fields: in List[FieldInfo], methods: in List[MethodInfo]): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

/// Create a class with explicit fields, interfaces, and methods.
/// Defaults: minor=0, major=65, ACC_PUBLIC|ACC_SUPER, superClass=java/lang/Object.
pub func makeClassFullWithInterfaces(
  thisClass: in String,
  interfaces: in List[String],
  fields: in List[FieldInfo],
  methods: in List[MethodInfo],
): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = interfaces,
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

/// Create a class that implements one or more interfaces.
pub func makeClassWithInterfaces(
  thisClass: in String, interfaces: in List[String], methods: in List[MethodInfo]
): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = interfaces,
    fields = newList(),
    methods = methods,
    attrs = newList()
  )
}

/// Create an interface ClassFile with the given methods.
/// Uses ACC_PUBLIC|ACC_INTERFACE|ACC_ABSTRACT flags.
pub func makeInterfaceWithMethods(thisClass: in String, methods: in List[MethodInfo]): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = methods,
    attrs = newList()
  )
}

/// Create a class that carries only class-level attributes (no methods, no fields).
/// Useful for attaching custom attributes (e.g. LyricSignature) to a class.
pub func makeClassWithAttrs(thisClass: in String, classAttrs: in List[Attribute]): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = newList(),
    attrs = classAttrs
  )
}

/// Create a class with class-level attributes (e.g. BootstrapMethods).
pub func makeClassWithMethodsAndAttrs(
  thisClass: in String, methods: in List[MethodInfo], classAttrs: in List[Attribute]
): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = methods,
    attrs = classAttrs
  )
}

/// Build a `BootstrapMethods` class-level attribute with a single entry
/// and no static arguments.  `refKind` is typically 6 (REF_invokeStatic).
pub func makeBootstrapMethodsSingle(
  pool: in Pool,
  refKind: in Int,
  className: in String,
  name: in String,
  desc: in String,
): Attribute {
  val w = writerNew()
  val mhIdx = poolMethodHandle(pool, refKind, className, name, desc)
  writerU2(w, 1)       // num_bootstrap_methods
  writerU2(w, mhIdx)   // bootstrap_method_ref
  writerU2(w, 0)       // num_bootstrap_arguments = 0
  attrFromWriter("BootstrapMethods", w)
}

/// Create an abstract class (`ACC_PUBLIC | ACC_SUPER | ACC_ABSTRACT`)
/// with `java/lang/Object` as superclass.  Used as the base of a union hierarchy.
pub func makeAbstractClass(thisClass: in String, fields: in List[FieldInfo], methods: in List[MethodInfo]): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_ABSTRACT,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

/// Create a final class (`ACC_PUBLIC | ACC_SUPER | ACC_FINAL`) with
/// `java/lang/Object` as superclass.  Used for protected types and wire classes.
pub func makeFinalClass(thisClass: in String, fields: in List[FieldInfo], methods: in List[MethodInfo]): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

/// Create a concrete case class that extends `superClass`.
/// Used for individual cases in a union type hierarchy.
pub func makeCaseClass(
  thisClass: in String,
  superClass: in String,
  fields: in List[FieldInfo],
  methods: in List[MethodInfo],
): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER,
    thisClass = thisClass,
    superClass = superClass,
    interfaces = newList(),
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

// ── B111-B116 attribute helpers ───────────────────────────────────────────────
/// Build a `PermittedSubclasses` class-level attribute (JVMS §4.7.31).
/// `caseNames` are the JVM binary names of the permitted subclasses.
pub func makePermittedSubclassesAttr(caseNames: in List[String], pool: in Pool): Attribute {
  val w = writerNew()
  writerU2(w, caseNames.count)
  for name in caseNames.toArray() {
    writerU2(w, poolClass(pool, name))
  }
  attrFromWriter("PermittedSubclasses", w)
}

/// Build a `Record` class-level attribute (JVMS §4.7.30).
/// `fieldNames` and `fieldDescs` must have equal length; each pair is one record component.
pub func makeRecordAttr(fieldNames: in List[String], fieldDescs: in List[String], pool: in Pool): Attribute {
  val w = writerNew()
  writerU2(w, fieldNames.count)   // components_count
  var i = 0
  while i < fieldNames.count {
    writerU2(w, poolUtf8(pool, fieldNames[i]))   // name_index
    writerU2(w, poolUtf8(pool, fieldDescs[i]))   // descriptor_index
    writerU2(w, 0)                               // attributes_count = 0
    i = i + 1
  }
  attrFromWriter("Record", w)
}

/// Build a sealed interface ClassFile with a `PermittedSubclasses` attribute.
pub func makeSealedInterfaceWithMethods(
  thisClass: in String,
  caseNames: in List[String],
  methods: in List[MethodInfo],
  pool: in Pool,
): ClassFile {
  val permAttr = makePermittedSubclassesAttr(caseNames, pool)
  val classAttrs: List[Attribute] = newList()
  classAttrs.add(permAttr)
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = newList(),
    fields = newList(),
    methods = methods,
    attrs = classAttrs
  )
}

/// Build a final record class with a `Record` attribute and unmangled field accessors.
pub func makeRecordClass(
  thisClass: in String,
  fields: in List[FieldInfo],
  methods: in List[MethodInfo],
  recordAttr: in Attribute,
): ClassFile {
  val classAttrs: List[Attribute] = newList()
  classAttrs.add(recordAttr)
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = thisClass,
    superClass = "java/lang/Record",
    interfaces = newList(),
    fields = fields,
    methods = methods,
    attrs = classAttrs
  )
}

/// Build a case class that extends `superClass` and implements `iface`.
pub func makeCaseClassImplementing(
  thisClass: in String,
  superClass: in String,
  iface: in String,
  fields: in List[FieldInfo],
  methods: in List[MethodInfo],
): ClassFile {
  val ifaces: List[String] = newList()
  ifaces.add(iface)
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_SUPER + ACC_FINAL,
    thisClass = thisClass,
    superClass = superClass,
    interfaces = ifaces,
    fields = fields,
    methods = methods,
    attrs = newList()
  )
}

// ── B126 annotation attribute helpers (JVMS §4.7.16, §4.7.22) ────────────────
/// An element_value (JVMS §4.7.16.1).  Covers the tags needed for
/// @LyricTest and the meta-annotations @Retention / @Target.
/// Extend with more cases as new tags are required.
pub union AnnotationElementValue {
  case AEVString(value: String)                                  // tag 's'
  case AEVInt(value: Int)                                        // tag 'I'
  case AEVEnum(typeName: String, constName: String)              // tag 'e'
  // Array of one enum value — covers the @Target({X}) common case without
  // requiring a self-referential union (which the bootstrap emitter cannot
  // handle via Reflection.Emit TypeBuilderInstantiation).
  case AEVSingleEnumArray(typeName: String, constName: String)  // tag '[' num=1 'e' ...
}

/// A single name=value pair inside a RuntimeVisibleAnnotations entry.
pub record AnnotationElement {
  name: String
  value: AnnotationElementValue
}

/// One annotation entry: the field descriptor of the annotation type plus
/// its element_value_pairs.
pub record AnnotationEntry {
  typeDescriptor: String
  elements: List[AnnotationElement]
}

// Emit an element_value to `w` (JVMS §4.7.16.1).
func emitElementValue(ev: in AnnotationElementValue, pool: in Pool, w: in ByteWriter): Unit {
  match ev {
    case AEVString(v) -> {
      writerByte(w, 115)          // tag 's' = 0x73
      writerU2(w, poolUtf8(pool, v))
    }
    case AEVInt(v) -> {
      writerByte(w, 73)           // tag 'I' = 0x49
      writerU2(w, poolInteger(pool, v))
    }
    case AEVEnum(typeName, constName) -> {
      writerByte(w, 101)          // tag 'e' = 0x65
      writerU2(w, poolUtf8(pool, typeName))
      writerU2(w, poolUtf8(pool, constName))
    }
    case AEVSingleEnumArray(typeName, constName) -> {
      writerByte(w, 91)           // tag '[' = 0x5B
      writerU2(w, 1)              // num_values = 1
      writerByte(w, 101)          // tag 'e' = 0x65
      writerU2(w, poolUtf8(pool, typeName))
      writerU2(w, poolUtf8(pool, constName))
    }
  }
}

// Emit one annotation{} struct (JVMS §4.7.16).
func emitAnnotationEntry(ann: in AnnotationEntry, pool: in Pool, w: in ByteWriter): Unit {
  writerU2(w, poolUtf8(pool, ann.typeDescriptor))
  writerU2(w, ann.elements.count)
  var i = 0
  while i < ann.elements.count {
    val elem = ann.elements[i]
    writerU2(w, poolUtf8(pool, elem.name))
    emitElementValue(elem.value, pool, w)
    i = i + 1
  }
}

/// Build a `RuntimeVisibleAnnotations` attribute (JVMS §4.7.16).
/// Place on a method or class to make annotations visible at runtime.
pub func makeRuntimeVisibleAnnotationsAttr(pool: in Pool, annotations: in List[AnnotationEntry]): Attribute {
  val w = writerNew()
  writerU2(w, annotations.count)
  var i = 0
  while i < annotations.count {
    emitAnnotationEntry(annotations[i], pool, w)
    i = i + 1
  }
  attrFromWriter("RuntimeVisibleAnnotations", w)
}

/// Build an `AnnotationDefault` attribute (JVMS §4.7.22).
/// Used on annotation-interface method elements to declare their default value.
pub func makeAnnotationDefaultAttr(pool: in Pool, defaultVal: in AnnotationElementValue): Attribute {
  val w = writerNew()
  emitElementValue(defaultVal, pool, w)
  attrFromWriter("AnnotationDefault", w)
}

/// Create a Java annotation-interface ClassFile.
/// Flags: ACC_PUBLIC | ACC_ANNOTATION | ACC_INTERFACE | ACC_ABSTRACT.
/// Automatically adds `java/lang/annotation/Annotation` to the interfaces list.
/// Pass `methods` = the annotation element method_infos.
/// Pass `classAttrs` = class-level annotations (e.g. @Retention, @Target).
pub func makeAnnotationInterfaceClass(
  thisClass: in String, methods: in List[MethodInfo], classAttrs: in List[Attribute]
): ClassFile {
  val ifaces: List[String] = newList()
  ifaces.add("java/lang/annotation/Annotation")
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags = ACC_PUBLIC + ACC_ANNOTATION + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass = thisClass,
    superClass = "java/lang/Object",
    interfaces = ifaces,
    fields = newList(),
    methods = methods,
    attrs = classAttrs
  )
}

// ── B126 high-level annotation attribute factories ────────────────────────────
//
// These helpers encapsulate the List[AnnotationElement] / List[AnnotationEntry]
// manipulation so callers in other packages (e.g. Jvm.TestEngine) need only
// work with `Attribute`, avoiding cross-package generic instantiation issues in
// the bootstrap emitter's stdlib-artifact compilation path.
/// Build a `RuntimeVisibleAnnotations` attribute carrying one
/// `@Retention(RetentionPolicy.RUNTIME)` annotation.
pub func makeRetentionRVAAttr(pool: in Pool): Attribute {
  val elems: List[AnnotationElement] = newList()
  elems.add(
    AnnotationElement(
      name = "value",
      value = AEVEnum(typeName = "Ljava/lang/annotation/RetentionPolicy;", constName = "RUNTIME")
    )
  )
  val anns: List[AnnotationEntry] = newList()
  anns.add(AnnotationEntry(typeDescriptor = "Ljava/lang/annotation/Retention;", elements = elems))
  makeRuntimeVisibleAnnotationsAttr(pool, anns)
}

/// Build a `RuntimeVisibleAnnotations` attribute carrying one
/// `@Target({ElementType.METHOD})` annotation.
pub func makeTargetRVAAttr(pool: in Pool): Attribute {
  val elems: List[AnnotationElement] = newList()
  elems.add(
    AnnotationElement(
      name = "value",
      value = AEVSingleEnumArray(typeName = "Ljava/lang/annotation/ElementType;", constName = "METHOD")
    )
  )
  val anns: List[AnnotationEntry] = newList()
  anns.add(AnnotationEntry(typeDescriptor = "Ljava/lang/annotation/Target;", elements = elems))
  makeRuntimeVisibleAnnotationsAttr(pool, anns)
}

/// Build a single `RuntimeVisibleAnnotations` attribute carrying both
/// `@Retention(RetentionPolicy.RUNTIME)` and `@Target({ElementType.METHOD})`.
/// The JVM spec requires at most one `RuntimeVisibleAnnotations` attribute per
/// class file element, so callers must not also add the individual helpers.
pub func makeRetentionAndTargetRVAAttr(pool: in Pool): Attribute {
  val retElems: List[AnnotationElement] = newList()
  retElems.add(
    AnnotationElement(
      name = "value",
      value = AEVEnum(typeName = "Ljava/lang/annotation/RetentionPolicy;", constName = "RUNTIME")
    )
  )
  val tgtElems: List[AnnotationElement] = newList()
  tgtElems.add(
    AnnotationElement(
      name = "value",
      value = AEVSingleEnumArray(typeName = "Ljava/lang/annotation/ElementType;", constName = "METHOD")
    )
  )
  val anns: List[AnnotationEntry] = newList()
  anns.add(AnnotationEntry(typeDescriptor = "Ljava/lang/annotation/Retention;", elements = retElems))
  anns.add(AnnotationEntry(typeDescriptor = "Ljava/lang/annotation/Target;", elements = tgtElems))
  makeRuntimeVisibleAnnotationsAttr(pool, anns)
}

/// Build an `AnnotationDefault` attribute whose default value is `""` (String).
/// Convenience wrapper for annotation-element methods returning String.
pub func makeAnnotationDefaultStringAttr(pool: in Pool): Attribute {
  makeAnnotationDefaultAttr(pool, AEVString(value = ""))
}

/// Build an `AnnotationDefault` attribute whose default value is `0` (int).
/// Convenience wrapper for annotation-element methods returning int.
pub func makeAnnotationDefaultIntAttr(pool: in Pool): Attribute {
  makeAnnotationDefaultAttr(pool, AEVInt(value = 0))
}

/// Build a `RuntimeVisibleAnnotations` attribute carrying one
/// `@LyricTest(displayName=..., sourceFile=..., sourceLine=...)` annotation.
/// The annotation type descriptor is `Llyric/runtime/jvm/LyricTest;`.
pub func makeLyricTestRVAAttr(
  pool: in Pool, displayName: in String, sourceFile: in String, sourceLine: in Int
): Attribute {
  val elems: List[AnnotationElement] = newList()
  elems.add(AnnotationElement(name = "displayName", value = AEVString(value = displayName)))
  elems.add(AnnotationElement(name = "sourceFile", value = AEVString(value = sourceFile)))
  elems.add(AnnotationElement(name = "sourceLine", value = AEVInt(value = sourceLine)))
  val anns: List[AnnotationEntry] = newList()
  anns.add(AnnotationEntry(typeDescriptor = "Llyric/runtime/jvm/LyricTest;", elements = elems))
  makeRuntimeVisibleAnnotationsAttr(pool, anns)
}
