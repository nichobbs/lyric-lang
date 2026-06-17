//! FFI example using `import extern` to import CLR types directly,
//! then invoking static, instance, operator, and constructor methods.
//!
//! Run: lyric run examples/ffi_datetime.l
package FfiDateTime

import extern System.{ DateTime }
import extern System.Text.{ StringBuilder }

func main(): Unit {
  val a = DateTime.get_UtcNow()
  // Burn some cycles so the elapsed delta is non-zero, but stay
  // small enough that the Int counter doesn't overflow.
  var i = 0
  while i < 100_000 {
    i += 1
  }
  val b = DateTime.get_UtcNow()
  
  // Call static method on DateTime to compare them
  val cmp = DateTime.Compare(b, a)
  println("loops = " + i)
  if cmp >= 0 {
    println("non-negative elapsed time (b >= a)")
  } else {
    println("negative elapsed time (unexpected)")
  }

  // Demonstrate constructor shorthand (.new) on the imported StringBuilder type
  val sb = StringBuilder.new()
  sb.Append("Created a StringBuilder via constructor shorthand!")
  val msg = sb.ToString()
  println(msg)
}


