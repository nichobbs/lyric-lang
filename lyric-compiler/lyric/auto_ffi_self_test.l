//! auto_ffi_self_test.l — executable regression test for self-hosted
//! metadata-based auto-FFI resolution (epic #1622, Phase 3c).
//!
//! `extern type T = "Foo.Bar"` makes `T.method(args)` resolve to a real
//! BCL static method.  The self-hosted MSIL emitter resolves the overload
//! from .NET reference-assembly metadata (Msil.MetadataReader) and emits the
//! real MemberRef — replacing the legacy `(object...) : void` guess.  This
//! file is run by the native `lyric test` (issue #1611), which compiles the
//! synthesised program in-process through the self-hosted Msil.Bridge and
//! asserts every runtime value, so it exercises the metadata-resolution
//! codegen path end-to-end with no new F#.
//!
//!   lyric test lyric-compiler/lyric/auto_ffi_self_test.l
//!
//! Coverage is the exact-match static primitive case (the first cut of
//! Phase 3c): System.Math overloads on Int arguments.  Argument types whose
//! owning assembly is mis-hinted by `clrAssemblyForType`, numeric coercion,
//! and instance methods still fall back to `@externTarget` and are not
//! exercised here.
@test_module
package Lyric.AutoFfiSelfTest

import Std.Core
import Std.String as Str
import Std.Testing

extern type Math = "System.Math"

extern type Path = "System.IO.Path"

extern type Ts = "System.TimeSpan"

extern type Typ = "System.Type"

extern type Obj = "System.Object"

extern type Enc = "System.Text.Encoding"

// Unquoted dotted path declarations
extern type UnquotedMath = System.Math

extern type UnquotedPath = System.IO.Path

extern type UnquotedObjectEnumerator = System.Text.Json.JsonElement.ObjectEnumerator

test "UnquotedMath and UnquotedPath resolve and compile correctly" {
  assertEqualInt(UnquotedMath.Max(20, 50), 50, "UnquotedMath.Max(20,50)")
  assertEqual(UnquotedPath.GetFileName("/tmp/unquoted.txt"), "unquoted.txt", "UnquotedPath.GetFileName")
}

test "Math.Max binds the int overload" {
  assertEqualInt(Math.Max(2, 5), 5, "Max(2,5)")
  assertEqualInt(Math.Max(10, 3), 10, "Max(10,3)")
}

test "Math.Min binds the int overload" {
  assertEqualInt(Math.Min(10, 3), 3, "Min(10,3)")
  assertEqualInt(Math.Min(2, 5), 2, "Min(2,5)")
}

test "Math.Abs binds the int overload" {
  assertEqualInt(Math.Abs(-7), 7, "Abs(-7)")
  assertEqualInt(Math.Abs(42), 42, "Abs(42)")
}

// Calling both the int and the long overload of the same method in one module
// pins that each gets its own MemberRef: the signature-blob intern key encodes
// the parameter/return element types, so Max(long, long) is not aliased to the
// earlier Max(int, int) blob (regression guard for the overload-key fix).
test "Math.Max int and long overloads get distinct MemberRefs" {
  assertEqualInt(Math.Max(2, 5), 5, "Max(int) = 5")
  assertTrue(Math.Max(2i64, 7i64) == 7i64, "Max(long) = 7")
  assertTrue(Math.Max(100i64, 9i64) == 100i64, "Max(long) = 100")
}

// Phase 3c step 2: `System.IO.Path` is mis-hinted by the legacy
// `clrAssemblyForType` table (→ `System.IO.FileSystem`), but the metadata
// type→assembly index finds its real facade assembly.  Use platform-neutral
// methods to avoid Unix-specific path-separator assumptions in `Path.Combine`
// (backslash on Windows vs. slash on Unix; #1712).
test "System.IO.Path resolves via the metadata type index" {
  assertEqual(Path.GetFileName("/tmp/x.txt"), "x.txt", "GetFileName")
  assertEqual(Path.GetExtension("file.txt"), ".txt", "GetExtension")
}

// Phase 3c step 2b: `System.Math.Sqrt` has only a `(double)` overload, so an
// `Int`/`Long` argument is widened with `conv.r8` before the call (numeric
// coercion).  Sqrt of a perfect square is exact in IEEE 754.
test "auto-FFI widens Int/Long args to a Double parameter" {
  assertTrue(Math.Sqrt(4) == 2.0, "Sqrt(int 4) = 2.0")
  assertTrue(Math.Sqrt(9i64) == 3.0, "Sqrt(long 9) = 3.0")
}

// Phase 3c step 3: value-type parameters and returns.  `TimeSpan.FromMinutes`
// returns a `TimeSpan` value type (resolved to MValueTypeRef from metadata),
// which feeds `TimeSpan.Compare(TimeSpan, TimeSpan): int` — a value-type-in,
// primitive-out round trip resolved entirely from metadata.
test "auto-FFI resolves value-type parameters and returns" {
  assertEqualInt(Ts.Compare(Ts.FromMinutes(5.0), Ts.FromMinutes(3.0)), 1, "Compare(5m, 3m) = 1")
  assertEqualInt(Ts.Compare(Ts.FromMinutes(2.0), Ts.FromMinutes(8.0)), -1, "Compare(2m, 8m) = -1")
  assertEqualInt(Ts.Compare(Ts.FromMinutes(4.0), Ts.FromMinutes(4.0)), 0, "Compare(4m, 4m) = 0")
}

// Phase 3c step 4a: class (reference-type) returns.  `Type.GetType(string): Type`
// returns a reference type — the resolved MemberRef must encode a CLASS return
// (CLASS + TypeRef), not `object`, or it would fail to bind to the real method
// at run time (MissingMethodException).  The returned `Type` flows into
// `Object.ReferenceEquals(object, object): bool`; the runtime unifies `Type`
// instances per type, so a passing assertion proves the class return is a real,
// usable reference.
test "auto-FFI resolves class (reference) returns" {
  assertTrue(
    Obj.ReferenceEquals(Typ.GetType("System.Int32"), Typ.GetType("System.Int32")),
    "GetType yields a usable class reference (same type unified)"
  )
  assertTrue(
    not Obj.ReferenceEquals(Typ.GetType("System.Int32"), Typ.GetType("System.String")),
    "distinct types are distinct references"
  )
}

// Phase 3c step 4b: instance-method dispatch.  `Type.GetType(string): Type`
// returns a class reference; `.ToString()` is an instance method resolved from
// metadata and dispatched via `callvirt` against the real CLR method.  The
// marquee end-to-end path: a class-returning static feeds a receiver-based
// instance call, both resolved entirely from .NET metadata.
test "auto-FFI dispatches instance methods via callvirt" {
  assertEqual(
    Typ.GetType("System.Int32").ToString(),
    "System.Int32",
    "GetType(...).ToString() returns the full type name"
  )
  assertEqual(Typ.GetType("System.String").ToString(), "System.String", "instance dispatch on a different receiver")
}

// Int → object: forces `box int32` before the call.
test "auto-FFI boxes value-type args to object parameters" {
  assertTrue(Obj.Equals(42, 42), "Equals(boxed 42, boxed 42) = true")
  assertTrue(not Obj.Equals(42, 43), "Equals(boxed 42, boxed 43) = false")
  // Long → object: same boxing path with a wider value type (`box int64`).
  assertTrue(Obj.Equals(42i64, 42i64), "Equals(boxed 42L, boxed 42L) = true")
  assertTrue(not Obj.Equals(42i64, 43i64), "Equals(boxed 42L, boxed 43L) = false")
}

// Closes the Phase 3c param/return matrix for instance dispatch: an instance
// method that itself returns a class ref (chaining), and one that takes a
// class-ref parameter.
test "auto-FFI instance dispatch chains class returns and takes class params" {
  // (a) instance method returning a class ref: Type.MakeArrayType(): Type.  The
  //     returned array Type chains into another instance call (ToString()).
  assertEqual(
    Typ.GetType("System.Int32").MakeArrayType().ToString(),
    "System.Int32[]",
    "MakeArrayType() returns a class ref that chains to ToString()"
  )
  // (b) instance method taking a class-ref parameter: Type.IsAssignableFrom(Type): bool.
  assertTrue(
    Typ.GetType("System.Object").IsAssignableFrom(Typ.GetType("System.String")),
    "Object.IsAssignableFrom(String) is true"
  )
  assertTrue(
    not Typ.GetType("System.String").IsAssignableFrom(Typ.GetType("System.Object")),
    "String.IsAssignableFrom(Object) is false"
  )
}

// Phase 4: @externTarget with metadata-verified signature.
// These wrappers declare correct BCL signatures; if F0015 incorrectly fires
// for a valid declaration the test would fail to build.
@externTarget("System.Math.Abs")
@externStatic
func externAbsInt(x: in Int): Int = ()

@externTarget("System.String.Concat")
@externStatic
func externStrConcat(a: in String, b: in String): String = ()

@externTarget("System.Math.Max")
@externStatic
func externMaxLong(a: in Long, b: in Long): Long = ()

// Phase 3c static-class-return path (#1568): an @externStatic wrapper that
// takes a String and returns a class-typed String via the static-method branch
// of buildFfiMethodSigCtx (hasThis = false, class return).  `String.Intern`
// is a deterministic, side-effect-free static that returns its argument when
// the interned form is identical.
@externTarget("System.String.Intern")
@externStatic
func externStrIntern(s: in String): String = ()

test "@externTarget with verified signatures compile and run correctly" {
  assertEqualInt(externAbsInt(-12), 12, "externAbsInt(-12)")
  assertEqualInt(externAbsInt(7), 7, "externAbsInt(7)")
  assertEqual(externStrConcat("hello", " world"), "hello world", "externStrConcat")
  assertTrue(externMaxLong(3i64, 9i64) == 9i64, "externMaxLong(3, 9)")
  assertTrue(externMaxLong(100i64, 2i64) == 100i64, "externMaxLong(100, 2)")
}

// @externStatic + class-typed return: `String.Intern` returns the interned
// String instance.  Exercises the static-method + class-return branch of
// buildFfiMethodSigCtx (r.isStatic and not r.isCtor, class return) end-to-end
// via @externTarget declaration (#1568).
test "@externStatic static method with class-typed return" {
  val interned = externStrIntern("hello-intern")
  assertEqual(interned, "hello-intern", "Intern returns interned value")
}

// Regression for a `resolvedSigToMsil` gap: it had no case for `STSzArray`
// (array-shaped signatures), so a BCL instance method returning an array —
// `Encoding.GetBytes(string): byte[]` — could never be metadata-resolved.
// Two symptoms of the same gap:
//  (a) raw auto-FFI instance-method-call syntax on an extern-typed receiver
//      (`enc.GetBytes(s)`, no `@externTarget` wrapper) fell back to the
//      "no matching instance method found" runtime throw stub;
//  (b) an `@externTarget` wrapper with no explicit `@externInstance`/
//      `@externStatic` hint never got its `emitIsStatic` corrected by the
//      metadata-scored resolution (the return-type conversion silently
//      failed), so it was emitted as a static call with the receiver as an
//      extra parameter — a real `System.MissingMethodException` at runtime
//      (`Encoding.GetBytes(Encoding, String)` instead of the true instance
//      `Encoding.GetBytes(String)`).
@externTarget("System.Text.Encoding.get_UTF8")
func externUtf8Encoding(): Enc = ()

// Deliberately no `@externInstance` hint — this is exactly the shape that
// used to mis-resolve to a static call.
@externTarget("System.Text.Encoding.GetBytes")
func externEncodingGetBytes(e: in Enc, s: in String): slice[Byte] = ()

// #3714: `readNestedClass` and the nested-type `+`-separator path in
// `findTypeDefByFqn` (lyric-compiler/msil/metadata_reader.l) have no test
// coverage. `System.Environment+SpecialFolder` is a nested enum: an AOT-safe,
// dependency-free BCL type that exercises the NestedClass table lookup end to
// end — the enum member field access below (`ApplicationData`) and the
// static method call taking it both require the metadata reader to locate
// the nested TypeDef, not merely parse the declaration string.
extern type SpecialFolder = "System.Environment+SpecialFolder"

@externTarget("System.Environment+SpecialFolder.ApplicationData")
func specialFolderApplicationData(): SpecialFolder = ()

@externTarget("System.Environment.GetFolderPath")
@externStatic
func externGetFolderPath(folder: in SpecialFolder): String = ()

test "auto-FFI resolves a nested BCL type via the `+` separator (#3714)" {
  val path = externGetFolderPath(specialFolderApplicationData())
  assertTrue(path.length >= 0, "GetFolderPath(SpecialFolder.ApplicationData) resolves through the nested TypeDef")
}

test "auto-FFI resolves an instance method with an array-typed return" {
  // (a) raw auto-FFI: call GetBytes directly on the extern-typed receiver.
  val direct = externUtf8Encoding().GetBytes("hi")
  assertEqualInt(direct.count, 2, "GetBytes(\"hi\") via raw auto-FFI returns 2 bytes")
  // (b) @externTarget wrapper with no explicit instance/static hint.
  val viaWrapper = externEncodingGetBytes(externUtf8Encoding(), "hi")
  assertEqualInt(viaWrapper.count, 2, "GetBytes(\"hi\") via unhinted @externTarget wrapper returns 2 bytes")
}

// #5562: instance members INHERITED from a base type resolve through the
// metadata reader's TypeDef Extends-chain walk — `StringWriter` declares
// none of the members below; they live on `System.IO.TextWriter`, one
// assembly-crossing step up the chain (System.Runtime).  Before the walk,
// each of these calls failed the build with "does not match any instance
// method" (and, before #5562's compile-time enforcement, compiled into a
// deferred runtime throw).  `Dispose()` is the exact shape that kept
// `Std.ProcessHost.hostDisposeProc` on an `@externTarget` wrapper
// (`Process.Dispose()` inherited from `System.ComponentModel.Component`).
extern type StringWriter = "System.IO.StringWriter"

extern type MemoryStream = "System.IO.MemoryStream"

// #5605: overloads whose TRAILING params are all defaulted are admitted when
// no exact-arity overload matches, and the emitter synthesizes each unfilled
// default (null for `= null` reference defaults, a zeroed struct for
// `= default`, the Constant-table value for numeric / enum constants).
extern type JsonText = "System.Text.Json.JsonEncodedText"

extern type JsonDoc = "System.Text.Json.JsonDocument"

extern type FileK = "System.IO.File"

extern type StreamReader = "System.IO.StreamReader"

test "auto-FFI fills a trailing optional reference param with null (#5605)" {
  // JsonEncodedText.Encode has NO 1-arg overload — only
  // Encode(String, JavaScriptEncoder = null).  Before #5605 this call failed
  // the build ("does not match any ... method"), which is exactly why
  // Std.Json's hostJsonEscape stayed on an @externTarget wrapper.
  val encoded = JsonText.Encode("hi")
  assertEqual(encoded.ToString(), "hi", "Encode(string) resolves the 2-param overload and passes encoder = null")
}

test "auto-FFI fills a trailing optional struct param with a zeroed default (#5605)" {
  // JsonDocument.Parse(String, JsonDocumentOptions = default): the unfilled
  // options struct is synthesized as its zero bit pattern (ldloca + initobj).
  val doc = JsonDoc.Parse("{\"a\":42}")
  val root = doc.RootElement
  assertEqual(root.GetRawText(), "{\"a\":42}", "Parse(string) resolves with options = default and round-trips")
  doc.Dispose()
}

test "auto-FFI fills trailing optional enum and long constants (#5605)" {
  // File.OpenHandle(String, FileMode = Open, FileAccess = Read,
  // FileShare = Read, FileOptions = None, Long preallocationSize = 0):
  // five unfilled defaults, two of them NON-ZERO enum constants decoded from
  // the Constant table (FileMode.Open = 3, FileAccess.Read = 1) plus an I8
  // constant — the shapes a bare type-default guess would get wrong.
  val tmp = Path.GetTempFileName()
  val handle = FileK.OpenHandle(tmp)
  assertTrue(not handle.IsInvalid, "OpenHandle(path) fills five trailing defaults and opens the file")
  handle.Dispose()
  FileK.Delete(tmp)
}

test "auto-FFI passes a subtype argument where the base class is declared (#5605)" {
  // Stream.CopyTo(Stream): the receiver resolves through the Extends walk
  // (declared on Stream, not MemoryStream) AND the MemoryStream-typed
  // argument upcasts to the Stream-typed parameter via its Extends chain —
  // before #5605 the argument's FQN had to match the parameter exactly.
  val bytes = externUtf8Encoding().GetBytes("hi")
  val src = MemoryStream.new(bytes)
  val dst = MemoryStream.new()
  src.CopyTo(dst)
  val copied = dst.ToArray()
  assertEqualInt(copied.count, 2, "CopyTo copied both bytes through the Stream-typed parameter")
  assertEqualInt(copied[0].toInt(), 104, "first copied byte is 'h'")
  assertEqualInt(copied[1].toInt(), 105, "second copied byte is 'i'")
}

test "exact-arity overload still outranks a trailing-default candidate (#5605)" {
  // StreamReader declares BOTH .ctor(Stream) and the defaulted
  // .ctor(Stream, Encoding = null, Boolean = true, Int32 = -1, Boolean = false):
  // the exact-arity candidate must win (its bonus outranks any prefix match),
  // with the MemoryStream argument upcast to the Stream parameter.  The
  // resolution-level pin that the 1-param ctor was chosen lives in
  // metadata_reader_self_test.l; this asserts the woven end-to-end behaviour.
  val bytes2 = externUtf8Encoding().GetBytes("ok")
  val src2 = MemoryStream.new(bytes2)
  val reader = StreamReader.new(src2)
  assertEqual(reader.ReadToEnd(), "ok", "StreamReader over an upcast MemoryStream reads the content")
  reader.Dispose()
}

test "auto-FFI resolves inherited instance members through the Extends chain" {
  val w = StringWriter.new()
  // Overridden member (declared on StringWriter itself): resolves without
  // the walk — pins that the walk does not disturb the direct case.
  w.Write("probe")
  // Inherited, argument-bearing: TextWriter.WriteLine(string) is not
  // overridden by StringWriter, so resolution must walk to the base
  // TypeDef.  It appends the platform newline, hence startsWith + length.
  w.WriteLine("-line")
  // Inherited, zero-arg void: TextWriter.Flush().
  w.Flush()
  val text = w.ToString()
  assertTrue(Str.startsWith(text, "probe-line"), "Write + inherited WriteLine both reached the writer")
  assertTrue(text.length > 10, "WriteLine appended a newline")
  // Inherited, zero-arg void through IDisposable: TextWriter.Dispose() —
  // the `Process.Dispose()` shape from #5562.
  w.Dispose()
  // Inherited instance PROPERTY getter: Stream.CanTimeout is not overridden
  // by MemoryStream, so the member-read path walks the chain too.
  val ms = MemoryStream.new()
  assertTrue(not ms.CanTimeout, "inherited Stream.CanTimeout getter resolves and reads false")
}

// #5613: an `@externTarget` naming a property INHERITED from a base type —
// `StringWriter.NewLine` is declared on `System.IO.TextWriter`, so the
// getter probe resolves `get_NewLine` through the Extends walk and the
// emitted MemberRef parents on the resolved declaring type (TextWriter)
// rather than the declared target type.
@externTarget("System.IO.StringWriter.NewLine")
@externInstance
func externWriterNewLine(w: in StringWriter): String = ()

test "@externTarget resolves an inherited property through the Extends chain (#5613)" {
  val w = StringWriter.new()
  val nl = externWriterNewLine(w)
  assertTrue(nl.length >= 1, "inherited TextWriter.NewLine getter returns a non-empty line separator")
  w.Dispose()
}
