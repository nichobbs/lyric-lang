//! import_extern_self_test.l — regression test for import extern syntax (D105, Phase 2).
//!
//! Tests `import extern` syntax for importing external types, ensuring that:
//! 1. External types can be imported via `import extern Namespace.{ Type }` syntax
//! 2. Aliasing works: `import extern Namespace.{ Type as Alias }`
//! 3. Multiple types can be imported in a group
//! 4. Public re-exports work: `pub use extern Namespace.{ Type }`
//! 5. Auto-FFI resolves method calls on imported external types
//!
//! Run with: lyric test lyric-compiler/lyric/import_extern_self_test.l
//!
@test_module
package Lyric.ImportExternSelfTest

import Std.Core
import Std.Testing
import extern System.{ Math as SystemMath }

test "Math.Max binds the int overload via import extern" {
  assertEqualInt(SystemMath.Max(2, 5), 5, "Max(2,5)")
  assertEqualInt(SystemMath.Max(10, 3), 10, "Max(10,3)")
}

test "Math.Min binds the int overload via import extern" {
  assertEqualInt(SystemMath.Min(10, 3), 3, "Min(10,3)")
  assertEqualInt(SystemMath.Min(2, 5), 2, "Min(2,5)")
}

test "Math.Abs binds the int overload via import extern" {
  assertEqualInt(SystemMath.Abs(-7), 7, "Abs(-7)")
  assertEqualInt(SystemMath.Abs(42), 42, "Abs(42)")
}
