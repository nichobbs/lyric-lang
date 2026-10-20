//! gpu.l - Gpu: WebGPU compute for `--target native`, over wgpu-native (docs/67 G5).
//!
//! Every GPU object is an opaque `Long` handle inside a record, so no `NativePtr`
//! crosses this package's public surface.  A `Device` owns the instance, adapter,
//! device and queue; `closeDevice` releases them.  Failures wgpu reports through its
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

/// An offscreen RGBA8 colour target of `width` by `height` pixels.
pub record RenderTarget {
  texture: Long
  view: Long
  width: Int
  height: Int
}

/// A render pipeline drawing triangle lists into an RGBA8 target.
pub record RenderPipeline {
  raw: Long
}

/// Buffers bound to the bindings of a compute pipeline's group 0.
pub record BindGroup {
  raw: Long
}

pub val usageMapRead: Long = 1

pub val usageMapWrite: Long = 2

pub val usageCopySrc: Long = 4

pub val usageCopyDst: Long = 8

pub val usageUniform: Long = 64

pub val usageStorage: Long = 128

/// Where an asynchronous wgpu call leaves its result.
record Slot {
  var status: Int
  var handle: Long
  var message: String
}

val errorCellSize: Long = 1032

val bindGroupEntrySize: Long = 56

val waitIterations: Int = 1000000

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
  var spins = 0
  while slot.status == 0 - 1 and spins < waitIterations {
    wgpuInstanceProcessEvents(longToPtr(instance))
    if device != 0 {
      val _ = wgpuDevicePoll(longToPtr(device), 0, nativeNullPtr())
    }
    spins = spins + 1
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

/// Opens the first available adapter's device and its queue.
@unsafe_ffi
pub func openDevice(): Result[Device, String] {
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
  Ok(
    value = Device(
      instance = instance,
      adapter = adapterSlot.handle,
      device = deviceSlot.handle,
      queue = ptrToLong(queue),
      errors = ptrToLong(errorCell)
    )
  )
}

/// Releases the device, its queue, the adapter and the instance.
@unsafe_ffi
pub func closeDevice(d: Device): Unit {
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
    case Some(message) -> Err(error = message)
    case None -> Ok(value = ComputePipeline(raw = ptrToLong(pipeline)))
  }
}

/// Binds `buffers[i]` to `@binding(i)` of group 0 of the pipeline.
@unsafe_ffi
pub func createBindGroup(d: Device, pipeline: ComputePipeline, buffers: List[Buffer]): Result[BindGroup, String] {
  val layout = wgpuComputePipelineGetBindGroupLayout(longToPtr(pipeline.raw), 0)
  val count = buffers.count
  val entries = Ffi.allocate(bindGroupEntrySize * count.toLong())
  var i = 0
  while i < count {
    var entry = WGPUBindGroupEntry(
      nextInChain = nativeNullPtr(),
      binding = i,
      buffer = longToPtr(buffers[i].raw),
      offset = 0,
      size = buffers[i].size,
      sampler = nativeNullPtr(),
      textureView = nativeNullPtr()
    )
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
    case Some(message) -> Err(error = message)
    case None -> Ok(value = BindGroup(raw = ptrToLong(group)))
  }
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
  RenderTarget(texture = ptrToLong(texture), view = ptrToLong(view), width = width, height = height)
}

@unsafe_ffi
pub func releaseRenderTarget(t: RenderTarget): Unit {
  wgpuTextureViewRelease(longToPtr(t.view))
  wgpuTextureRelease(longToPtr(t.texture))
}

/// A pipeline from one WGSL module's vertex and fragment entry points; it draws triangle
/// lists with no vertex buffers (the shader generates positions from `@builtin(vertex_index)`).
@unsafe_ffi
pub func createRenderPipeline(
  d: Device, source: String, vertexEntry: String, fragmentEntry: String
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
  var target = WGPUColorTargetState(
    nextInChain = nativeNullPtr(),
    format = WGPUTextureFormat_RGBA8Unorm,
    blend = nativeNullPtr(),
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
      bufferCount = 0,
      buffers = nativeNullPtr()
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
  match takeError(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = RenderPipeline(raw = ptrToLong(pipeline)))
  }
}

@unsafe_ffi
pub func releaseRenderPipeline(p: RenderPipeline): Unit {
  wgpuRenderPipelineRelease(longToPtr(p.raw))
}

/// Clears the target to (`red`, `green`, `blue`, `alpha`) and draws `vertexCount` vertices.
@unsafe_ffi
pub func render(
  d: Device,
  target: RenderTarget,
  pipeline: RenderPipeline,
  red: Float,
  green: Float,
  blue: Float,
  alpha: Float,
  vertexCount: Int,
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
  wgpuRenderPassEncoderSetPipeline(pass, longToPtr(pipeline.raw))
  wgpuRenderPassEncoderDraw(pass, vertexCount, 1, 0, 0)
  wgpuRenderPassEncoderEnd(pass)
  wgpuRenderPassEncoderRelease(pass)
  submit(d, encoder)
  match takeError(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = ())
  }
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
