// book_ch13_ffi_tests.l — Chapter 13: Interoperability and FFI
//
// Verifies the extern type (auto-FFI) feature documented in §13.9.
// The self-hosted MSIL emitter resolves extern type calls against .NET
// reference-assembly metadata at compile time and emits real MemberRefs.
//
// This file is a regression suite ensuring the examples in chapter 13 compile
// and produce correct results. It mirrors the coverage of auto_ffi_self_test.l
// but written as a standalone stdlib test (not a @test_module) so that it is
// discovered by the Expecto runner in StdlibLyricTests.fs.
package Book.Ch13.Ffi.Tests

import Std.Core
import Std.Testing

// ---------------------------------------------------------------------------
// §13.9  extern type — bind a Lyric name to a CLR type
// ---------------------------------------------------------------------------

extern type Math  = "System.Math"
extern type Ts    = "System.TimeSpan"
extern type Typ   = "System.Type"
extern type Obj   = "System.Object"
extern type Env   = "System.Environment"
extern type Path  = "System.IO.Path"

// ---------------------------------------------------------------------------
// Static methods on primitive types
// ---------------------------------------------------------------------------

func testMathMax(): Unit {
  assertEqualInt(Math.Max(2, 5),   5,  "Max(2,5)")
  assertEqualInt(Math.Max(10, 3), 10, "Max(10,3)")
  assertEqualInt(Math.Max(0, 0),   0,  "Max(0,0)")
}

func testMathMin(): Unit {
  assertEqualInt(Math.Min(10, 3), 3, "Min(10,3)")
  assertEqualInt(Math.Min(2, 5),  2, "Min(2,5)")
  assertEqualInt(Math.Min(7, 7),  7, "Min(7,7)")
}

func testMathAbs(): Unit {
  assertEqualInt(Math.Abs(-7),  7,  "Abs(-7)")
  assertEqualInt(Math.Abs(42),  42, "Abs(42)")
  assertEqualInt(Math.Abs(0),   0,  "Abs(0)")
}

// ---------------------------------------------------------------------------
// Int and Long overloads get distinct MemberRefs
// ---------------------------------------------------------------------------

func testIntLongOverloads(): Unit {
  assertEqualInt(Math.Max(2, 5), 5, "Max(int,int)=5")
  assertTrue(Math.Max(2i64, 7i64) == 7i64, "Max(long,long)=7")
  assertTrue(Math.Max(100i64, 9i64) == 100i64, "Max(long,long)=100")
}

// ---------------------------------------------------------------------------
// Numeric widening: Int/Long to Double
// ---------------------------------------------------------------------------

func testAutoWidening(): Unit {
  assertTrue(Math.Sqrt(4) == 2.0,  "Sqrt(int 4)=2.0")
  assertTrue(Math.Sqrt(9) == 3.0,  "Sqrt(int 9)=3.0")
  assertTrue(Math.Sqrt(9i64) == 3.0, "Sqrt(long 9)=3.0")
  assertTrue(Math.Sqrt(16) == 4.0, "Sqrt(int 16)=4.0")
}

// ---------------------------------------------------------------------------
// System.IO.Path — type found via metadata index (facade assembly)
// ---------------------------------------------------------------------------

func testPathCombine(): Unit {
  assertEqual(Path.Combine("/tmp", "x.txt"), "/tmp/x.txt", "Combine(/tmp, x.txt)")
  assertEqual(Path.Combine("a", "b"),        "a/b",        "Combine(a, b)")
}

func testPathGetExtension(): Unit {
  assertEqual(Path.GetExtension("file.txt"),   ".txt", "GetExtension .txt")
  assertEqual(Path.GetExtension("file.tar.gz"), ".gz",  "GetExtension .tar.gz")
}

func testPathGetFileName(): Unit {
  assertEqual(Path.GetFileName("/tmp/file.txt"), "file.txt", "GetFileName")
  assertEqual(Path.GetFileNameWithoutExtension("/tmp/file.txt"), "file", "GetFileNameWithoutExtension")
}

// ---------------------------------------------------------------------------
// Value-type parameters and returns (System.TimeSpan)
// ---------------------------------------------------------------------------

func testTimeSpanCompare(): Unit {
  assertEqualInt(Ts.Compare(Ts.FromMinutes(5.0), Ts.FromMinutes(3.0)),  1, "5m > 3m")
  assertEqualInt(Ts.Compare(Ts.FromMinutes(2.0), Ts.FromMinutes(8.0)), -1, "2m < 8m")
  assertEqualInt(Ts.Compare(Ts.FromMinutes(4.0), Ts.FromMinutes(4.0)),  0, "4m == 4m")
}

func testTimeSpanArithmetic(): Unit {
  // FromHours returns a TimeSpan value type; chain into Compare
  assertEqualInt(Ts.Compare(Ts.FromHours(1.0), Ts.FromMinutes(59.0)), 1, "1h > 59m")
  assertEqualInt(Ts.Compare(Ts.FromSeconds(60.0), Ts.FromMinutes(1.0)), 0, "60s == 1m")
}

// ---------------------------------------------------------------------------
// Class (reference) returns
// ---------------------------------------------------------------------------

func testGetType(): Unit {
  // Type.GetType(string): Type  — class return
  assertTrue(
    Obj.ReferenceEquals(Typ.GetType("System.Int32"), Typ.GetType("System.Int32")),
    "same type is the same reference")
  assertTrue(
    not Obj.ReferenceEquals(Typ.GetType("System.Int32"), Typ.GetType("System.String")),
    "different types are different references")
}

// ---------------------------------------------------------------------------
// Instance-method dispatch (callvirt on class-typed receiver)
// ---------------------------------------------------------------------------

func testInstanceDispatch(): Unit {
  assertEqual(Typ.GetType("System.Int32").ToString(), "System.Int32",
              "GetType.ToString() = full type name")
  assertEqual(Typ.GetType("System.String").ToString(), "System.String",
              "GetType.ToString() on String")
}

func testInstanceChaining(): Unit {
  // MakeArrayType() returns a new Type, then chain ToString()
  assertEqual(Typ.GetType("System.Int32").MakeArrayType().ToString(), "System.Int32[]",
              "MakeArrayType().ToString()")
}

func testInstanceWithClassParam(): Unit {
  // IsAssignableFrom(Type): bool — instance method taking a class-ref param
  assertTrue(
    Typ.GetType("System.Object").IsAssignableFrom(Typ.GetType("System.String")),
    "Object.IsAssignableFrom(String) = true")
  assertTrue(
    not Typ.GetType("System.String").IsAssignableFrom(Typ.GetType("System.Object")),
    "String.IsAssignableFrom(Object) = false")
}

// ---------------------------------------------------------------------------
// Boxing: value-type args to object parameters
// ---------------------------------------------------------------------------

func testBoxing(): Unit {
  assertTrue(Obj.Equals(42, 42),       "Equals(42, 42)=true")
  assertTrue(not Obj.Equals(42, 43),   "Equals(42, 43)=false")
  assertTrue(Obj.Equals(42i64, 42i64), "Equals(42L, 42L)=true")
  assertTrue(not Obj.Equals(42i64, 43i64), "Equals(42L, 43L)=false")
}

func main(): Unit {
  testMathMax()
  testMathMin()
  testMathAbs()
  testIntLongOverloads()
  testAutoWidening()
  testPathCombine()
  testPathGetExtension()
  testPathGetFileName()
  testTimeSpanCompare()
  testTimeSpanArithmetic()
  testGetType()
  testInstanceDispatch()
  testInstanceChaining()
  testInstanceWithClassParam()
  testBoxing()
  println("book_ch13_ffi: ok")
}
