//! gpu.l - Gpu: WebGPU compute for `--target native`, over wgpu-native (docs/67 G5).
//!
//! Every GPU object is an opaque `Long` handle inside a record, so no `NativePtr`
//! crosses this package's public surface.  A `Device` owns the instance, adapter,
//! device and queue and lives for one `withDevice` call.  Every call that can fail runs
//! inside wgpu error scopes (validation and out-of-memory), so the error it causes comes back
//! as its own `Err`; a lost device makes every later call return `Err` with the reason
//! (`deviceLost`).  wgpu-native has no internal-error scope, so an internal error reaches the
//! uncaptured-error callback and `takeError`.
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

/// A window's drawable surface.  `format`, the size and `presentMode` are set by
/// `configureSurface`; `withPresentMode` asks for a present mode before configuring.
pub record Surface {
  raw: Long
  format: Int
  width: Int
  height: Int
  presentMode: PresentMode
}

/// How a surface's frames reach the screen.  `Fifo` waits for vertical sync and every surface
/// supports it; `FifoRelaxed` shows a late frame at once; `Mailbox` keeps only the newest frame,
/// without tearing; `Immediate` shows each frame at once and may tear.
pub enum PresentMode {
  case Fifo
  case FifoRelaxed
  case Mailbox
  case Immediate
}

/// Why a surface has no frame to draw into.
pub union FrameError {
  /// The surface no longer matches its window (it was resized): configure it again.
  case Outdated
  /// The surface is gone: release it and create a new one for the window.
  case Lost
  /// The device ran out of memory, was lost or failed; drawing cannot continue.
  case Failed(message: String)
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
  /// 1, or the full mip chain of a `createMipmappedTexture` texture.
  mipLevels: Int
}

/// A depth buffer of `width` by `height` pixels (32-bit float) for `renderWithDepth`.
pub record DepthTarget {
  texture: Long
  view: Long
  width: Int
  height: Int
}

/// The index buffer of an indexed draw: `count` 32-bit indices from the start of `buffer`
/// (written with `writeInts`; the buffer needs `usageIndex`).
pub record Indices {
  buffer: Buffer
  count: Int
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
/// at `firstInstance` (`@builtin(instance_index)` counts from it).  With `indices`, the draw
/// reads that many vertices through the index buffer and `vertexCount` is not used.  `scissor`
/// clips the draw to a rectangle of the target; `None` draws the whole target.
pub record Draw {
  pipeline: RenderPipeline
  bindGroup: Option[BindGroup]
  vertexBuffers: List[Buffer]
  vertexCount: Int
  instanceCount: Int
  firstInstance: Int
  scissor: Option[Scissor]
  indices: Option[Indices]
}

/// Everything a render pipeline is built from.  `createRenderPipeline` is this with no depth
/// test and no culling.  With `depthTest`, the pipeline draws only fragments nearer (a smaller
/// depth) than the depth buffer holds and records their depth, so it must draw with
/// `renderWithDepth`.  With `cullBack`, triangles whose vertices run clockwise on screen are not
/// drawn.
pub record RenderPipelineDesc {
  source: String
  vertexEntry: String
  fragmentEntry: String
  layouts: List[VertexLayout]
  format: Int
  blend: Bool
  depthTest: Bool
  cullBack: Bool
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
ref record Slot {
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

// The device's error cell, written by wgpu's callbacks: byte 0 counts the uncaptured errors
// (to 255), byte 1 is set when the device is lost; the first uncaptured message is a
// NUL-terminated string from `uncapturedAt`, the device-lost message one from `lostAt`.  Both
// are cut at `cellText` bytes; a call's own error comes from its scope and is not cut there.
val errorCellSize: Long = 2056

val uncapturedAt: Long = 8

val lostAt: Long = 1032

val cellText: Long = 1023

// The longest message copied from wgpu into a Lyric string; WGSL errors carry the source excerpt.
val messageLimit: Long = 65536

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
  while i < v.length and i < messageLimit {
    bytes.add(nativeLoadByte(v.data, i))
    i = i + 1
  }
  match tryDecodeUtf8(bytes.toArray()) {
    case Some(text) -> text
    case None -> ""
  }
}

// Copies at most `cellText` bytes of `message` into the cell at `at`, NUL-terminated.
@unsafe_ffi
func storeCellText(cell: NativePtr[Byte], at: Long, message: WGPUStringView): Unit {
  var i: Long = 0
  if message.data != nativeNullPtr() {
    // A length of -1 (WGPU_STRLEN) is a NUL-terminated string.
    while i < cellText and (if message.length < 0 then nativeLoadByte(message.data, i) != 0u8 else i < message.length) {
      nativeStoreByte(cell, at + i, nativeLoadByte(message.data, i))
      i = i + 1
    }
  }
  nativeStoreByte(cell, at + i, 0u8)
}

// Records a device lost while in use.  `Destroyed` is the device's own release in
// `closeDevice`, and `CallbackCancelled` the instance going away; neither is a loss.
@unsafe_ffi
func onDeviceLost(device: NativePtr[NativePtr[Byte]], reason: Int, message: WGPUStringView, cell: NativePtr[Byte]): Unit {
  if reason == WGPUDeviceLostReason_Destroyed or reason == WGPUDeviceLostReason_CallbackCancelled {
    return
  }
  if nativeLoadByte(cell, 1) == 0u8 {
    storeCellText(cell, lostAt, message)
    nativeStoreByte(cell, 1, if reason == WGPUDeviceLostReason_FailedCreation then 2u8 else 1u8)
  }
}

// An error outside every error scope: the first message is kept and the rest counted.
@unsafe_ffi
func onUncapturedError(
  device: NativePtr[NativePtr[Byte]], kind: Int, message: WGPUStringView, cell: NativePtr[Byte]
): Unit {
  val seen = nativeLoadByte(cell, 0)
  if seen == 0u8 {
    storeCellText(cell, uncapturedAt, message)
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
      // Non-blocking: a blocking poll would not return for a hung device, and the deadline
      // could not end the wait.
      val _ = wgpuDevicePoll(longToPtr(device), 0, nativeNullPtr())
    }
  }
  slot.status != 0 - 1
}

/// The message of the first error wgpu raised outside an error scope since the last
/// `takeError`, with how many more followed it, or None.  Validation and out-of-memory errors a
/// `Gpu` call causes are that call's `Err`, so this sees internal errors (wgpu-native has no
/// scope for them) and errors wgpu raises on its own.
@unsafe_ffi
pub func takeError(d: Device): Option[String] {
  val cell = longToPtr(d.errors)
  val seen = nativeLoadByte(cell, 0)
  if seen == 0u8 {
    return None
  }
  val text = match Ffi.tryFromCString(longToPtr(d.errors + uncapturedAt)) {
    case Some(s) -> s
    case None -> "unknown GPU error"
  }
  nativeStoreByte(cell, 0, 0u8)
  if seen == 1u8 {
    return Some(value = text)
  }
  val more = if seen == 255u8 then "at least 254 more errors" else (seen.toInt() - 1).toString() + " more errors"
  Some(value = text + " (and " + more + ")")
}

/// Why the device was lost, once it has been: the driver reset or crashed, or the GPU was
/// removed.  Every call on a lost device returns this as its `Err`; a program recovers by
/// leaving `withDevice` and opening a new device.
@unsafe_ffi
pub func deviceLost(d: Device): Option[String] {
  val cell = longToPtr(d.errors)
  val flag = nativeLoadByte(cell, 1)
  if flag == 0u8 {
    return None
  }
  val detail = match Ffi.tryFromCString(longToPtr(d.errors + lostAt)) { case Some(s) -> s; case None -> "" }
  val head = if flag == 2u8 then "the GPU device could not be created" else "the GPU device was lost"
  Some(value = if Str.isEmpty(detail) then head else head + ": " + detail)
}

// Opens the error scopes a call's errors are caught in; `closeScope` pops them.  wgpu-native
// panics on `WGPUErrorFilter_Internal`, so internal errors are left to the uncaptured-error
// callback.
@unsafe_ffi
func openScope(d: Device): Unit {
  val dev = longToPtr(d.device)
  wgpuDevicePushErrorScope(dev, WGPUErrorFilter_OutOfMemory)
  wgpuDevicePushErrorScope(dev, WGPUErrorFilter_Validation)
}

@unsafe_ffi
func popScope(d: Device): Option[String] {
  val slot = Slot(status = 0 - 1, handle = 0, message = "")
  val onPop: (Int, Int, WGPUStringView, NativePtr[Byte]) -> Unit = { status: Int, kind: Int, message: WGPUStringView, user: NativePtr[Byte] ->
    slot.handle = kind.toLong()
    slot.message = stringOfView(message)
    slot.status = status
  }
  val info = WGPUPopErrorScopeCallbackInfo(
    nextInChain = nativeNullPtr(),
    mode = WGPUCallbackMode_AllowProcessEvents,
    callback = onPop,
    userdata1 = onPop,
    userdata2 = nativeNullPtr()
  )
  val _f = wgpuDevicePopErrorScope(longToPtr(d.device), info)
  if not waitSlot(d.instance, d.device, slot) {
    return Some(value = "wgpu: waiting for the call's errors timed out")
  }
  if slot.status != WGPUPopErrorScopeStatus_Success {
    return Some(value = "wgpu: cannot read the call's errors: " + slot.message)
  }
  val kind = slot.handle.toInt()
  if kind == WGPUErrorType_NoError {
    None
  } else if kind == WGPUErrorType_OutOfMemory {
    Some(value = "the GPU is out of memory: " + slot.message)
  } else {
    Some(value = slot.message)
  }
}

// Pops the scopes `openScope` pushed and returns the first error they caught, or the reason
// the device was lost.
@unsafe_ffi
func closeScope(d: Device): Option[String] {
  val validation = popScope(d)
  val memory = popScope(d)
  match deviceLost(d) {
    case Some(reason) -> Some(value = reason)
    case None -> match validation { case Some(m) -> Some(value = m); case None -> memory }
  }
}

// `closeScope` as a `Result`.
@unsafe_ffi
func scopeResult(d: Device): Result[Unit, String] {
  match closeScope(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = ())
  }
}

/// Opens the first available adapter's device and its queue, runs `body` with it, then
/// releases everything.  wgpu keeps the device's error and device-lost callbacks for the
/// device's whole life and native closures are reference-counted, so the device lives only
/// as long as this call: the closures are alive until `body` has returned.  An `Err` means no
/// device could be opened; everything acquired on the way is released first.  A panic in
/// `body` ends the program without releasing the device, which the operating system reclaims.
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
    // Releasing the instance cancels the request, so its callback cannot run after this call.
    wgpuInstanceRelease(inst)
    return Err(error = "wgpu: requesting an adapter timed out")
  }
  if adapterSlot.status != 1 or adapterSlot.handle == 0 {
    if adapterSlot.handle != 0 {
      wgpuAdapterRelease(longToPtr(adapterSlot.handle))
    }
    wgpuInstanceRelease(inst)
    return Err(error = "wgpu: no adapter available: " + adapterSlot.message)
  }

  val errorCell = Ffi.allocate(errorCellSize)
  nativeStoreByte(errorCell, 0, 0u8)
  nativeStoreByte(errorCell, 1, 0u8)

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
      userdata2 = errorCell
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
  val opened = waitSlot(instance, 0, deviceSlot)
  if not opened or deviceSlot.status != 1 or deviceSlot.handle == 0 {
    if deviceSlot.handle != 0 {
      wgpuDeviceRelease(longToPtr(deviceSlot.handle))
    }
    wgpuAdapterRelease(longToPtr(adapterSlot.handle))
    wgpuInstanceRelease(inst)
    Ffi.release(errorCell)
    return Err(
      error = if not opened then "wgpu: requesting a device timed out" else "wgpu: cannot open a device: " + deviceSlot.message
    )
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

/// Releases the device, its queue, the adapter and the instance.  The error cell goes last:
/// the device-lost callback can still run while the device is released.
@unsafe_ffi
func closeDevice(d: Device): Unit {
  wgpuQueueRelease(longToPtr(d.queue))
  wgpuDeviceRelease(longToPtr(d.device))
  wgpuAdapterRelease(longToPtr(d.adapter))
  wgpuInstanceRelease(longToPtr(d.instance))
  Ffi.release(longToPtr(d.errors))
}

/// A buffer of `size` bytes with the given usage flags (`usageStorage`, `usageCopyDst`, ...).
/// An `Err` is an invalid combination of flags, a size over the device's limit or a size
/// that is not a multiple of 4 for a mappable buffer, or the GPU out of memory.
@unsafe_ffi
pub func createBuffer(d: Device, size: Long, usage: Long): Result[Buffer, String] {
  if size < 0 {
    return Err(error = "a buffer needs a size of at least 0 bytes, not " + size.toString())
  }
  openScope(d)
  var desc = WGPUBufferDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    usage = usage,
    size = size,
    mappedAtCreation = 0
  )
  val raw = wgpuDeviceCreateBuffer(longToPtr(d.device), nativeAddrOf(desc))
  match closeScope(d) {
    case Some(message) -> {
      wgpuBufferRelease(raw)
      Err(error = message)
    }
    case None -> Ok(value = Buffer(raw = ptrToLong(raw), size = size))
  }
}

// Checks that `bytes` bytes written at `offset` fit in the buffer and keep WebGPU's
// 4-byte alignment for queue writes.
func checkWrite(b: Buffer, offset: Long, bytes: Long): Result[Unit, String] {
  if offset < 0 or offset % 4 != 0 {
    return Err(error = "a buffer write needs an offset that is a multiple of 4, not " + offset.toString())
  }
  if bytes % 4 != 0 {
    return Err(error = "a buffer write needs a multiple of 4 bytes, not " + bytes.toString())
  }
  if offset + bytes > b.size {
    return Err(
      error = "writing " + bytes.toString() + " bytes at offset " + offset.toString() + " overruns a buffer of " +
        b.size.toString() +
        " bytes"
    )
  }
  Ok(value = ())
}

@unsafe_ffi
pub func releaseBuffer(b: Buffer): Unit {
  wgpuBufferRelease(longToPtr(b.raw))
}

/// Copies `values` into the buffer at `offset` bytes.  The buffer needs
/// `usageCopyDst`; the offset and the byte count must be multiples of 4 and fit in the buffer.
@unsafe_ffi
pub func writeInts(d: Device, b: Buffer, offset: Long, values: buffer[Int]): Result[Unit, String] {
  val bytes = values.length.toLong() * 4
  match checkWrite(b, offset, bytes) {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> ()
  }
  openScope(d)
  values.withPointer(
    { p: NativePtr[Int] -> wgpuQueueWriteBufferInts(longToPtr(d.queue), longToPtr(b.raw), offset, p, bytes) }
  )
  scopeResult(d)
}

/// Copies `values` into the buffer at `offset` bytes.  The buffer needs
/// `usageCopyDst`; the offset and the byte count must be multiples of 4 and fit in the buffer.
@unsafe_ffi
pub func writeBytes(d: Device, b: Buffer, offset: Long, values: buffer[Byte]): Result[Unit, String] {
  val bytes = values.length.toLong()
  match checkWrite(b, offset, bytes) {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> ()
  }
  openScope(d)
  values.withPointer(
    { p: NativePtr[Byte] -> wgpuQueueWriteBufferBytes(longToPtr(d.queue), longToPtr(b.raw), offset, p, bytes) }
  )
  scopeResult(d)
}

/// Copies `values` (32-bit floats) into the buffer at `offset` bytes.  The buffer needs
/// `usageCopyDst`; the offset and the byte count must be multiples of 4 and fit in the buffer.
@unsafe_ffi
pub func writeFloats(d: Device, b: Buffer, offset: Long, values: buffer[Float]): Result[Unit, String] {
  val bytes = values.length.toLong() * 4
  match checkWrite(b, offset, bytes) {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> ()
  }
  openScope(d)
  values.withPointer(
    { p: NativePtr[Float] -> wgpuQueueWriteBufferFloats(longToPtr(d.queue), longToPtr(b.raw), offset, p, bytes) }
  )
  scopeResult(d)
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
  if count < 0 or bytes > b.size {
    return Err(error = "cannot read " + count.toString() + " Ints from a buffer of " + b.size.toString() + " bytes")
  }
  val staging = match createBuffer(d, bytes, usageMapRead + usageCopyDst) {
    case Ok(x) -> x
    case Err(e) -> return Err(error = e)
  }
  openScope(d)
  val encoder = wgpuDeviceCreateCommandEncoder(longToPtr(d.device), nativeNullPtr())
  wgpuCommandEncoderCopyBufferToBuffer(encoder, longToPtr(b.raw), 0, longToPtr(staging.raw), 0, bytes)
  submit(d, encoder)
  match closeScope(d) {
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

// A shader module from WGSL `source`.  It is created in a scope of its own, so a WGSL error
// comes back as "WGSL: " and the compiler's message, which names the line and column, apart
// from errors in the pipeline built from it.
@unsafe_ffi
func createShader(d: Device, source: String): Result[NativePtr[Byte], String] {
  val wgsl = Ffi.toCString(source)
  var chained = WGPUShaderSourceWGSL(
    chain = WGPUChainedStruct(next = nativeNullPtr(), sType = WGPUSType_ShaderSourceWGSL),
    code = cString(wgsl)
  )
  // The chain header is the first member, so the struct's address is its chain's address.
  val chainHead: NativePtr[Byte] = nativeAddrOf(chained)
  var moduleDesc = WGPUShaderModuleDescriptor(nextInChain = chainHead, label = noString())
  openScope(d)
  val shader = wgpuDeviceCreateShaderModule(longToPtr(d.device), nativeAddrOf(moduleDesc))
  val failure = closeScope(d)
  Ffi.release(wgsl)
  match failure {
    case Some(message) -> {
      wgpuShaderModuleRelease(shader)
      Err(error = "WGSL: " + message)
    }
    case None -> Ok(value = shader)
  }
}

/// A compute pipeline for the WGSL `source`'s `entry` point, with its bindings inferred.  An
/// `Err` starting "WGSL: " is a shader that does not compile; any other is a pipeline the shader
/// cannot make, such as a missing entry point.
@unsafe_ffi
pub func createComputePipeline(d: Device, source: String, entry: String): Result[ComputePipeline, String] {
  val shader = match createShader(d, source) { case Ok(m) -> m; case Err(e) -> return Err(error = e) }
  val entryName = Ffi.toCString(entry)
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
  openScope(d)
  val pipeline = wgpuDeviceCreateComputePipeline(longToPtr(d.device), nativeAddrOf(pipelineDesc))
  wgpuShaderModuleRelease(shader)
  Ffi.release(entryName)
  match closeScope(d) {
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
  openScope(d)
  val group = wgpuDeviceCreateBindGroup(longToPtr(d.device), nativeAddrOf(desc))
  wgpuBindGroupLayoutRelease(layout)
  Ffi.release(entries)
  match closeScope(d) {
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
  openScope(d)
  val encoder = wgpuDeviceCreateCommandEncoder(longToPtr(d.device), nativeNullPtr())
  val pass = wgpuCommandEncoderBeginComputePass(encoder, nativeNullPtr())
  wgpuComputePassEncoderSetPipeline(pass, longToPtr(pipeline.raw))
  wgpuComputePassEncoderSetBindGroup(pass, 0, longToPtr(group.raw), 0, nativeNullPtr())
  wgpuComputePassEncoderDispatchWorkgroups(pass, x, y, z)
  wgpuComputePassEncoderEnd(pass)
  wgpuComputePassEncoderRelease(pass)
  submit(d, encoder)
  match closeScope(d) {
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

/// An RGBA8 colour target that a render pass can draw into and `readPixels` can read.  An `Err`
/// is a size that is not positive or over the device's limit, or the GPU out of memory.
@unsafe_ffi
pub func createRenderTarget(d: Device, width: Int, height: Int): Result[RenderTarget, String] {
  if width <= 0 or height <= 0 {
    return Err(error = "a render target needs a positive size, not " + width.toString() + "x" + height.toString())
  }
  openScope(d)
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
  match closeScope(d) {
    case Some(message) -> {
      wgpuTextureViewRelease(view)
      wgpuTextureRelease(texture)
      Err(error = message)
    }
    case None -> Ok(
      value = RenderTarget(
        texture = ptrToLong(texture),
        view = ptrToLong(view),
        width = width,
        height = height,
        format = WGPUTextureFormat_RGBA8Unorm
      )
    )
  }
}

@unsafe_ffi
pub func releaseRenderTarget(t: RenderTarget): Unit {
  wgpuTextureViewRelease(longToPtr(t.view))
  wgpuTextureRelease(longToPtr(t.texture))
}

/// A depth buffer for `renderWithDepth` into targets of the same size.
@unsafe_ffi
pub func createDepthTarget(d: Device, width: Int, height: Int): Result[DepthTarget, String] {
  if width <= 0 or height <= 0 {
    return Err(error = "a depth target needs a positive size, not " + width.toString() + "x" + height.toString())
  }
  var desc = WGPUTextureDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    usage = WGPUTextureUsage_RenderAttachment,
    dimension = WGPUTextureDimension_2D,
    size = WGPUExtent3D(width = width, height = height, depthOrArrayLayers = 1),
    format = WGPUTextureFormat_Depth32Float,
    mipLevelCount = 1,
    sampleCount = 1,
    viewFormatCount = 0,
    viewFormats = nativeNullPtr()
  )
  openScope(d)
  val texture = wgpuDeviceCreateTexture(longToPtr(d.device), nativeAddrOf(desc))
  val view = wgpuTextureCreateView(texture, nativeNullPtr())
  match closeScope(d) {
    case Some(message) -> {
      wgpuTextureViewRelease(view)
      wgpuTextureRelease(texture)
      Err(error = message)
    }
    case None -> Ok(
      value = DepthTarget(
        texture = ptrToLong(texture),
        view = ptrToLong(view),
        width = width,
        height = height
      )
    )
  }
}

@unsafe_ffi
pub func releaseDepthTarget(t: DepthTarget): Unit {
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
  createRenderPipelineFrom(
    d,
    RenderPipelineDesc(
      source = source,
      vertexEntry = vertexEntry,
      fragmentEntry = fragmentEntry,
      layouts = layouts,
      format = format,
      blend = blend,
      depthTest = false,
      cullBack = false
    )
  )
}

/// A render pipeline from a full description (`RenderPipelineDesc`), for a depth test or
/// back-face culling.
@unsafe_ffi
pub func createRenderPipelineFrom(d: Device, desc: RenderPipelineDesc): Result[RenderPipeline, String] {
  val layouts = desc.layouts
  val format = desc.format
  val blend = desc.blend
  val shader = match createShader(d, desc.source) { case Ok(m) -> m; case Err(e) -> return Err(error = e) }
  val vertexName = Ffi.toCString(desc.vertexEntry)
  val fragmentName = Ffi.toCString(desc.fragmentEntry)
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
  val keep = WGPUStencilFaceState(
    compare = WGPUCompareFunction_Always,
    failOp = WGPUStencilOperation_Keep,
    depthFailOp = WGPUStencilOperation_Keep,
    passOp = WGPUStencilOperation_Keep
  )
  var depthState = WGPUDepthStencilState(
    nextInChain = nativeNullPtr(),
    format = WGPUTextureFormat_Depth32Float,
    depthWriteEnabled = WGPUOptionalBool_True,
    depthCompare = WGPUCompareFunction_Less,
    stencilFront = keep,
    stencilBack = keep,
    stencilReadMask = 0,
    stencilWriteMask = 0,
    depthBias = 0,
    depthBiasSlopeScale = 0.0f32,
    depthBiasClamp = 0.0f32
  )
  var pipelineDesc = WGPURenderPipelineDescriptor(
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
      cullMode = if desc.cullBack then WGPUCullMode_Back else WGPUCullMode_None,
      unclippedDepth = 0
    ),
    depthStencil = if desc.depthTest { nativeAddrOf(depthState) } else { nativeNullPtr() },
    multisample = WGPUMultisampleState(
      nextInChain = nativeNullPtr(),
      count = 1,
      mask = 0 - 1,
      alphaToCoverageEnabled = 0
    ),
    fragment = nativeAddrOf(fragment)
  )
  openScope(d)
  val pipeline = wgpuDeviceCreateRenderPipeline(longToPtr(d.device), nativeAddrOf(pipelineDesc))
  wgpuShaderModuleRelease(shader)
  Ffi.release(vertexName)
  Ffi.release(fragmentName)
  Ffi.release(layoutArray)
  for address in attributeArrays {
    Ffi.release(longToPtr(address))
  }
  match closeScope(d) {
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
  renderPass(d, target, None, red, green, blue, alpha, draws)
}

/// `render` with a depth buffer, cleared to the farthest depth (1.0) first, for pipelines built
/// with `depthTest`.  The depth target must be the target's size.
@unsafe_ffi
pub func renderWithDepth(
  d: Device,
  target: RenderTarget,
  depth: DepthTarget,
  red: Float,
  green: Float,
  blue: Float,
  alpha: Float,
  draws: List[Draw],
): Result[Unit, String] {
  if depth.width != target.width or depth.height != target.height {
    return Err(
      error = "a " + depth.width.toString() + "x" + depth.height.toString() + " depth target cannot serve a " +
        target.width.toString() +
        "x" +
        target.height.toString() +
        " target"
    )
  }
  renderPass(d, target, Some(value = depth), red, green, blue, alpha, draws)
}

@unsafe_ffi
func renderPass(
  d: Device,
  target: RenderTarget,
  depth: Option[DepthTarget],
  red: Float,
  green: Float,
  blue: Float,
  alpha: Float,
  draws: List[Draw],
): Result[Unit, String] {
  for draw in draws {
    match draw.indices {
      case Some(ix) -> if ix.count < 0 or ix.count.toLong() * 4 > ix.buffer.size {
        return Err(
          error = "an index buffer of " + ix.buffer.size.toString() + " bytes cannot hold " + ix.count.toString() +
            " indices"
        )
      }
      case None -> ()
    }
  }
  openScope(d)
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
  val hasDepth = match depth { case Some(_) -> true; case None -> false }
  val depthView = match depth { case Some(t) -> t.view; case None -> 0 }
  var depthAttachment = WGPURenderPassDepthStencilAttachment(
    nextInChain = nativeNullPtr(),
    view = longToPtr(depthView),
    depthLoadOp = WGPULoadOp_Clear,
    depthStoreOp = WGPUStoreOp_Store,
    depthClearValue = 1.0f32,
    depthReadOnly = 0,
    stencilLoadOp = WGPULoadOp_Undefined,
    stencilStoreOp = WGPUStoreOp_Undefined,
    stencilClearValue = 0,
    stencilReadOnly = 0
  )
  var passDesc = WGPURenderPassDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    colorAttachmentCount = 1,
    colorAttachments = nativeAddrOf(attachment),
    depthStencilAttachment = if hasDepth { nativeAddrOf(depthAttachment) } else { nativeNullPtr() },
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
    match draw.indices {
      case Some(ix) -> {
        wgpuRenderPassEncoderSetIndexBuffer(pass, longToPtr(ix.buffer.raw), WGPUIndexFormat_Uint32, 0, ix.buffer.size)
        wgpuRenderPassEncoderDrawIndexed(pass, ix.count, draw.instanceCount, 0, 0, draw.firstInstance)
      }
      case None -> wgpuRenderPassEncoderDraw(pass, draw.vertexCount, draw.instanceCount, 0, draw.firstInstance)
    }
  }
  wgpuRenderPassEncoderEnd(pass)
  wgpuRenderPassEncoderRelease(pass)
  submit(d, encoder)
  match closeScope(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = ())
  }
}

@unsafe_ffi
func writePixels(d: Device, texture: NativePtr[Byte], level: Int, width: Int, height: Int, pixels: buffer[Byte]): Unit {
  var destination = WGPUTexelCopyTextureInfo(
    texture = texture,
    mipLevel = level,
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

// Checks a texture's size and that `pixels` holds exactly its RGBA8 texels.
func checkPixels(width: Int, height: Int, pixels: buffer[Byte]): Result[Unit, String] {
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
  Ok(value = ())
}

/// The number of levels in a full mip chain for a `width` by `height` texture: one per halving of
/// the larger side, down to 1 pixel.
pub func mipLevelCount(width: Int, height: Int): Int {
  var side = if width > height then width else height
  var levels = 1
  while side > 1 {
    side = side / 2
    levels = levels + 1
  }
  levels
}

// The next mip level of a `width` by `height` RGBA8 image: each texel is the average of the
// (up to) 2x2 texels it covers, rounded to nearest; an odd last row or column is folded into
// the texel beside it.
func halve(width: Int, height: Int, pixels: buffer[Byte]): buffer[Byte] {
  val w = if width > 1 then width / 2 else 1
  val h = if height > 1 then height / 2 else 1
  var half = Buf.filled(w * h * 4, 0u8)
  var y = 0
  while y < h {
    val y0 = if height > 1 then y * 2 else 0
    val y1 = if y == h - 1 then height - 1 else y0 + 1
    var x = 0
    while x < w {
      val x0 = if width > 1 then x * 2 else 0
      val x1 = if x == w - 1 then width - 1 else x0 + 1
      var c = 0
      while c < 4 {
        var sum = 0
        var count = 0
        var sy = y0
        while sy <= y1 {
          var sx = x0
          while sx <= x1 {
            sum = sum + pixels[(sy * width + sx) * 4 + c].toInt()
            count = count + 1
            sx = sx + 1
          }
          sy = sy + 1
        }
        half[(y * w + x) * 4 + c] = ((sum + count / 2) / count).toByte()
        c = c + 1
      }
      x = x + 1
    }
    y = y + 1
  }
  half
}

// Writes `pixels` to level 0 and, for a mipmapped texture, each smaller level from the one above.
@unsafe_ffi
func writeLevels(d: Device, texture: NativePtr[Byte], levels: Int, width: Int, height: Int, pixels: buffer[Byte]): Unit {
  var level = 0
  var w = width
  var h = height
  var current = pixels
  while level < levels {
    writePixels(d, texture, level, w, h, current)
    level = level + 1
    if level < levels {
      current = halve(w, h, current)
      w = if w > 1 then w / 2 else 1
      h = if h > 1 then h / 2 else 1
    }
  }
}

@unsafe_ffi
func makeTexture(d: Device, width: Int, height: Int, levels: Int, pixels: buffer[Byte]): Result[Texture, String] {
  match checkPixels(width, height, pixels) {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> ()
  }
  var desc = WGPUTextureDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    usage = WGPUTextureUsage_TextureBinding + WGPUTextureUsage_CopyDst,
    dimension = WGPUTextureDimension_2D,
    size = WGPUExtent3D(width = width, height = height, depthOrArrayLayers = 1),
    format = WGPUTextureFormat_RGBA8Unorm,
    mipLevelCount = levels,
    sampleCount = 1,
    viewFormatCount = 0,
    viewFormats = nativeNullPtr()
  )
  openScope(d)
  val texture = wgpuDeviceCreateTexture(longToPtr(d.device), nativeAddrOf(desc))
  writeLevels(d, texture, levels, width, height, pixels)
  val view = wgpuTextureCreateView(texture, nativeNullPtr())
  match closeScope(d) {
    case Some(message) -> {
      wgpuTextureViewRelease(view)
      wgpuTextureRelease(texture)
      Err(error = message)
    }
    case None -> Ok(
      value = Texture(
        raw = ptrToLong(texture),
        view = ptrToLong(view),
        width = width,
        height = height,
        mipLevels = levels
      )
    )
  }
}

/// An RGBA8 texture of `width` by `height` pixels holding `pixels` (tightly packed rows, top
/// row first), ready to bind with `TextureBinding`.
@unsafe_ffi
pub func createTexture(d: Device, width: Int, height: Int, pixels: buffer[Byte]): Result[Texture, String] {
  makeTexture(d, width, height, 1, pixels)
}

/// `createTexture` with a full mip chain (`mipLevelCount` levels), each level the 2x2 box-filtered
/// average of the one above, so a texture drawn smaller than its size is sampled from the level
/// that matches instead of aliasing.  Sample it with a `createSampler(d, true)` sampler, which
/// blends between levels.
@unsafe_ffi
pub func createMipmappedTexture(d: Device, width: Int, height: Int, pixels: buffer[Byte]): Result[Texture, String] {
  if width <= 0 or height <= 0 {
    return Err(error = "a texture needs a positive size, not " + width.toString() + "x" + height.toString())
  }
  makeTexture(d, width, height, mipLevelCount(width, height), pixels)
}

@unsafe_ffi
pub func releaseTexture(t: Texture): Unit {
  wgpuTextureViewRelease(longToPtr(t.view))
  wgpuTextureRelease(longToPtr(t.raw))
}

/// Replaces every pixel of `t` with `pixels` (tightly packed rows, top row first), for a texture
/// whose contents change, such as a glyph atlas.  The count must be the texture's own size; a
/// mipmapped texture's smaller levels are rebuilt from it.
@unsafe_ffi
pub func writeTexture(d: Device, t: Texture, pixels: buffer[Byte]): Result[Unit, String] {
  match checkPixels(t.width, t.height, pixels) {
    case Err(e) -> return Err(error = e)
    case Ok(_) -> ()
  }
  openScope(d)
  writeLevels(d, longToPtr(t.raw), t.mipLevels, t.width, t.height, pixels)
  scopeResult(d)
}

/// A sampler that clamps to the texture's edge and filters linearly (`linear`, also blending
/// between the mip levels of a mipmapped texture) or takes the nearest texel of the nearest level.
@unsafe_ffi
pub func createSampler(d: Device, linear: Bool): Result[Sampler, String] {
  val filter = if linear then WGPUFilterMode_Linear else WGPUFilterMode_Nearest
  val mipFilter = if linear then WGPUMipmapFilterMode_Linear else WGPUMipmapFilterMode_Nearest
  var desc = WGPUSamplerDescriptor(
    nextInChain = nativeNullPtr(),
    label = noString(),
    addressModeU = WGPUAddressMode_ClampToEdge,
    addressModeV = WGPUAddressMode_ClampToEdge,
    addressModeW = WGPUAddressMode_ClampToEdge,
    magFilter = filter,
    minFilter = filter,
    mipmapFilter = mipFilter,
    lodMinClamp = 0.0f32,
    lodMaxClamp = 32.0f32,
    compare = WGPUCompareFunction_Undefined,
    maxAnisotropy = [1u8, 0u8]
  )
  openScope(d)
  val raw = wgpuDeviceCreateSampler(longToPtr(d.device), nativeAddrOf(desc))
  match closeScope(d) {
    case Some(message) -> {
      wgpuSamplerRelease(raw)
      Err(error = message)
    }
    case None -> Ok(value = Sampler(raw = ptrToLong(raw)))
  }
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
  val staging = match createBuffer(d, paddedRow.toLong() * target.height.toLong(), usageMapRead + usageCopyDst) {
    case Ok(x) -> x
    case Err(e) -> return Err(error = e)
  }
  openScope(d)
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
  match closeScope(d) {
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
  match deviceLost(d) {
    case Some(reason) -> {
      if ptrToLong(raw) != 0 {
        wgpuSurfaceRelease(raw)
      }
      Err(error = reason)
    }
    case None -> if ptrToLong(raw) == 0 {
      Err(error = "wgpu could not create a surface for this window")
    } else {
      Ok(value = Surface(raw = ptrToLong(raw), format = 0, width = 0, height = 0, presentMode = PresentMode.Fifo))
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

/// A surface for a macOS window: `layer` is the `CAMetalLayer*`, as `Window.metalLayer` returns it.
/// The layer must outlive the surface.
@unsafe_ffi
pub func createMetalSurface(d: Device, layer: Long): Result[Surface, String] {
  var source = WGPUSurfaceSourceMetalLayer(
    chain = WGPUChainedStruct(next = nativeNullPtr(), sType = WGPUSType_SurfaceSourceMetalLayer),
    layer = longToPtr(layer)
  )
  val head: NativePtr[Byte] = nativeAddrOf(source)
  var desc = WGPUSurfaceDescriptor(nextInChain = head, label = noString())
  finishSurface(d, wgpuInstanceCreateSurface(longToPtr(d.instance), nativeAddrOf(desc)))
}

/// `s` asking for `mode` the next time it is configured.  `configureSurface` falls back to
/// `Fifo`, which every surface supports, when the surface does not offer `mode`; the
/// configured surface's `presentMode` is the mode in use.
pub func withPresentMode(s: Surface, mode: PresentMode): Surface {
  s.copy(presentMode = mode)
}

func presentModeCode(mode: PresentMode): Int {
  match mode {
    case Fifo -> WGPUPresentMode_Fifo
    case FifoRelaxed -> WGPUPresentMode_FifoRelaxed
    case Mailbox -> WGPUPresentMode_Mailbox
    case Immediate -> WGPUPresentMode_Immediate
  }
}

/// Sets the surface's size in pixels (call it again when the window is resized) and picks its
/// format: RGBA8 when the surface offers it, else BGRA8, else its first format.  The two unorm
/// formats are preferred over their sRGB twins so that colours written by a shader appear as
/// written, as they do in an offscreen `formatRgba8` target.  Frames are presented with the
/// surface's `presentMode` (`withPresentMode`) when the surface offers it, else `Fifo` (vsync).
@unsafe_ffi
pub func configureSurface(d: Device, s: Surface, width: Int, height: Int): Result[Surface, String] {
  if width <= 0 or height <= 0 {
    return Err(error = "a surface needs a positive size, not " + width.toString() + "x" + height.toString())
  }
  match deviceLost(d) {
    case Some(reason) -> return Err(error = reason)
    case None -> ()
  }
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
  val wanted = presentModeCode(s.presentMode)
  var modesAddress: Long = 0
  var modes = caps.presentModes
  val _m = memcpyIntPointerToLong(nativeAddrOf(modesAddress), nativeAddrOf(modes), 8)
  var offered = false
  var mi: Long = 0
  while mi < caps.presentModeCount {
    var candidate = 0
    val _c = memcpyFromBytes(nativeAddrOf(candidate), longToPtr(modesAddress + 4 * mi), 4)
    if candidate == wanted {
      offered = true
    }
    mi = mi + 1
  }
  wgpuSurfaceCapabilitiesFreeMembers(caps)
  val mode = if offered then s.presentMode else PresentMode.Fifo
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
    presentMode = presentModeCode(mode)
  )
  openScope(d)
  wgpuSurfaceConfigure(longToPtr(s.raw), nativeAddrOf(config))
  match closeScope(d) {
    case Some(message) -> Err(error = message)
    case None -> Ok(value = Surface(raw = s.raw, format = chosen, width = width, height = height, presentMode = mode))
  }
}

@unsafe_ffi
func frameFrom(s: Surface, current: WGPUSurfaceTexture): RenderTarget {
  val view = wgpuTextureCreateView(current.texture, nativeNullPtr())
  RenderTarget(
    texture = ptrToLong(current.texture),
    view = ptrToLong(view),
    width = s.width,
    height = s.height,
    format = s.format
  )
}

/// The surface's next frame as a render target, or `None` when no frame can be shown right now
/// and the caller should skip this iteration without touching the surface: the window is
/// occluded, minimized or not on screen yet (on macOS the first frames after `Window.show`), or the
/// compositor timed out.  Draw into the target with `render`, then `presentFrame`.  An `Err` says
/// what the loop must do: configure the surface again (`Outdated`, as after a resize), create a
/// new surface (`Lost`), or stop (`Failed`).
@unsafe_ffi
pub func tryAcquireFrame(d: Device, s: Surface): Result[Option[RenderTarget], FrameError] {
  match deviceLost(d) {
    case Some(reason) -> return Err(error = Failed(message = reason))
    case None -> ()
  }
  var current = WGPUSurfaceTexture(nextInChain = nativeNullPtr(), texture = nativeNullPtr(), status = 0)
  wgpuSurfaceGetCurrentTexture(longToPtr(s.raw), nativeAddrOf(current))
  val status = current.status
  if status == WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal or status == WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal {
    return Ok(value = Some(value = frameFrom(s, current)))
  }
  if status == WGPUSurfaceGetCurrentTextureStatus_Timeout or status == WGPUSurfaceGetCurrentTextureStatus_Occluded {
    return Ok(value = None)
  }
  if status == WGPUSurfaceGetCurrentTextureStatus_Outdated {
    return Err(error = Outdated)
  }
  if status == WGPUSurfaceGetCurrentTextureStatus_Lost {
    return Err(error = Lost)
  }
  val detail = match deviceLost(d) {
    case Some(reason) -> reason
    case None -> "the surface has no frame (status " + status.toString() + ")"
  }
  Err(error = Failed(message = detail))
}

/// A sentence describing a frame error, for a log or a message to the user.
pub func frameErrorMessage(e: FrameError): String {
  match e {
    case Outdated -> "the surface no longer matches its window; configure it again"
    case Lost -> "the surface was lost; create a new one"
    case Failed(message) -> message
  }
}

/// Shows the frame on the window and releases it; use `discardFrame` instead when drawing failed.
@unsafe_ffi
pub func presentFrame(s: Surface, frame: RenderTarget): Result[Unit, String] {
  val status = wgpuSurfacePresent(longToPtr(s.raw))
  wgpuTextureViewRelease(longToPtr(frame.view))
  wgpuTextureRelease(longToPtr(frame.texture))
  if status == WGPUStatus_Success then Ok(value = ()) else Err(error = "presenting the frame failed (status " + status.toString() + ")")
}

/// Releases a frame from `tryAcquireFrame` without showing it, for when drawing into it failed.
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
