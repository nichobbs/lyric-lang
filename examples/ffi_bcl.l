//! FFI smoke test: call into the .NET BCL via `@externTarget`.
//!
//! Each `@externTarget("Fully.Qualified.Member")` annotation tells
//! the codegen to resolve the function's body as a direct call to a
//! CLR method or property getter on a type loaded in the current
//! AppDomain.  No manifest / no `--ref` flag is needed for BCL types
//! — they're already loaded by the runtime.
//!
//! Run: lyric run examples/ffi_bcl.l
package FfiBcl

// Property getter on a System.* class.  .NET properties are exposed as
// `get_<Name>` static methods on the declaring type.
@externTarget("System.Environment.get_MachineName")
func machineName(): String = ()

// Static method with a single arg.
@externTarget("System.IO.Directory.Exists")
func directoryExists(path: in String): Bool = ()

// Static getter that doesn't take args.
@externTarget("System.Environment.get_ProcessorCount")
func cpuCount(): Int = ()

func main(): Unit {
  println("machine = " + machineName())
  println("cpus    = " + cpuCount())
  println("/tmp exists = " + directoryExists("/tmp"))
  println("/no-such-path exists = " + directoryExists("/definitely-not-there"))
}
