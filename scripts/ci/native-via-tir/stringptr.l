//! stringptr.l - `nativeAddrOf` of a `String` local and `NativePtr[String]` parameters lowered from
//! TIR (docs/70 phase 4a, D537): the standard library's environment kernel writes an owned string
//! through the slot's address, so the bundled `Std.Environment` functions the program calls come
//! from TIR too.  `native-via-tir-e2e.sh` runs it both ways and under AddressSanitizer.
package StringPtrViaTir

import Std.Core
import Std.Environment as Env
import Std.Console as Console

func main(): Unit {
  println(toString(Env.getVarOrDefault("LYRIC_STRINGPTR_UNSET_VAR", "dflt")))
  println(toString(Env.currentDirectory().length > 0))
  Env.setVar("LYRIC_STRINGPTR_VAR", "abc")
  println(Env.getVarOrDefault("LYRIC_STRINGPTR_VAR", "none"))
}
