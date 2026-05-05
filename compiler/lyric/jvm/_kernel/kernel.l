// jvm/_kernel/jvm_io.l — trusted host boundary for JVM class-file emission.
//
// Declares the two opaque BCL handles (`Pool`, `ByteWriter`) and routes all
// mutation operations through `@externTarget` to `Lyric.Stdlib.JvmByteHost`
// and `Lyric.Stdlib.JvmPoolHost`.  Because Lyric record fields are readonly,
// mutable state lives entirely inside the BCL objects; Lyric code only holds
// references and calls these functions.
//
// Internal: only `Jvm.*` packages should import this.

@axiom("JvmByteBuilder and JvmConstantPool conform to their documented contracts")
package Jvm.Kernel

import Std.Core
import Std.Collections

// ── Opaque BCL handle types ───────────────────────────────────────────────────

/// Mutable big-endian byte buffer used to build class-file sections.
/// All state is in-place; the reference held by Lyric code is stable.
extern type ByteWriter = "Lyric.Stdlib.JvmByteBuilder"

/// Mutable JVM constant pool.  Interns strings, numbers, and symbolic
/// references; each intern call returns the 1-based pool index.
/// Long and Double entries consume two consecutive pool slots.
extern type Pool = "Lyric.Stdlib.JvmConstantPool"

// ── ByteWriter operations ─────────────────────────────────────────────────────

/// Construct a fresh, empty `ByteWriter`.
@externTarget("Lyric.Stdlib.JvmByteHost.New")
pub func writerNew(): ByteWriter = ()

/// Append the low byte of `v` (0–255) to `w`.
@externTarget("Lyric.Stdlib.JvmByteHost.AppendByte")
pub func writerByte(w: in ByteWriter, v: in Int): Unit = ()

/// Append a 2-byte big-endian unsigned integer.
@externTarget("Lyric.Stdlib.JvmByteHost.AppendU2Be")
pub func writerU2(w: in ByteWriter, v: in Int): Unit = ()

/// Append a 4-byte big-endian unsigned integer.
@externTarget("Lyric.Stdlib.JvmByteHost.AppendU4Be")
pub func writerU4(w: in ByteWriter, v: in Int): Unit = ()

/// Append an 8-byte big-endian unsigned integer (Long).
@externTarget("Lyric.Stdlib.JvmByteHost.AppendU8Be")
pub func writerU8(w: in ByteWriter, v: in Long): Unit = ()

/// Append a JVMS §4.4.7 modified-UTF-8 encoded string (no length prefix).
@externTarget("Lyric.Stdlib.JvmByteHost.AppendModifiedUtf8")
pub func writerModifiedUtf8(w: in ByteWriter, s: in String): Unit = ()

/// Return the byte length of `s` when encoded as modified UTF-8.
/// Used to compute the u2 length prefix of a Utf8 constant without
/// writing to any buffer.
@externTarget("Lyric.Stdlib.JvmByteHost.ModifiedUtf8Length")
pub func modifiedUtf8Length(w: in ByteWriter, s: in String): Int = ()

/// Append a raw byte array (`slice[Byte]`) to `w`.
@externTarget("Lyric.Stdlib.JvmByteHost.AppendBytes")
pub func writerBytes(w: in ByteWriter, bs: in slice[Byte]): Unit = ()

/// Append a `List[Byte]` to `w`.
@externTarget("Lyric.Stdlib.JvmByteHost.AppendByteList")
pub func writerByteList(w: in ByteWriter, bs: in List[Byte]): Unit = ()

/// Append all bytes from `src` into `w`.
@externTarget("Lyric.Stdlib.JvmByteHost.AppendWriter")
pub func writerAppend(w: in ByteWriter, src: in ByteWriter): Unit = ()

/// Current byte position (number of bytes written so far).
@externTarget("Lyric.Stdlib.JvmByteHost.Position")
pub func writerPos(w: in ByteWriter): Int = ()

/// Patch a previously-written u2 at `offset` with `v`.
@externTarget("Lyric.Stdlib.JvmByteHost.PatchU2Be")
pub func writerPatchU2(w: in ByteWriter, offset: in Int, v: in Int): Unit = ()

/// Patch a previously-written u4 at `offset` with `v`.
@externTarget("Lyric.Stdlib.JvmByteHost.PatchU4Be")
pub func writerPatchU4(w: in ByteWriter, offset: in Int, v: in Int): Unit = ()

/// Materialise all written bytes as a `slice[Byte]`.
@externTarget("Lyric.Stdlib.JvmByteHost.ToBytes")
pub func writerToBytes(w: in ByteWriter): slice[Byte] = ()

/// Materialise all written bytes as a `List[Byte]`.
@externTarget("Lyric.Stdlib.JvmByteHost.ToList")
pub func writerToList(w: in ByteWriter): List[Byte] = ()

// ── Constant-pool operations ──────────────────────────────────────────────────

/// Construct a fresh, empty constant pool (slot 0 is reserved; first
/// usable slot is 1).
@externTarget("Lyric.Stdlib.JvmPoolHost.New")
pub func poolNew(): Pool = ()

/// Intern a JVMS §4.4.7 Utf8 constant.  Returns the 1-based pool index.
/// Idempotent: the same string always yields the same index.
@externTarget("Lyric.Stdlib.JvmPoolHost.Utf8")
pub func poolUtf8(pool: in Pool, s: in String): Int = ()

/// Intern a CONSTANT_Integer (tag 3).
@externTarget("Lyric.Stdlib.JvmPoolHost.Integer")
pub func poolInteger(pool: in Pool, v: in Int): Int = ()

/// Intern a CONSTANT_Long (tag 5); occupies two consecutive pool slots.
@externTarget("Lyric.Stdlib.JvmPoolHost.Long_")
pub func poolLong(pool: in Pool, v: in Long): Int = ()

/// Intern a CONSTANT_Double (tag 6); occupies two consecutive pool slots.
@externTarget("Lyric.Stdlib.JvmPoolHost.Double_")
pub func poolDouble(pool: in Pool, v: in Double): Int = ()

/// Intern a CONSTANT_Class (tag 7).  `name` is the internal binary name
/// (e.g., `"java/lang/Object"`).
@externTarget("Lyric.Stdlib.JvmPoolHost.Class_")
pub func poolClass(pool: in Pool, name: in String): Int = ()

/// Intern a CONSTANT_String (tag 8).
@externTarget("Lyric.Stdlib.JvmPoolHost.String_")
pub func poolString(pool: in Pool, s: in String): Int = ()

/// Intern a CONSTANT_NameAndType (tag 12).
@externTarget("Lyric.Stdlib.JvmPoolHost.NameAndType")
pub func poolNameAndType(pool: in Pool, name: in String, descriptor: in String): Int = ()

/// Intern a CONSTANT_Fieldref (tag 9).
@externTarget("Lyric.Stdlib.JvmPoolHost.Fieldref")
pub func poolFieldref(pool: in Pool, className: in String, name: in String, descriptor: in String): Int = ()

/// Intern a CONSTANT_Methodref (tag 10).
@externTarget("Lyric.Stdlib.JvmPoolHost.Methodref")
pub func poolMethodref(pool: in Pool, className: in String, name: in String, descriptor: in String): Int = ()

/// Intern a CONSTANT_InterfaceMethodref (tag 11).
@externTarget("Lyric.Stdlib.JvmPoolHost.InterfaceMethodref")
pub func poolIfaceMethodref(pool: in Pool, className: in String, name: in String, descriptor: in String): Int = ()

/// Intern a CONSTANT_MethodHandle (tag 15).
/// `refKind` is one of the REF_* constants (1–9; see JVMS §5.4.3.5).
@externTarget("Lyric.Stdlib.JvmPoolHost.MethodHandle")
pub func poolMethodHandle(pool: in Pool, refKind: in Int, className: in String, name: in String, descriptor: in String): Int = ()

/// Intern a CONSTANT_MethodType (tag 16).
@externTarget("Lyric.Stdlib.JvmPoolHost.MethodType")
pub func poolMethodType(pool: in Pool, descriptor: in String): Int = ()

/// Intern a CONSTANT_InvokeDynamic (tag 18).
/// `bmIdx` is the 0-based index into the `BootstrapMethods` attribute.
@externTarget("Lyric.Stdlib.JvmPoolHost.InvokeDynamic")
pub func poolInvokeDynamic(pool: in Pool, bmIdx: in Int, name: in String, descriptor: in String): Int = ()

/// Write `constant_pool_count` (u2) followed by all non-phantom entries
/// to `writer`.  Call this after all pool interns are complete.
@externTarget("Lyric.Stdlib.JvmPoolHost.WriteTo")
pub func poolWriteTo(pool: in Pool, writer: in ByteWriter): Unit = ()

/// Number of valid pool entries (= nextSlot - 1).
@externTarget("Lyric.Stdlib.JvmPoolHost.Count")
pub func poolCount(pool: in Pool): Int = ()
