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
import Std.Testing

extern type Math = "System.Math"

extern type Path = "System.IO.Path"

extern type Ts = "System.TimeSpan"

extern type Typ = "System.Type"

extern type Obj = "System.Object"

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

test "@externTarget with verified signatures compile and run correctly" {
  assertEqualInt(externAbsInt(-12), 12, "externAbsInt(-12)")
  assertEqualInt(externAbsInt(7), 7, "externAbsInt(7)")
  assertEqual(externStrConcat("hello", " world"), "hello world", "externStrConcat")
  assertTrue(externMaxLong(3i64, 9i64) == 9i64, "externMaxLong(3, 9)")
  assertTrue(externMaxLong(100i64, 2i64) == 100i64, "externMaxLong(100, 2)")
}
