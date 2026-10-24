//! gpu.l - Gpu: WebGPU compute for `--target native`, over wgpu-native (docs/67 G5).
//!
//! Every GPU object is an opaque `Long` handle inside a record, so no `NativePtr`
//! crosses this package's public surface.  A `Device` owns the instance, adapter,
//! device and queue and lives for one `withDevice` call.  Failures wgpu reports through its
//! uncaptured-error callback are collected on the device and returned as `Err` by the
//! call that caused them.
//!
//! Buffers move data as `buffer[Int]` or `buffer[Byte]`; a compute pass is a pipeline
//! built from WGSL, a bind group of storage buffers, and a workgroup count.
@io
package Gpu

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Encoding
import Std.Ffi as Ffi
import Std.String as Str
import Std.Time as Time
import Gpu.Kernel.Wgpu

/// A GPU device with its queue, ready for buffers and compute passes.
pub record Device {
  instance: Long
  adapter: Long
  device: Long
  queue: Long
  errors: Long
}

/// A GPU buffer and its size in bytes.
pub record Buffer {
  raw: Long
  size: Long
}

/// A compute pipeline built from WGSL.
pub record ComputePipeline {
  raw: Long
}

/// A colour target of `width` by `height` pixels: an offscreen RGBA8 texture, or one frame of a
/// surface (`acquireFrame`).
pub record RenderTarget {
  texture: Long
  view: Long
  width: Int
  height: Int
  format: Int
}

/// A window's drawable surface.  `format` and the size are set by `configureSurface`.
pub record Surface {
  raw: Long
  format: Int
  width: Int
  height: Int
}

/// A render pipeline drawing triangle lists into an RGBA8 target.
pub record RenderPipeline {
  raw: Long
}

/// Buffers, textures and samplers bound to the bindings of group 0 of a pipeline.
pub record BindGroup {
  raw: Long
}

/// An RGBA8 texture to sample in a shader, with its default view.
pub record Texture {
  raw: Long
  view: Long
  width: Int
  height: Int
}

/// How a shader reads a texture: the filter and the edge handling set by `createSampler`.
pub record Sampler {
  raw: Long
}

/// What `@binding(i)` of group 0 is bound to: a uniform or storage buffer, a texture or a sampler.
pub union Binding {
  case BufferBinding(buffer: Buffer)
  case TextureBinding(texture: Texture)
  case SamplerBinding(sampler: Sampler)
}

/// One attribute of a vertex: its format (`vertexFloat32x2` ...), byte offset and `@location`.
pub record VertexAttribute {
  format: Int
  offset: Long
  location: Int
}

/// How one vertex buffer is read: bytes per vertex and the attributes in each.
pub record VertexLayout {
  stride: Long
  attributes: List[VertexAttribute]
}

/// A rectangle of the target in pixels, from its top-left corner.
pub record Scissor {
  x: Int
  y: Int
  width: Int
  height: Int
}

/// One draw: the pipeline, its optional bind group, the vertex buffers (slot i is
/// `vertexBuffers[i]`), the number of vertices, and how many instances of them to draw starting
/// at `firstInstance` (`@builtin(instance_index)` counts from it).  `scissor` clips the draw to
/// a rectangle of the target; `None` draws the whole target.
pub record Draw {
  pipeline: RenderPipeline
  bindGroup: Option[BindGroup]
  vertexBuffers: List[Buffer]
  vertexCount: Int
  instanceCount: Int
  firstInstance: Int
  scissor: Option[Scissor]
}

pub val usageMapRead: Long = 1

pub val usageMapWrite: Long = 2

pub val usageCopySrc: Long = 4

pub val usageCopyDst: Long = 8

pub val usageIndex: Long = 16

pub val usageVertex: Long = 32

pub val usageUniform: Long = 64

pub val usageStorage: Long = 128

/// Where an asynchronous wgpu call leaves its result.
record Slot {
  var status: Int
  var handle: Long
  var message: String
}

pub val formatRgba8: Int = 22

pub val formatBgra8: Int = 27

pub val vertexFloat32: Int = 28

pub val vertexFloat32x2: Int = 29

pub val vertexFloat32x3: Int = 30

pub val vertexFloat32x4: Int = 31

val errorCellSize: Long = 1032

val vertexAttributeSize: Long = 32

val vertexLayoutSize: Long = 40

val bindGroupEntrySize: Long = 56

// How long a wait for a GPU callback may take before it is reported as timed out.
val waitMillis: Long = 30000

@library("c")
@unsafe_ffi
extern func memcpyToLong(dst: NativePtr[Long], src: NativePtr[NativePtr[Byte]], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyToPtr(dst: NativePtr[NativePtr[Byte]], src: NativePtr[Long], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyFromBytes(dst: NativePtr[Int], src: NativePtr[Byte], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyEntry(dst: NativePtr[Byte], src: NativePtr[WGPUBindGroupEntry], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyBytes(dst: NativePtr[Byte], src: NativePtr[Byte], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyIntPointerToLong(dst: NativePtr[Long], src: NativePtr[NativePtr[Int]], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyAttribute(dst: NativePtr[Byte], src: NativePtr[WGPUVertexAttribute], n: Long): NativePtr[Byte] = "memcpy"

@library("c")
@unsafe_ffi
extern func memcpyVertexLayout(dst: NativePtr[Byte], src: NativePtr[WGPUVertexBufferLayout], n: Long): NativePtr[Byte] = "memcpy"

@library("wgpu_native-release")
@unsafe_ffi
extern func wgpuQueueWriteBufferFloats(queue: NativePtr[Byte], buffer: NativePtr[Byte], bufferOffset: Long, data: NativePtr[Float], size: Long): Unit = "wgpuQueueWriteBuffer"

@library("wgpu_native-release")
@unsafe_ffi
extern func wgpuQueueWriteBufferInts(queue: NativePtr[Byte], buffer: NativePtr[Byte], bufferOffset: Long, data: NativePtr[Int], size: Long): Unit = "wgpuQueueWriteBuffer"

@library("wgpu_native-release")
@unsafe_ffi
extern func wgpuQueueWriteBufferBytes(queue: NativePtr[Byte], buffer: NativePtr[Byte], bufferOffset: Long, data: NativePtr[Byte], size: Long): Unit = "wgpuQueueWriteBuffer"

@unsafe_ffi
func ptrToLong(p: NativePtr[Byte]): Long {
  var src = p
  var dst: Long = 0
  val _ = memcpyToLong(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func longToPtr(v: Long): NativePtr[Byte] {
  var src = v
  var dst: NativePtr[Byte] = nativeNullPtr()
  val _ = memcpyToPtr(nativeAddrOf(dst), nativeAddrOf(src), 8)
  dst
}

@unsafe_ffi
func noString(): WGPUStringView {
  WGPUStringView(data = nativeNullPtr(), length = 0)
}

@unsafe_ffi
func cString(p: NativePtr[Byte]): WGPUStringView {
  WGPUStringView(data = p, length = 0 - 1)
}

@unsafe_ffi
func stringOfView(v: WGPUStringView): String {
  if v.data == nativeNullPtr() or v.length <= 0 {
    return ""
  }
  val bytes: List[Byte] = newList()
  var i: Long = 0
  while i < v.length and i < 1000 {
    bytes.add(nativeLoadByte(v.data, i))
    i = i + 1
  }
  match tryDecodeUtf8(bytes.toArray()) {
    case Some(text) -> text
    case None -> ""
  }
}

@unsafe_ffi
func onDeviceLost(device: NativePtr[NativePtr[Byte]], reason: Int, message: WGPUStringView, user: NativePtr[Byte]): Unit {
}

// The uncaptured-error callback keeps the first message of a burst in the device's error
// cell: byte 0 counts the errors, the message is a NUL-terminated string from byte 8.
@unsafe_ffi
func onUncapturedError(
  device: NativePtr[NativePtr[Byte]], kind: Int, message: WGPUStringView, cell: NativePtr[Byte]
): Unit {
  val seen = nativeLoadByte(cell, 0)
  if seen == 0u8 {
    var i: Long = 0
    if message.data != nativeNullPtr() {
      while i < message.length and i < 1000 {
        nativeStoreByte(cell, 8 + i, nativeLoadByte(message.data, i))
        i = i + 1
      }
    }
    nativeStoreByte(cell, 8 + i, 0u8)
  }
  if seen < 255u8 {
    nativeStoreByte(cell, 0, seen + 1u8)
  }
}

@unsafe_ffi
func waitSlot(instance: Long, device: Long, slot: Slot): Bool {
  val deadline = Time.nowEpochMillis() + waitMillis
  while slot.status == 0 - 1 and Time.nowEpochMillis() < deadline {
    wgpuInstanceProcessEvents(longToPtr(instance))
    if device != 0 {
      // Blocks until the submitted work is done, so a slow device (a software
      // rasteriser) is waited for rather than spun past.
      val _ = wgpuDevicePoll(longToPtr(device), 1, nativeNullPtr())
    }
  }
  slot.status != 0 - 1
}

/// The message of the first error the device has reported since the last call, or None.
@unsafe_ffi
pub func takeError(d: Device): Option[String] {
  val cell = longToPtr(d.errors)
  val seen = nativeLoadByte(cell, 0)
  if seen == 0u8 {
    return None
  }
  val text = match Ffi.tryFromCString(longToPtr(d.errors + 8)) { case Some(s) -> s; case None -> "unknown GPU error" }
  nativeStoreByte(cell, 0, 0u8)
  Some(value = text)
}

/// Opens the first available adapter's device and its queue, runs `body` with it, then
/// releases everything.  wgpu keeps the device's error and device-lost callbacks for the
/// device's whole life and native closures are reference-counted, so the device lives only
/// as long as this call: the closures are alive until `body` has returned.
@unsafe_ffi
pub func withDevice[T](body: (Device) -> T): Result[T, String] {
  val inst = wgpuCreateInstance(nativeNullPtr())
  if ptrToLong(inst) == 0 {
    return Err(error = "wgpu: cannot create an instance")
  }
  val instance = ptrToLong(inst)

  val adapterSlot = Slot(status = 0 - 1, handle = 0, message = "")
  val onAdapter: (Int, NativePtr[Byte], WGPUStringView, NativePtr[Byte]) -> Unit = { status: Int, adapter: NativePtr[Byte], message: WGPUStringView, user: NativePtr[Byte] ->
    adapterSlot.handle = ptrToLong(adapter)
    adapterSlot.message = stringOfView(message)
    adapterSlot.status = status
  }
  val adapterInfo = WGPURequestAdapterCallbackInfo(
    nextInChain = nativeNullPtr(),
    mode = WGPUCallbackMode_AllowProcessEvents,
    callback = onAdapter,
    userdata1 = onAdapter,
    userdata2 = nativeNullPtr()
  )
  val _f = wgpuInstanceRequestAdapter(inst, nativeNullPtr(), adapterInfo)
  if not waitSlot(instance, 0, adapterSlot) {
    return Err(error = "wgpu: requesting an adapter timed out")
  }
  if adapterSlot.status != 1 or adapterSlot.handle == 0 {
    return Err(error = "wgpu: no adapter available: " + adapterSlot.message)
  }

  val errorCell = Ffi.allocate(errorCellSize)
  nativeStoreByte(errorCell, 0, 0u8)

  val deviceSlot = Slot(status = 0 - 1, handle = 0, message = "")
  val onDevice: (Int, NativePtr[Byte], WGPUStringView, NativePtr[Byte]) -> Unit = { status: Int, dev: NativePtr[Byte], message: WGPUStringView, user: NativePtr[Byte] ->
    deviceSlot.handle = ptrToLong(dev)
    deviceSlot.message = stringOfView(message)
    deviceSlot.status = status
  }
  val lostCb: (NativePtr[NativePtr[Byte]], Int, WGPUStringView, NativePtr[Byte]) -> Unit = onDeviceLost
  val errCb: (NativePtr[NativePtr[Byte]], Int, WGPUStringView, NativePtr[Byte]) -> Unit = onUncapturedError
  var deviceDesc = WGPUDeviceDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    requiredFeatureCount = 0,
    requiredFeatures = nativeNullPtr(),
    requiredLimits = nativeNullPtr(),
    defaultQueue = WGPUQueueDescriptor(nextInChain = nativeNullPtr(), label = noString()),
    deviceLostCallbackInfo = WGPUDeviceLostCallbackInfo(
      nextInChain = nativeNullPtr(),
      mode = WGPUCallbackMode_AllowSpontaneous,
      callback = lostCb,
      userdata1 = lostCb,
      userdata2 = nativeNullPtr()
    ),
    uncapturedErrorCallbackInfo = WGPUUncapturedErrorCallbackInfo(
      nextInChain = nativeNullPtr(),
      callback = errCb,
      userdata1 = errCb,
      userdata2 = errorCell
    )
  )
  val deviceInfo = WGPURequestDeviceCallbackInfo(
    nextInChain = nativeNullPtr(),
    mode = WGPUCallbackMode_AllowProcessEvents,
    callback = onDevice,
    userdata1 = onDevice,
    userdata2 = nativeNullPtr()
  )
  val _g = wgpuAdapterRequestDevice(longToPtr(adapterSlot.handle), nativeAddrOf(deviceDesc), deviceInfo)
  if not waitSlot(instance, 0, deviceSlot) {
    return Err(error = "wgpu: requesting a device timed out")
  }
  if deviceSlot.status != 1 or deviceSlot.handle == 0 {
    return Err(error = "wgpu: cannot open a device: " + deviceSlot.message)
  }
  val queue = wgpuDeviceGetQueue(longToPtr(deviceSlot.handle))
  val device = Device(
    instance = instance,
    adapter = adapterSlot.handle,
    device = deviceSlot.handle,
    queue = ptrToLong(queue),
    errors = ptrToLong(errorCell)
  )
  val result = body(device)
  closeDevice(device)
  Ok(value = result)
}

/// Releases the device, its queue, the adapter and the instance.
@unsafe_ffi
func closeDevice(d: Device): Unit {
  wgpuQueueRelease(longToPtr(d.queue))
  wgpuDeviceRelease(longToPtr(d.device))
  wgpuAdapterRelease(longToPtr(d.adapter))
  wgpuInstanceRelease(longToPtr(d.instance))
  Ffi.release(longToPtr(d.errors))
}

/// A buffer of `size` bytes with the given usage flags (`usageStorage`, `usageCopyDst`, ...).
@unsafe_ffi
pub func createBuffer(d: Device, size: Long, usage: Long): Buffer {
  var desc = WGPUBufferDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    usage = usage,
    size = size,
    mappedAtCreation = 0
  )
  val raw = wgpuDeviceCreateBuffer(longToPtr(d.device), nativeAddrOf(desc))
  Buffer(raw = ptrToLong(raw), size = size)
}

@unsafe_ffi
pub func releaseBuffer(b: Buffer): Unit {
  wgpuBufferRelease(longToPtr(b.raw))
}

/// Copies `values` into the buffer at `offset` bytes.
@unsafe_ffi
pub func writeInts(d: Device, b: Buffer, offset: Long, values: buffer[Int]): Unit {
  values.withPointer(
    { p: NativePtr[Int] ->
      wgpuQueueWriteBufferInts(longToPtr(d.queue), longToPtr(b.raw), offset, p, values.length.toLong() * 4)
    }
  )
}

/// Copies `values` into the buffer at `offset` bytes.
@unsafe_ffi
pub func writeBytes(d: Device, b: Buffer, offset: Long, values: buffer[Byte]): Unit {
  values.withPointer(
    { p: NativePtr[Byte] ->
      wgpuQueueWriteBufferBytes(longToPtr(d.queue), longToPtr(b.raw), offset, p, values.length.toLong())
    }
  )
}

/// Copies `values` (32-bit floats) into the buffer at `offset` bytes.
@unsafe_ffi
pub func writeFloats(d: Device, b: Buffer, offset: Long, values: buffer[Float]): Unit {
  values.withPointer(
    { p: NativePtr[Float] ->
      wgpuQueueWriteBufferFloats(longToPtr(d.queue), longToPtr(b.raw), offset, p, values.length.toLong() * 4)
    }
  )
}

@unsafe_ffi
func submit(d: Device, encoder: NativePtr[Byte]): Unit {
  var cmd = wgpuCommandEncoderFinish(encoder, nativeNullPtr())
  wgpuQueueSubmit(longToPtr(d.queue), 1, nativeAddrOf(cmd))
  wgpuCommandBufferRelease(cmd)
  wgpuCommandEncoderRelease(encoder)
}

/// Reads `count` Ints from the start of the buffer, which needs `usageCopySrc`.
@unsafe_ffi
pub func readInts(d: Device, b: Buffer, count: Int): Result[buffer[Int], String] {
  val bytes = count.toLong() * 4
  val staging = createBuffer(d, bytes, usageMapRead + usageCopyDst)
  val encoder = wgpuDeviceCreateCommandEncoder(longToPtr(d.device), nativeNullPtr())
  wgpuCommandEncoderCopyBufferToBuffer(encoder, longToPtr(b.raw), 0, longToPtr(staging.raw), 0, bytes)
  submit(d, encoder)
  match takeError(d) {
    case Some(message) -> {
      releaseBuffer(staging)
      return Err(error = message)
    }
    case None -> ()
  }

  val slot = Slot(status = 0 - 1, handle = 0, message = "")
  val onMap: (Int, WGPUStringView, NativePtr[Byte]) -> Unit = { status: Int, message: WGPUStringView, user: NativePtr[Byte] ->
    slot.message = stringOfView(message)
    slot.status = status
  }
  val info = WGPUBufferMapCallbackInfo(
    nextInChain = nativeNullPtr(),
    mode = WGPUCallbackMode_AllowProcessEvents,
    callback = onMap,
    userdata1 = onMap,
    userdata2 = nativeNullPtr()
  )
  val _f = wgpuBufferMapAsync(longToPtr(staging.raw), WGPUMapMode_Read, 0, bytes, info)
  if not waitSlot(d.instance, d.device, slot) {
    releaseBuffer(staging)
    return Err(error = "wgpu: reading a buffer timed out")
  }
  if slot.status != WGPUMapAsyncStatus_Success {
    releaseBuffer(staging)
    return Err(error = "wgpu: cannot map the buffer: " + slot.message)
  }
  var result = Buf.filled(count, 0)
  val source = wgpuBufferGetConstMappedRange(longToPtr(staging.raw), 0, bytes)
  val _c = result.withMutPointer({ p: NativePtr[Int] -> memcpyFromBytes(p, source, bytes) })
  wgpuBufferUnmap(longToPtr(staging.raw))
  releaseBuffer(staging)
  Ok(value = result)
}

/// A compute pipeline for the WGSL `source`'s `entry` point, with its bindings inferred.
@unsafe_ffi
pub func createComputePipeline(d: Device, source: String, entry: String): Result[ComputePipeline, String] {
  val wgsl = Ffi.toCString(source)
  val entryName = Ffi.toCString(entry)
  var chained = WGPUShaderSourceWGSL(
    chain = WGPUChainedStruct(next = nativeNullPtr(), sType = WGPUSType_ShaderSourceWGSL),
    code = cString(wgsl)
  )
  // The chain header is the first member, so the struct's address is its chain's address.
  val chainHead: NativePtr[Byte] = nativeAddrOf(chained)
  var moduleDesc = WGPUShaderModuleDescriptor(nextInChain = chainHead, label = noString())
  val shader = wgpuDeviceCreateShaderModule(longToPtr(d.device), nativeAddrOf(moduleDesc))
  var pipelineDesc = WGPUComputePipelineDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    layout = nativeNullPtr(),
    compute = WGPUComputeState(
      nextInChain = nativeNullPtr(),
      module = shader,
      entryPoint = cString(entryName),
      constantCount = 0,
      constants = nativeNullPtr()
    )
  )
  val pipeline = wgpuDeviceCreateComputePipeline(longToPtr(d.device), nativeAddrOf(pipelineDesc))
  wgpuShaderModuleRelease(shader)
  Ffi.release(wgsl)
  Ffi.release(entryName)
  match takeError(d) {
    case Some(message) -> {
      wgpuComputePipelineRelease(pipeline)
      Err(error = message)
    }
    case None -> Ok(value = ComputePipeline(raw = ptrToLong(pipeline)))
  }
}

@unsafe_ffi
func buildBindGroup(d: Device, layout: NativePtr[Byte], bindings: List[Binding]): Result[BindGroup, String] {
  val count = bindings.count
  val entries = Ffi.allocate(bindGroupEntrySize * count.toLong())
  var i = 0
  while i < count {
    var entry = WGPUBindGroupEntry(
      nextInChain = nativeNullPtr(),
      binding = i,
      buffer = nativeNullPtr(),
      offset = 0,
      size = 0,
      sampler = nativeNullPtr(),
      textureView = nativeNullPtr()
    )
    match bindings[i] {
      case BufferBinding(buffer) -> {
        entry.buffer = longToPtr(buffer.raw)
        entry.size = buffer.size
      }
      case TextureBinding(texture) -> {
        entry.textureView = longToPtr(texture.view)
      }
      case SamplerBinding(sampler) -> {
        entry.sampler = longToPtr(sampler.raw)
      }
    }
    val _m = memcpyEntry(
      longToPtr(ptrToLong(entries) + bindGroupEntrySize * i.toLong()),
      nativeAddrOf(entry),
      bindGroupEntrySize
    )
    i = i + 1
  }
  var desc = WGPUBindGroupDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    layout = layout,
    entryCount = count.toLong(),
    entries = entries
  )
  val group = wgpuDeviceCreateBindGroup(longToPtr(d.device), nativeAddrOf(desc))
  wgpuBindGroupLayoutRelease(layout)
  Ffi.release(entries)
  match takeError(d) {
    case Some(message) -> {
      wgpuBindGroupRelease(group)
      Err(error = message)
    }
    case None -> Ok(value = BindGroup(raw = ptrToLong(group)))
  }
}

/// Binds `bindings[i]` to `@binding(i)` of group 0 of the compute pipeline.
@unsafe_ffi
pub func createBindGroup(d: Device, pipeline: ComputePipeline, bindings: List[Binding]): Result[BindGroup, String] {
  buildBindGroup(d, wgpuComputePipelineGetBindGroupLayout(longToPtr(pipeline.raw), 0), bindings)
}

/// Binds `bindings[i]` to `@binding(i)` of group 0 of the render pipeline.
@unsafe_ffi
pub func createRenderBindGroup(d: Device, pipeline: RenderPipeline, bindings: List[Binding]): Result[BindGroup, String] {
  buildBindGroup(d, wgpuRenderPipelineGetBindGroupLayout(longToPtr(pipeline.raw), 0), bindings)
}

/// Runs the pipeline over `x * y * z` workgroups with the bind group, waiting for the queue.
@unsafe_ffi
pub func dispatch(d: Device, pipeline: ComputePipeline, group: BindGroup, x: Int, y: Int, z: Int): Result[Unit, String] {
  val encoder = wgpuDeviceCreateCommandEncoder(longToPtr(d.device), nativeNullPtr())
  val pass = wgpuCommandEncoderBeginComputePass(encoder, nativeNullPtr())
  wgpuComputePassEncoderSetPipeline(pass, longToPtr(pipeline.raw))
  wgpuComputePassEncoderSetBindGroup(pass, 0, longToPtr(group.raw), 0, nativeNullPtr())
  wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, z)
  wgpuComputePassEncoderEnd(pass)
  wgpuComputePassEncoderRelease(pass)
  submit(d, encoder)
  match takeError(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = ())
  }
}

@unsafe_ffi
pub func releasePipeline(p: ComputePipeline): Unit {
  wgpuComputePipelineRelease(longToPtr(p.raw))
}

@unsafe_ffi
pub func releaseBindGroup(g: BindGroup): Unit {
  wgpuBindGroupRelease(longToPtr(g.raw))
}

/// An RGBA8 colour target that a render pass can draw into and `readPixels` can read.
@unsafe_ffi
pub func createRenderTarget(d: Device, width: Int, height: Int): RenderTarget {
  var desc = WGPUTextureDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    usage = WGPUTextureUsage_RenderAttachment + WGPUTextureUsage_CopySrc,
    dimension = WGPUTextureDimension_2D,
    size = WGPUExtent3D(width = width, height = height, depthOrArrayLayers = 1),
    format = WGPUTextureFormat_RGBA8Unorm,
    mipLevelCount = 1,
    sampleCount = 1,
    viewFormatCount = 0,
    viewFormats = nativeNullPtr()
  )
  val texture = wgpuDeviceCreateTexture(longToPtr(d.device), nativeAddrOf(desc))
  val view = wgpuTextureCreateView(texture, nativeNullPtr())
  RenderTarget(
    texture = ptrToLong(texture),
    view = ptrToLong(view),
    width = width,
    height = height,
    format = WGPUTextureFormat_RGBA8Unorm
  )
}

@unsafe_ffi
pub func releaseRenderTarget(t: RenderTarget): Unit {
  wgpuTextureViewRelease(longToPtr(t.view))
  wgpuTextureRelease(longToPtr(t.texture))
}

/// A pipeline from one WGSL module's vertex and fragment entry points that draws triangle
/// lists into targets of `format` (`formatRgba8` for `createRenderTarget`, `Surface.format` for
/// a surface's frames).  `layouts[i]` describes vertex buffer slot i; an empty list is a
/// shader that generates its positions from `@builtin(vertex_index)`.  With `blend`, the
/// fragment output is composited over the target as premultiplied alpha (`src + dst * (1 - src.a)`);
/// without it the output replaces the target's pixel.
@unsafe_ffi
pub func createRenderPipeline(
  d: Device,
  source: String,
  vertexEntry: String,
  fragmentEntry: String,
  layouts: List[VertexLayout],
  format: Int,
  blend: Bool,
): Result[RenderPipeline, String] {
  val wgsl = Ffi.toCString(source)
  val vertexName = Ffi.toCString(vertexEntry)
  val fragmentName = Ffi.toCString(fragmentEntry)
  var chained = WGPUShaderSourceWGSL(
    chain = WGPUChainedStruct(next = nativeNullPtr(), sType = WGPUSType_ShaderSourceWGSL),
    code = cString(wgsl)
  )
  val chainHead: NativePtr[Byte] = nativeAddrOf(chained)
  var moduleDesc = WGPUShaderModuleDescriptor(nextInChain = chainHead, label = noString())
  val shader = wgpuDeviceCreateShaderModule(longToPtr(d.device), nativeAddrOf(moduleDesc))
  val layoutCount = layouts.count
  val layoutArray = Ffi.allocate(vertexLayoutSize * (if layoutCount > 0 then layoutCount.toLong() else 1))
  val attributeArrays: List[Long] = newList()
  var li = 0
  while li < layoutCount {
    val attributeCount = layouts[li].attributes.count
    val attributeArray = Ffi.allocate(vertexAttributeSize * (if attributeCount > 0 then attributeCount.toLong() else 1))
    attributeArrays.add(ptrToLong(attributeArray))
    var ai = 0
    while ai < attributeCount {
      var attribute = WGPUVertexAttribute(
        nextInChain = nativeNullPtr(),
        format = layouts[li].attributes[ai].format,
        offset = layouts[li].attributes[ai].offset,
        shaderLocation = layouts[li].attributes[ai].location
      )
      val _a = memcpyAttribute(
        longToPtr(ptrToLong(attributeArray) + vertexAttributeSize * ai.toLong()),
        nativeAddrOf(attribute),
        vertexAttributeSize
      )
      ai = ai + 1
    }
    var layoutEntry = WGPUVertexBufferLayout(
      nextInChain = nativeNullPtr(),
      stepMode = WGPUVertexStepMode_Vertex,
      arrayStride = layouts[li].stride,
      attributeCount = attributeCount.toLong(),
      attributes = attributeArray
    )
    val _l = memcpyVertexLayout(
      longToPtr(ptrToLong(layoutArray) + vertexLayoutSize * li.toLong()),
      nativeAddrOf(layoutEntry),
      vertexLayoutSize
    )
    li = li + 1
  }
  var blendState = WGPUBlendState(
    color = WGPUBlendComponent(
      operation = WGPUBlendOperation_Add,
      srcFactor = WGPUBlendFactor_One,
      dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
    ),
    alpha = WGPUBlendComponent(
      operation = WGPUBlendOperation_Add,
      srcFactor = WGPUBlendFactor_One,
      dstFactor = WGPUBlendFactor_OneMinusSrcAlpha
    )
  )
  var target = WGPUColorTargetState(
    nextInChain = nativeNullPtr(),
    format = format,
    blend = if blend { nativeAddrOf(blendState) } else { nativeNullPtr() },
    writeMask = WGPUColorWriteMask_All
  )
  var fragment = WGPUFragmentState(
    nextInChain = nativeNullPtr(),
    module = shader,
    entryPoint = cString(fragmentName),
    constantCount = 0,
    constants = nativeNullPtr(),
    targetCount = 1,
    targets = nativeAddrOf(target)
  )
  var desc = WGPURenderPipelineDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    layout = nativeNullPtr(),
    vertex = WGPUVertexState(
      nextInChain = nativeNullPtr(),
      module = shader,
      entryPoint = cString(vertexName),
      constantCount = 0,
      constants = nativeNullPtr(),
      bufferCount = layoutCount.toLong(),
      buffers = layoutArray
    ),
    primitive = WGPUPrimitiveState(
      nextInChain = nativeNullPtr(),
      topology = WGPUPrimitiveTopology_TriangleList,
      stripIndexFormat = 0,
      frontFace = WGPUFrontFace_CCW,
      cullMode = WGPUCullMode_None,
      unclippedDepth = 0
    ),
    depthStencil = nativeNullPtr(),
    multisample = WGPUMultisampleState(
      nextInChain = nativeNullPtr(),
      count = 1,
      mask = 0 - 1,
      alphaToCoverageEnabled = 0
    ),
    fragment = nativeAddrOf(fragment)
  )
  val pipeline = wgpuDeviceCreateRenderPipeline(longToPtr(d.device), nativeAddrOf(desc))
  wgpuShaderModuleRelease(shader)
  Ffi.release(wgsl)
  Ffi.release(vertexName)
  Ffi.release(fragmentName)
  Ffi.release(layoutArray)
  for address in attributeArrays {
    Ffi.release(longToPtr(address))
  }
  match takeError(d) {
    case Some(message) -> {
      wgpuRenderPipelineRelease(pipeline)
      Err(error = message)
    }
    case None -> Ok(value = RenderPipeline(raw = ptrToLong(pipeline)))
  }
}

@unsafe_ffi
pub func releaseRenderPipeline(p: RenderPipeline): Unit {
  wgpuRenderPipelineRelease(longToPtr(p.raw))
}

/// Clears the target to (`red`, `green`, `blue`, `alpha`) and runs the draws in order.  A
/// scissor must lie inside the target.
@unsafe_ffi
pub func render(
  d: Device, target: RenderTarget, red: Float, green: Float, blue: Float, alpha: Float, draws: List[Draw]
): Result[Unit, String] {
  val encoder = wgpuDeviceCreateCommandEncoder(longToPtr(d.device), nativeNullPtr())
  var attachment = WGPURenderPassColorAttachment(
    nextInChain = nativeNullPtr(),
    view = longToPtr(target.view),
    depthSlice = 0 - 1,
    resolveTarget = nativeNullPtr(),
    loadOp = WGPULoadOp_Clear,
    storeOp = WGPUStoreOp_Store,
    clearValue = WGPUColor(r = red, g = green, b = blue, a = alpha)
  )
  var passDesc = WGPURenderPassDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    colorAttachmentCount = 1,
    colorAttachments = nativeAddrOf(attachment),
    depthStencilAttachment = nativeNullPtr(),
    occlusionQuerySet = nativeNullPtr(),
    timestampWrites = nativeNullPtr()
  )
  val pass = wgpuCommandEncoderBeginRenderPass(encoder, nativeAddrOf(passDesc))
  for draw in draws {
    wgpuRenderPassEncoderSetPipeline(pass, longToPtr(draw.pipeline.raw))
    match draw.bindGroup {
      case Some(group) -> wgpuRenderPassEncoderSetBindGroup(pass, 0, longToPtr(group.raw), 0, nativeNullPtr())
      case None -> ()
    }
    var slot = 0
    while slot < draw.vertexBuffers.count {
      val buffer = draw.vertexBuffers[slot]
      wgpuRenderPassEncoderSetVertexBuffer(pass, slot, longToPtr(buffer.raw), 0, buffer.size)
      slot = slot + 1
    }
    match draw.scissor {
      case Some(r) -> wgpuRenderPassEncoderSetScissorRect(pass, r.x, r.y, r.width, r.height)
      case None -> wgpuRenderPassEncoderSetScissorRect(pass, 0, 0, target.width, target.height)
    }
    wgpuRenderPassEncoderDraw(pass, draw.vertexCount, draw.instanceCount, 0, draw.firstInstance)
  }
  wgpuRenderPassEncoderEnd(pass)
  wgpuRenderPassEncoderRelease(pass)
  submit(d, encoder)
  match takeError(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = ())
  }
}

@unsafe_ffi
func writePixels(d: Device, texture: NativePtr[Byte], width: Int, height: Int, pixels: buffer[Byte]): Unit {
  var destination = WGPUTexelCopyTextureInfo(
    texture = texture,
    mipLevel = 0,
    origin = WGPUOrigin3D(x = 0, y = 0, z = 0),
    aspect = WGPUTextureAspect_All
  )
  var layout = WGPUTexelCopyBufferLayout(offset = 0, bytesPerRow = width * 4, rowsPerImage = height)
  var size = WGPUExtent3D(width = width, height = height, depthOrArrayLayers = 1)
  val destinationAddress = ptrToLong(nativeAddrOf(destination))
  val layoutAddress = ptrToLong(nativeAddrOf(layout))
  val sizeAddress = ptrToLong(nativeAddrOf(size))
  val queue = d.queue
  val bytes = pixels.length.toLong()
  pixels.withPointer(
    { p: NativePtr[Byte] ->
      wgpuQueueWriteTexture(
        longToPtr(queue),
        longToPtr(destinationAddress),
        p,
        bytes,
        longToPtr(layoutAddress),
        longToPtr(sizeAddress)
      )
    }
  )
}

/// An RGBA8 texture of `width` by `height` pixels holding `pixels` (tightly packed rows, top
/// row first), ready to bind with `TextureBinding`.
@unsafe_ffi
pub func createTexture(d: Device, width: Int, height: Int, pixels: buffer[Byte]): Result[Texture, String] {
  if width <= 0 or height <= 0 {
    return Err(error = "a texture needs a positive size, not " + width.toString() + "x" + height.toString())
  }
  val needed = width.toLong() * height.toLong() * 4
  if pixels.length.toLong() != needed {
    return Err(
      error = "a " + width.toString() + "x" + height.toString() + " RGBA8 texture needs " + needed.toString() +
        " bytes, not " +
        pixels.length.toString()
    )
  }
  var desc = WGPUTextureDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    usage = WGPUTextureUsage_TextureBinding + WGPUTextureUsage_CopyDst,
    dimension = WGPUTextureDimension_2D,
    size = WGPUExtent3D(width = width, height = height, depthOrArrayLayers = 1),
    format = WGPUTextureFormat_RGBA8Unorm,
    mipLevelCount = 1,
    sampleCount = 1,
    viewFormatCount = 0,
    viewFormats = nativeNullPtr()
  )
  val texture = wgpuDeviceCreateTexture(longToPtr(d.device), nativeAddrOf(desc))
  writePixels(d, texture, width, height, pixels)
  val view = wgpuTextureCreateView(texture, nativeNullPtr())
  match takeError(d) {
    case Some(message) -> {
      wgpuTextureViewRelease(view)
      wgpuTextureRelease(texture)
      Err(error = message)
    }
    case None -> Ok(value = Texture(raw = ptrToLong(texture), view = ptrToLong(view), width = width, height = height))
  }
}

@unsafe_ffi
pub func releaseTexture(t: Texture): Unit {
  wgpuTextureViewRelease(longToPtr(t.view))
  wgpuTextureRelease(longToPtr(t.raw))
}

/// Replaces every pixel of `t` with `pixels` (tightly packed rows, top row first), for a texture
/// whose contents change, such as a glyph atlas.  The count must be the texture's own size.
@unsafe_ffi
pub func writeTexture(d: Device, t: Texture, pixels: buffer[Byte]): Result[Unit, String] {
  val needed = t.width.toLong() * t.height.toLong() * 4
  if pixels.length.toLong() != needed {
    return Err(
      error = "a " + t.width.toString() + "x" + t.height.toString() + " RGBA8 texture needs " + needed.toString() +
        " bytes, not " +
        pixels.length.toString()
    )
  }
  writePixels(d, longToPtr(t.raw), t.width, t.height, pixels)
  match takeError(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = ())
  }
}

/// A sampler that clamps to the texture's edge and filters linearly (`linear`) or takes the
/// nearest texel.
@unsafe_ffi
pub func createSampler(d: Device, linear: Bool): Sampler {
  val filter = if linear then WGPUFilterMode_Linear else WGPUFilterMode_Nearest
  var desc = WGPUSamplerDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    addressModeU = WGPUAddressMode_ClampToEdge,
    addressModeV = WGPUAddressMode_ClampToEdge,
    addressModeW = WGPUAddressMode_ClampToEdge,
    magFilter = filter,
    minFilter = filter,
    mipmapFilter = WGPUMipmapFilterMode_Nearest,
    lodMinClamp = 0.0f32,
    lodMaxClamp = 32.0f32,
    compare = WGPUCompareFunction_Undefined,
    maxAnisotropy = [1u8, 0u8]
  )
  Sampler(raw = ptrToLong(wgpuDeviceCreateSampler(longToPtr(d.device), nativeAddrOf(desc))))
}

@unsafe_ffi
pub func releaseSampler(s: Sampler): Unit {
  wgpuSamplerRelease(longToPtr(s.raw))
}

/// The target's pixels as tightly packed RGBA8 rows, top row first.
@unsafe_ffi
pub func readPixels(d: Device, target: RenderTarget): Result[buffer[Byte], String] {
  val rowBytes = target.width * 4
  val paddedRow = (rowBytes + 255) / 256 * 256
  val staging = createBuffer(d, paddedRow.toLong() * target.height.toLong(), usageMapRead + usageCopyDst)
  val encoder = wgpuDeviceCreateCommandEncoder(longToPtr(d.device), nativeNullPtr())
  var source = WGPUTexelCopyTextureInfo(
    texture = longToPtr(target.texture),
    mipLevel = 0,
    origin = WGPUOrigin3D(x = 0, y = 0, z = 0),
    aspect = WGPUTextureAspect_All
  )
  var destination = WGPUTexelCopyBufferInfo(
    layout = WGPUTexelCopyBufferLayout(
      offset = 0,
      bytesPerRow = paddedRow,
      rowsPerImage = target.height
    ),
    buffer = longToPtr(staging.raw)
  )
  var size = WGPUExtent3D(width = target.width, height = target.height, depthOrArrayLayers = 1)
  wgpuCommandEncoderCopyTextureToBuffer(encoder, nativeAddrOf(source), nativeAddrOf(destination), nativeAddrOf(size))
  submit(d, encoder)
  match takeError(d) {
    case Some(message) -> {
      releaseBuffer(staging)
      return Err(error = message)
    }
    case None -> ()
  }

  val slot = Slot(status = 0 - 1, handle = 0, message = "")
  val onMap: (Int, WGPUStringView, NativePtr[Byte]) -> Unit = { status: Int, message: WGPUStringView, user: NativePtr[Byte] ->
    slot.message = stringOfView(message)
    slot.status = status
  }
  val info = WGPUBufferMapCallbackInfo(
    nextInChain = nativeNullPtr(),
    mode = WGPUCallbackMode_AllowProcessEvents,
    callback = onMap,
    userdata1 = onMap,
    userdata2 = nativeNullPtr()
  )
  val _f = wgpuBufferMapAsync(longToPtr(staging.raw), WGPUMapMode_Read, 0, staging.size, info)
  if not waitSlot(d.instance, d.device, slot) {
    releaseBuffer(staging)
    return Err(error = "wgpu: reading the target timed out")
  }
  if slot.status != WGPUMapAsyncStatus_Success {
    releaseBuffer(staging)
    return Err(error = "wgpu: cannot map the staging buffer: " + slot.message)
  }
  var pixels = Buf.filled(rowBytes * target.height, 0u8)
  val mapped = ptrToLong(wgpuBufferGetConstMappedRange(longToPtr(staging.raw), 0, staging.size))
  var row = 0
  while row < target.height {
    val srcRow = longToPtr(mapped + paddedRow.toLong() * row.toLong())
    val rowOffset = rowBytes.toLong() * row.toLong()
    val _c = pixels.withMutPointer(
      { p: NativePtr[Byte] -> memcpyBytes(longToPtr(ptrToLong(p) + rowOffset), srcRow, rowBytes.toLong()) }
    )
    row = row + 1
  }
  wgpuBufferUnmap(longToPtr(staging.raw))
  releaseBuffer(staging)
  Ok(value = pixels)
}

@unsafe_ffi
func finishSurface(d: Device, raw: NativePtr[Byte]): Result[Surface, String] {
  match takeError(d) {
    case Some(message) -> {
      wgpuSurfaceRelease(raw)
      Err(error = message)
    }
    case None -> if ptrToLong(raw) == 0 {
      Err(error = "wgpu could not create a surface for this window")
    } else {
      Ok(value = Surface(raw = ptrToLong(raw), format = 0, width = 0, height = 0))
    }
  }
}

/// A surface for an X11 window: `display` is the `Display*` and `window` the window id, as
/// `Window.nativeWindow` returns them.  The device's adapter must be able to present to it, which
/// holds on a machine with one GPU or a software Vulkan device.
@unsafe_ffi
pub func createXlibSurface(d: Device, display: Long, window: Long): Result[Surface, String] {
  var source = WGPUSurfaceSourceXlibWindow(
    chain = WGPUChainedStruct(next = nativeNullPtr(), sType = WGPUSType_SurfaceSourceXlibWindow),
    display = longToPtr(display),
    window = window
  )
  val head: NativePtr[Byte] = nativeAddrOf(source)
  var desc = WGPUSurfaceDescriptor(nextInChain = head, label = noString())
  finishSurface(d, wgpuInstanceCreateSurface(longToPtr(d.instance), nativeAddrOf(desc)))
}

/// A surface for a Wayland window: `display` is the `wl_display*` and `surface` the `wl_surface*`.
@unsafe_ffi
pub func createWaylandSurface(d: Device, display: Long, surface: Long): Result[Surface, String] {
  var source = WGPUSurfaceSourceWaylandSurface(
    chain = WGPUChainedStruct(next = nativeNullPtr(), sType = WGPUSType_SurfaceSourceWaylandSurface),
    display = longToPtr(display),
    surface = longToPtr(surface)
  )
  val head: NativePtr[Byte] = nativeAddrOf(source)
  var desc = WGPUSurfaceDescriptor(nextInChain = head, label = noString())
  finishSurface(d, wgpuInstanceCreateSurface(longToPtr(d.instance), nativeAddrOf(desc)))
}

/// A surface for a Win32 window: `instance` is the `HINSTANCE` and `hwnd` the `HWND`, as
/// `Window.nativeWindow` returns them.
@unsafe_ffi
pub func createWindowsSurface(d: Device, instance: Long, hwnd: Long): Result[Surface, String] {
  var source = WGPUSurfaceSourceWindowsHWND(
    chain = WGPUChainedStruct(next = nativeNullPtr(), sType = WGPUSType_SurfaceSourceWindowsHWND),
    hinstance = longToPtr(instance),
    hwnd = longToPtr(hwnd)
  )
  val head: NativePtr[Byte] = nativeAddrOf(source)
  var desc = WGPUSurfaceDescriptor(nextInChain = head, label = noString())
  finishSurface(d, wgpuInstanceCreateSurface(longToPtr(d.instance), nativeAddrOf(desc)))
}

/// Sets the surface's size in pixels (call it again when the window is resized) and picks its
/// format: RGBA8 when the surface offers it, else BGRA8, else its first format.  The two unorm formats are preferred over their sRGB twins so that colours written by a shader appear as written, as they do in an offscreen `formatRgba8` target.  Presentation is vsynced.
@unsafe_ffi
pub func configureSurface(d: Device, s: Surface, width: Int, height: Int): Result[Surface, String] {
  var caps = WGPUSurfaceCapabilities(
    nextInChain = nativeNullPtr(),
    usages = 0,
    formatCount = 0,
    formats = nativeNullPtr(),
    presentModeCount = 0,
    presentModes = nativeNullPtr(),
    alphaModeCount = 0,
    alphaModes = nativeNullPtr()
  )
  val status = wgpuSurfaceGetCapabilities(longToPtr(s.raw), longToPtr(d.adapter), nativeAddrOf(caps))
  if status != WGPUStatus_Success {
    return Err(error = "the surface reports no capabilities for this adapter")
  }
  if caps.formatCount == 0 {
    wgpuSurfaceCapabilitiesFreeMembers(caps)
    return Err(error = "the surface offers no format for this adapter")
  }
  var formatsAddress: Long = 0
  var formats = caps.formats
  val _a = memcpyIntPointerToLong(nativeAddrOf(formatsAddress), nativeAddrOf(formats), 8)
  var chosen = 0
  var chosenRank = 0
  var i: Long = 0
  while i < caps.formatCount {
    var candidate = 0
    val _c = memcpyFromBytes(nativeAddrOf(candidate), longToPtr(formatsAddress + 4 * i), 4)
    val rank = if candidate == formatRgba8 { 3 } else if candidate == formatBgra8 { 2 } else { 1 }
    if rank > chosenRank {
      chosen = candidate
      chosenRank = rank
    }
    i = i + 1
  }
  wgpuSurfaceCapabilitiesFreeMembers(caps)
  var config = WGPUSurfaceConfiguration(
    nextInChain = nativeNullPtr(),
    device = longToPtr(d.device),
    format = chosen,
    usage = WGPUTextureUsage_RenderAttachment,
    width = width,
    height = height,
    viewFormatCount = 0,
    viewFormats = nativeNullPtr(),
    alphaMode = WGPUCompositeAlphaMode_Auto,
    presentMode = WGPUPresentMode_Fifo
  )
  wgpuSurfaceConfigure(longToPtr(s.raw), nativeAddrOf(config))
  match takeError(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = Surface(raw = s.raw, format = chosen, width = width, height = height))
  }
}

/// The surface's next frame as a render target.  Draw into it with `render`, then `presentFrame`.
/// An `Err` here (the window was resized, minimized or lost) means reconfigure the surface and
/// try again next frame.
@unsafe_ffi
pub func acquireFrame(d: Device, s: Surface): Result[RenderTarget, String] {
  var current = WGPUSurfaceTexture(nextInChain = nativeNullPtr(), texture = nativeNullPtr(), status = 0)
  wgpuSurfaceGetCurrentTexture(longToPtr(s.raw), nativeAddrOf(current))
  if current.status != WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal and current.status != WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal {
    return Err(
      error = "no surface frame is available (status " + current.status.toString() + "); reconfigure the surface"
    )
  }
  val view = wgpuTextureCreateView(current.texture, nativeNullPtr())
  Ok(
    value = RenderTarget(
      texture = ptrToLong(current.texture),
      view = ptrToLong(view),
      width = s.width,
      height = s.height,
      format = s.format
    )
  )
}

/// Shows the frame on the window and releases it; use `discardFrame` instead when drawing failed.
@unsafe_ffi
pub func presentFrame(s: Surface, frame: RenderTarget): Result[Unit, String] {
  val status = wgpuSurfacePresent(longToPtr(s.raw))
  wgpuTextureViewRelease(longToPtr(frame.view))
  wgpuTextureRelease(longToPtr(frame.texture))
  if status == WGPUStatus_Success then Ok(value = ()) else Err(error = "presenting the frame failed (status " + status.toString() + ")")
}

/// Releases a frame from `acquireFrame` without showing it, for when drawing into it failed.
@unsafe_ffi
pub func discardFrame(frame: RenderTarget): Unit {
  wgpuTextureViewRelease(longToPtr(frame.view))
  wgpuTextureRelease(longToPtr(frame.texture))
}

@unsafe_ffi
pub func releaseSurface(s: Surface): Unit {
  wgpuSurfaceUnconfigure(longToPtr(s.raw))
  wgpuSurfaceRelease(longToPtr(s.raw))
}
