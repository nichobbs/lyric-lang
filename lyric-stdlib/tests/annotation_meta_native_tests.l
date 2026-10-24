//! tests/annotation_meta_native_tests.l - Std.AnnotationMeta on the native
//! backend, which embeds no annotation metadata yet (#8524).  Every query
//! must report `Unsupported` rather than an empty list that would be
//! indistinguishable from "no annotated fields"; the pure decoder still works.
@test_module
package Std.AnnotationMeta.NativeTests

import Std.Core
import Std.Collections
import Std.Testing
import Std.AnnotationMeta

test "native queries report Unsupported, not an empty answer" {
  match allAnnotatedFields() {
    case Err(Unsupported(_)) -> ()
    case Err(Malformed(m)) -> assertTrue(false, "expected Unsupported, got Malformed: " + m)
    case Ok(_) -> assertTrue(false, "expected Unsupported, got Ok")
  }
  match fieldsWithAnnotation("secretsManager") {
    case Err(Unsupported(_)) -> ()
    case Err(Malformed(m)) -> assertTrue(false, "expected Unsupported, got Malformed: " + m)
    case Ok(_) -> assertTrue(false, "expected Unsupported, got Ok")
  }
}

test "the pure decoder works on native" {
  match parseAnnotationMeta("[{\"config\":\"C\",\"field\":\"f\",\"annotation\":\"a\",\"args\":[]}]") {
    case Ok(fs) -> assertEqualInt(fs.count, 1, "one field decoded")
    case Err(e) -> assertTrue(false, errorMessage(e))
  }
}
