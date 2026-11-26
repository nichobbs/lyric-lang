//! nativedtor.l - an opaque type wrapping a raw C handle (`@nativeDtor`) lowered from TIR (docs/70 phase 4a part 8,
//! D856): the record layout carries the destructor that frees the handle first and then releases the reference
//! fields (ARC Rule 7).  `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer, where a missed
//! release, a double release or a release in the wrong order fails the run.
package NativeDtorViaTir

import Std.Core

extern func cStrlen(s: NativePtr[Byte]): Long = "strlen"
extern func toC(s: String): NativePtr[Byte] = "lyric_string_to_cstring"

opaque type CStr @nativeDtor("lyric_cstring_free") {
  p: NativePtr[Byte]
  label: String
}

@unsafe_ffi
func measure(i: in Int): Int {
  val c = CStr(p = toC("handle"), label = "n" + i.toString())
  cStrlen(c.p).toInt() + c.label.length - 6
}

@unsafe_ffi
func main(): Int {
  var total = 0
  var i = 0
  while i < 2000 {
    total = total + measure(i)
    i = i + 1
  }
  if total > 0 {
    0
  } else {
    1
  }
}
