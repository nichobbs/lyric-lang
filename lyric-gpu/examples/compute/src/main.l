package Gpu.Examples.Compute

import Std.Console as Console
import Std.Buffer as Buf
import Std.Collections
import Gpu

val shader: String = "@group(0) @binding(0) var<storage, read_write> data: array<i32>;\n@compute @workgroup_size(64)\nfn main(@builtin(global_invocation_id) id: vec3<u32>) {\n  if (id.x < arrayLength(&data)) {\n    data[id.x] = data[id.x] * 2;\n  }\n}\n"

func fail(msg: String): Int {
  Console.println("FAIL: " + msg)
  1
}

func run(d: Gpu.Device): Int {
  val n = 1000
  var input = Buf.filled(n, 0)
  var i = 0
  while i < n {
    input[i] = i
    i = i + 1
  }
  val bytes = n.toLong() * 4
  val buf = Gpu.createBuffer(d, bytes, Gpu.usageStorage + Gpu.usageCopyDst + Gpu.usageCopySrc)
  Gpu.writeInts(d, buf, 0, input)
  val pipeline = match Gpu.createComputePipeline(d, shader, "main") { case Ok(p) -> p; case Err(e) -> return fail(e) }
  val bindings: List[Gpu.Binding] = newList()
  bindings.add(BufferBinding(buffer = buf))
  val group = match Gpu.createBindGroup(d, pipeline, bindings) { case Ok(g) -> g; case Err(e) -> return fail(e) }
  match Gpu.dispatch(d, pipeline, group, 16, 1, 1) {
    case Ok(_) -> ()
    case Err(e) -> return fail(e)
  }
  val result = match Gpu.readInts(d, buf, n) { case Ok(b) -> b; case Err(e) -> return fail(e) }
  var bad = 0
  var k = 0
  while k < n {
    if result[k] != k * 2 {
      bad = bad + 1
    }
    k = k + 1
  }
  // The device's error callback is called long after `withDevice` set it up: a shader that does not compile
  // must come back as an `Err`, not crash.
  match Gpu.createComputePipeline(d, "this is not WGSL", "main") {
    case Ok(_) -> return fail("invalid WGSL was accepted")
    case Err(message) -> Console.println(
      "invalid shader rejected: " +
        (if message.length > 0 then "with a message" else "without a message")
    )
  }
  Console.println("checked " + n.toString() + " values, wrong=" + bad.toString())
  if bad == 0 then 0 else 1
}

func main(): Int {
  val body: (Gpu.Device) -> Int = { d: Gpu.Device -> run(d) }
  match Gpu.withDevice(body) {
    case Err(e) -> fail(e)
    case Ok(rc) -> rc
  }
}
