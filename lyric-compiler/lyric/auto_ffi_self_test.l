// auto_ffi_self_test.l — executable regression test for self-hosted
// metadata-based auto-FFI resolution (epic #1622, Phase 3c).
//
// `extern type T = "Foo.Bar"` makes `T.method(args)` resolve to a real
// BCL static method.  The self-hosted MSIL emitter resolves the overload
// from .NET reference-assembly metadata (Msil.MetadataReader) and emits the
// real MemberRef — replacing the legacy `(object...) : void` guess.  This
// file is run by the native `lyric test` (issue #1611), which compiles the
// synthesised program in-process through the self-hosted Msil.Bridge and
// asserts every runtime value, so it exercises the metadata-resolution
// codegen path end-to-end with no new F#.
//
//   lyric test lyric-compiler/lyric/auto_ffi_self_test.l
//
// Coverage is the exact-match static primitive case (the first cut of
// Phase 3c): System.Math overloads on Int arguments.  Argument types whose
// owning assembly is mis-hinted by `clrAssemblyForType`, numeric coercion,
// and instance methods still fall back to `@externTarget` and are not
// exercised here.

@test_module
package Lyric.AutoFfiSelfTest

import Std.Core
import Std.Testing

extern type Math = "System.Math"

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
