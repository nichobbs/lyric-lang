// FFI example using `extern type` to declare opaque CLR handles,
// then calling extern functions that return / consume them.
//
// `extern type Foo = "Some.Clr.Type"` declares a Lyric-side name
// for a CLR type loaded in the AppDomain — string at the
// declaration site, ordinary Lyric symbol at every use site.
//
// Run: lyric run examples/ffi_datetime.l

package FfiDateTime

extern type DateTime = "System.DateTime"
extern type TimeSpan = "System.TimeSpan"

@externTarget("System.DateTime.UtcNow")
func utcNow(): DateTime = ()

@externTarget("System.DateTime.op_Subtraction")
func subDates(a: in DateTime, b: in DateTime): TimeSpan = ()

@externTarget("System.TimeSpan.TotalMilliseconds")
func tsTotalMillis(t: in TimeSpan): Double = ()

func main(): Unit {
  val a = utcNow()
  // Burn some cycles so the elapsed delta is non-zero, but stay
  // small enough that the Int counter doesn't overflow.
  var i = 0
  while i < 100_000 {
    i += 1
  }
  val b = utcNow()
  val delta = subDates(b, a)
  println("loops = " + i)
  // The exact ms value is non-deterministic; just confirm it
  // produced a Double (it'll print like "12.345" or so).
  val ms = tsTotalMillis(delta)
  if ms >= 0.0 {
    println("non-negative elapsed ms")
  } else {
    println("negative elapsed ms (unexpected)")
  }
}
