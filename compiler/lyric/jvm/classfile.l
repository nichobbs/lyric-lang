// jvm/classfile.l — JVM §4 class-file data model and binary serializer.
//
// Provides the record types that describe a Java class (ClassFile, FieldInfo,
// MethodInfo, Attribute) and `serializeClass`, which lowers a ClassFile to a
// `List[Byte]` that the JVM accepts as a valid .class file (Java 21,
// major version 65, big-endian per JVMS §4).
//
// Serialization strategy: two-pass.
//   Pass 1 — intern all symbolic names into the constant pool (idempotent).
//   Pass 2 — emit the class body using the already-interned pool indices.
// The pool is then prepended with its count, followed by the body.
//
// Stage B1: ClassFile model and serializer only.  The Code attribute is
// built externally by Jvm.Bytecode and passed in as a pre-serialised
// List[Byte] inside an Attribute record.

package Jvm.Classfile

import Std.Core
import Std.Collections
import Jvm.Kernel

// ── Access flags (JVMS §4.1, §4.5, §4.6) ────────────────────────────────────
// Bit-mask constants; combine with addition (`+`): `ACC_PUBLIC + ACC_FINAL`.
// All JVMS flag bits are distinct, so addition is equivalent to bitwise-or.

pub val ACC_PUBLIC     : Int = 0x0001
pub val ACC_PRIVATE    : Int = 0x0002
pub val ACC_PROTECTED  : Int = 0x0004
pub val ACC_STATIC     : Int = 0x0008
pub val ACC_FINAL      : Int = 0x0010
pub val ACC_SUPER      : Int = 0x0020   // always set on class_info
pub val ACC_BRIDGE     : Int = 0x0040   // compiler-synthesised bridge method
pub val ACC_VARARGS    : Int = 0x0080
pub val ACC_NATIVE     : Int = 0x0100
pub val ACC_INTERFACE  : Int = 0x0200
pub val ACC_ABSTRACT   : Int = 0x0400
pub val ACC_STRICT     : Int = 0x0800   // strictfp (deprecated in Java 17)
pub val ACC_SYNTHETIC  : Int = 0x1000
pub val ACC_ANNOTATION : Int = 0x2000
pub val ACC_ENUM       : Int = 0x4000
pub val ACC_MODULE     : Int = 0x8000

// ── MethodHandle reference-kind constants (JVMS §5.4.3.5) ───────────────────
pub val REF_GETFIELD          : Int = 1
pub val REF_GETSTATIC         : Int = 2
pub val REF_PUTFIELD          : Int = 3
pub val REF_PUTSTATIC         : Int = 4
pub val REF_INVOKEVIRTUAL     : Int = 5
pub val REF_INVOKESTATIC      : Int = 6
pub val REF_INVOKESPECIAL     : Int = 7
pub val REF_NEWINVOKESPECIAL  : Int = 8
pub val REF_INVOKEINTERFACE   : Int = 9

// ── Data model ───────────────────────────────────────────────────────────────

/// A single class-file attribute.  `bytes` is the raw `attribute_info.info`
/// content (everything after the name_index and length).  The serializer
/// writes name_index (u2) + length (u4) + bytes verbatim.
pub record Attribute {
  name:  String
  bytes: List[Byte]
}

/// A field_info entry (JVMS §4.5).
pub record FieldInfo {
  flags:      Int
  name:       String
  descriptor: String
  attrs:      List[Attribute]
}

/// A method_info entry (JVMS §4.6).
pub record MethodInfo {
  flags:      Int
  name:       String
  descriptor: String
  attrs:      List[Attribute]
}

/// Top-level class-file descriptor (JVMS §4.1).
/// Use `makeClass` / `makeInterface` for common defaults.
pub record ClassFile {
  minorVersion: Int           // 0 for release; 65535 = preview features
  majorVersion: Int           // 65 = Java 21
  flags:        Int           // access_flags bitmask
  thisClass:    String        // internal binary name, e.g. "com/example/Foo"
  superClass:   String        // "" → java/lang/Object for classes; "" for interfaces
  interfaces:   List[String]
  fields:       List[FieldInfo]
  methods:      List[MethodInfo]
  attrs:        List[Attribute]
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

/// Minimum `ClassFile` for a concrete class.
/// Sets minor=0, major=65 (Java 21), ACC_PUBLIC|ACC_SUPER, no interfaces.
pub func makeClass(thisClass: in String): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags        = ACC_PUBLIC + ACC_SUPER,
    thisClass    = thisClass,
    superClass   = "java/lang/Object",
    interfaces   = newList(),
    fields       = newList(),
    methods      = newList(),
    attrs        = newList()
  )
}

/// Minimum `ClassFile` for an interface.
/// Sets ACC_PUBLIC|ACC_INTERFACE|ACC_ABSTRACT, superClass = "java/lang/Object".
pub func makeInterface(thisClass: in String): ClassFile {
  ClassFile(
    minorVersion = 0,
    majorVersion = 65,
    flags        = ACC_PUBLIC + ACC_INTERFACE + ACC_ABSTRACT,
    thisClass    = thisClass,
    superClass   = "java/lang/Object",
    interfaces   = newList(),
    fields       = newList(),
    methods      = newList(),
    attrs        = newList()
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

/// Serialize `cf` to a JVM-loadable byte sequence.
///
/// The returned `List[Byte]` can be written to a `.class` file verbatim.
///
/// Algorithm:
///   1. Build the constant pool by interning all symbolic references.
///   2. Write the pool to a `ByteWriter` (count + entries).
///   3. Write the class body (flags, this/super, interfaces, fields,
///      methods, attributes) to a second `ByteWriter`.
///   4. Concatenate: magic (0xCAFEBABE) + minor + major + pool + body.
pub func serializeClass(cf: in ClassFile): List[Byte] {
  val pool = poolNew()

  // ── Pass 1: populate the constant pool ───────────────────────────────────
  // Pool operations are idempotent (same key → same index), so pass 2
  // can re-call the same pool* functions and get the cached indices.

  val superName = if cf.superClass == "" then "java/lang/Object" else cf.superClass
  val _thisIdx  = poolClass(pool, cf.thisClass)
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
  writerU4(result, 0xCAFEBABE)
  writerU2(result, cf.minorVersion)
  writerU2(result, cf.majorVersion)
  poolWriteTo(pool, result)    // constant_pool_count + entries
  writerAppend(result, body)   // access_flags … attributes
  writerToList(result)
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
  maxStack:   in Int,
  maxLocals:  in Int,
  code:       in List[Byte],
  startPc:    in Int,
  endPc:      in Int,
  handlerPc:  in Int,
  catchType:  in Int
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
