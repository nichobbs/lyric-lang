/// JVM class-file emission helpers — moved out of `Lyric.Stdlib`
/// per `docs/23-fsharp-shim-elimination.md` Phase 1 Bucket D
/// (D-progress-107).  These types are consumed only by the
/// JVM emitter's Lyric source under `compiler/lyric/jvm/`; they
/// don't belong in the stdlib bundle that ordinary user programs
/// depend on.
///
/// `JvmByteBuilder` and `JvmConstantPool` are mutable BCL objects
/// held by reference inside Lyric opaque types.  Because Lyric
/// record fields are readonly, the Lyric side never replaces the
/// reference — it only calls methods on the object through
/// `@externTarget`-routed statics in `JvmByteHost` / `JvmPoolHost`.
/// All state mutation stays in-place here.
namespace Lyric.Jvm.Hosts

open System

[<AutoOpen>]
module private JvmInternals =
 /// JVMS §4.4.7 modified UTF-8: NUL → 0xC0 0x80; supplementary code points
 /// encoded as CESU-8 surrogate pairs (each surrogate as its own 3-byte seq).
 let encodeModifiedUtf8 (s: string) : byte[] =
    let buf = System.Collections.Generic.List<byte>()
    let mutable i = 0
    while i < s.Length do
        let c = int s.[i]
        if c = 0 then
            buf.Add(0xC0uy); buf.Add(0x80uy)
            i <- i + 1
        elif c <= 0x7F then
            buf.Add(byte c)
            i <- i + 1
        elif c <= 0x7FF then
            buf.Add(byte (0xC0 ||| (c >>> 6)))
            buf.Add(byte (0x80 ||| (c &&& 0x3F)))
            i <- i + 1
        elif c >= 0xD800 && c <= 0xDBFF && i + 1 < s.Length then
            let high = c
            let low  = int s.[i + 1]
            if low >= 0xDC00 && low <= 0xDFFF then
                buf.Add(byte (0xE0 ||| (high >>> 12)))
                buf.Add(byte (0x80 ||| ((high >>> 6) &&& 0x3F)))
                buf.Add(byte (0x80 ||| (high &&& 0x3F)))
                buf.Add(byte (0xE0 ||| (low >>> 12)))
                buf.Add(byte (0x80 ||| ((low >>> 6) &&& 0x3F)))
                buf.Add(byte (0x80 ||| (low &&& 0x3F)))
                i <- i + 2
            else
                buf.Add(byte (0xE0 ||| (high >>> 12)))
                buf.Add(byte (0x80 ||| ((high >>> 6) &&& 0x3F)))
                buf.Add(byte (0x80 ||| (high &&& 0x3F)))
                i <- i + 1
        else
            buf.Add(byte (0xE0 ||| (c >>> 12)))
            buf.Add(byte (0x80 ||| ((c >>> 6) &&& 0x3F)))
            buf.Add(byte (0x80 ||| (c &&& 0x3F)))
            i <- i + 1
    buf.ToArray()

/// Mutable big-endian byte buffer for JVM class-file construction.
/// Held by reference inside `opaque type ByteWriter { inner: ByteWriter }`;
/// Lyric's readonly record fields guarantee the reference is stable while
/// mutations accumulate in-place.
type JvmByteBuilder() =
    let buf = System.Collections.Generic.List<byte>()

    member _.AppendByte(v: int) : unit =
        buf.Add(byte (v &&& 0xFF))

    member _.AppendU2Be(v: int) : unit =
        buf.Add(byte ((v >>> 8) &&& 0xFF))
        buf.Add(byte (v &&& 0xFF))

    member _.AppendU4Be(v: int) : unit =
        buf.Add(byte ((v >>> 24) &&& 0xFF))
        buf.Add(byte ((v >>> 16) &&& 0xFF))
        buf.Add(byte ((v >>> 8)  &&& 0xFF))
        buf.Add(byte (v &&& 0xFF))

    member _.AppendU8Be(v: int64) : unit =
        buf.Add(byte ((v >>> 56) &&& 0xFFL))
        buf.Add(byte ((v >>> 48) &&& 0xFFL))
        buf.Add(byte ((v >>> 40) &&& 0xFFL))
        buf.Add(byte ((v >>> 32) &&& 0xFFL))
        buf.Add(byte ((v >>> 24) &&& 0xFFL))
        buf.Add(byte ((v >>> 16) &&& 0xFFL))
        buf.Add(byte ((v >>> 8)  &&& 0xFFL))
        buf.Add(byte (v &&& 0xFFL))

    member _.AppendModifiedUtf8(s: string) : unit =
        buf.AddRange(encodeModifiedUtf8 s)

    member _.ModifiedUtf8Length(s: string) : int =
        (encodeModifiedUtf8 s).Length

    member _.AppendBytes(bs: byte[]) : unit =
        buf.AddRange(bs)

    member _.AppendByteList(bs: System.Collections.Generic.List<byte>) : unit =
        buf.AddRange(bs)

    member this.AppendWriter(src: JvmByteBuilder) : unit =
        buf.AddRange(src.ToArray())

    member _.Position : int = buf.Count

    member _.AppendU2Le(v: int) : unit =
        let u = uint32 v
        buf.Add(byte (u &&& 0xFFu))
        buf.Add(byte ((u >>> 8) &&& 0xFFu))

    member _.AppendU4Le(v: int) : unit =
        let u = uint32 v
        buf.Add(byte (u &&& 0xFFu))
        buf.Add(byte ((u >>> 8)  &&& 0xFFu))
        buf.Add(byte ((u >>> 16) &&& 0xFFu))
        buf.Add(byte ((u >>> 24) &&& 0xFFu))

    member _.AppendI8Le(v: int64) : unit =
        let u = uint64 v
        buf.Add(byte (u &&& 0xFFUL))
        buf.Add(byte ((u >>> 8)  &&& 0xFFUL))
        buf.Add(byte ((u >>> 16) &&& 0xFFUL))
        buf.Add(byte ((u >>> 24) &&& 0xFFUL))
        buf.Add(byte ((u >>> 32) &&& 0xFFUL))
        buf.Add(byte ((u >>> 40) &&& 0xFFUL))
        buf.Add(byte ((u >>> 48) &&& 0xFFUL))
        buf.Add(byte ((u >>> 56) &&& 0xFFUL))

    member _.AppendF4Le(v: float) : unit =
        let bs = System.BitConverter.GetBytes(single v)
        if System.BitConverter.IsLittleEndian then buf.AddRange(bs)
        else buf.Add(bs.[3]); buf.Add(bs.[2]); buf.Add(bs.[1]); buf.Add(bs.[0])

    member _.AppendF8Le(v: float) : unit =
        let bs = System.BitConverter.GetBytes(v)
        if System.BitConverter.IsLittleEndian then buf.AddRange(bs)
        else for i in 7 .. -1 .. 0 do buf.Add(bs.[i])

    member _.PatchU2Be(offset: int, v: int) : unit =
        buf.[offset]   <- byte ((v >>> 8) &&& 0xFF)
        buf.[offset+1] <- byte (v &&& 0xFF)

    member _.PatchU4Be(offset: int, v: int) : unit =
        buf.[offset]   <- byte ((v >>> 24) &&& 0xFF)
        buf.[offset+1] <- byte ((v >>> 16) &&& 0xFF)
        buf.[offset+2] <- byte ((v >>> 8)  &&& 0xFF)
        buf.[offset+3] <- byte (v &&& 0xFF)

    member _.ToArray() : byte[] = buf.ToArray()

    member _.ToList() : System.Collections.Generic.List<byte> =
        let r = System.Collections.Generic.List<byte>(buf.Count)
        r.AddRange(buf)
        r

/// Static shim routing Lyric `@externTarget` calls to `JvmByteBuilder`.
[<Sealed; AbstractClass>]
type JvmByteHost private () =

    static member New() : JvmByteBuilder = JvmByteBuilder()

    static member AppendByte(w: JvmByteBuilder, v: int) : unit =
        w.AppendByte(v)

    static member AppendU2Be(w: JvmByteBuilder, v: int) : unit =
        w.AppendU2Be(v)

    static member AppendU4Be(w: JvmByteBuilder, v: int) : unit =
        w.AppendU4Be(v)

    static member AppendU8Be(w: JvmByteBuilder, v: int64) : unit =
        w.AppendU8Be(v)

    static member AppendModifiedUtf8(w: JvmByteBuilder, s: string) : unit =
        w.AppendModifiedUtf8(s)

    static member ModifiedUtf8Length(w: JvmByteBuilder, s: string) : int =
        w.ModifiedUtf8Length(s)

    static member AppendBytes(w: JvmByteBuilder, bs: byte[]) : unit =
        w.AppendBytes(bs)

    static member AppendByteList
            (w: JvmByteBuilder,
             bs: System.Collections.Generic.List<byte>) : unit =
        w.AppendByteList(bs)

    static member AppendWriter(w: JvmByteBuilder, src: JvmByteBuilder) : unit =
        w.AppendWriter(src)

    static member Position(w: JvmByteBuilder) : int = w.Position

    static member PatchU2Be(w: JvmByteBuilder, offset: int, v: int) : unit =
        w.PatchU2Be(offset, v)

    static member PatchU4Be(w: JvmByteBuilder, offset: int, v: int) : unit =
        w.PatchU4Be(offset, v)

    static member ToBytes(w: JvmByteBuilder) : byte[] = w.ToArray()

    static member AppendU2Le(w: JvmByteBuilder, v: int) : unit =
        w.AppendU2Le(v)

    static member AppendU4Le(w: JvmByteBuilder, v: int) : unit =
        w.AppendU4Le(v)

    static member AppendI8Le(w: JvmByteBuilder, v: int64) : unit =
        w.AppendI8Le(v)

    static member AppendF4Le(w: JvmByteBuilder, v: float) : unit =
        w.AppendF4Le(v)

    static member AppendF8Le(w: JvmByteBuilder, v: float) : unit =
        w.AppendF8Le(v)

    static member ToList
            (w: JvmByteBuilder) : System.Collections.Generic.List<byte> =
        w.ToList()

/// CRC32 (ISO 3309, reflected polynomial 0xEDB88320) and ZIP assembly helpers.
[<Sealed; AbstractClass>]
type JvmZipHost private () =

    // Pre-computed CRC32 lookup table (reflected polynomial 0xEDB88320).
    static let crcTable : uint32[] =
        let t = Array.zeroCreate 256
        for i in 0..255 do
            let mutable c = uint32 i
            for _ in 0..7 do
                if c &&& 1u <> 0u then c <- (c >>> 1) ^^^ 0xEDB88320u
                else c <- c >>> 1
            t.[i] <- c
        t

    /// CRC32 of a `List<byte>`.  Returns the checksum as a signed int32
    /// (the bit pattern is identical to the unsigned CRC32 value).
    static member Crc32(data: System.Collections.Generic.List<byte>) : int =
        let mutable crc = 0xFFFFFFFFu
        for b in data do
            let idx = int ((crc ^^^ uint32 b) &&& 0xFFu)
            crc <- (crc >>> 8) ^^^ crcTable.[idx]
        int (crc ^^^ 0xFFFFFFFFu)

/// JVM constant pool builder (JVMS §4.4).
/// Long / Double entries occupy two pool slots (nextSlot += 2);
/// phantom `[||]` entries in the entry list mark the second slot so
/// `WriteTo` can skip them while writing a single pool entry.
type JvmConstantPool() =
    let entries = System.Collections.Generic.List<byte[]>()
    let cache   = System.Collections.Generic.Dictionary<string, int>()
    let mutable nextSlot = 1

    member private _.Add(key: string, data: byte[]) : int =
        let slot = nextSlot
        entries.Add(data)
        cache.[key] <- slot
        nextSlot <- nextSlot + 1
        slot

    member private this.Add2(key: string, data: byte[]) : int =
        let slot = nextSlot
        entries.Add(data)
        entries.Add([||])   // phantom: marks second slot as consumed
        cache.[key] <- slot
        nextSlot <- nextSlot + 2
        slot

    member _.Count : int = nextSlot - 1

    member this.Utf8(s: string) : int =
        let key = "1:" + s
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let encoded = encodeModifiedUtf8 s
            if encoded.Length > 65535 then
                failwithf "Utf8 constant too long: %d bytes" encoded.Length
            let hd = [| 1uy; byte (encoded.Length >>> 8); byte (encoded.Length &&& 0xFF) |]
            let data = Array.append hd encoded
            this.Add(key, data)

    member this.Integer(v: int) : int =
        let key = "3:" + string v
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let data = [| 3uy
                          byte ((v >>> 24) &&& 0xFF); byte ((v >>> 16) &&& 0xFF)
                          byte ((v >>> 8)  &&& 0xFF); byte (v &&& 0xFF) |]
            this.Add(key, data)

    member this.Float_(v: float) : int =
        let key = "4:" + string (float32 v)
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let bits = System.BitConverter.SingleToInt32Bits(float32 v)
            let data = [| 4uy
                          byte ((bits >>> 24) &&& 0xFF); byte ((bits >>> 16) &&& 0xFF)
                          byte ((bits >>> 8)  &&& 0xFF); byte (bits &&& 0xFF) |]
            this.Add(key, data)

    member this.Long_(v: int64) : int =
        let key = "5:" + string v
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let data = [| 5uy
                          byte ((v >>> 56) &&& 0xFFL); byte ((v >>> 48) &&& 0xFFL)
                          byte ((v >>> 40) &&& 0xFFL); byte ((v >>> 32) &&& 0xFFL)
                          byte ((v >>> 24) &&& 0xFFL); byte ((v >>> 16) &&& 0xFFL)
                          byte ((v >>> 8)  &&& 0xFFL); byte (v &&& 0xFFL) |]
            this.Add2(key, data)

    member this.Double_(v: float) : int =
        let key = "6:" + string v
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let bits = System.BitConverter.DoubleToInt64Bits(v)
            let data = [| 6uy
                          byte ((bits >>> 56) &&& 0xFFL); byte ((bits >>> 48) &&& 0xFFL)
                          byte ((bits >>> 40) &&& 0xFFL); byte ((bits >>> 32) &&& 0xFFL)
                          byte ((bits >>> 24) &&& 0xFFL); byte ((bits >>> 16) &&& 0xFFL)
                          byte ((bits >>> 8)  &&& 0xFFL); byte (bits &&& 0xFFL) |]
            this.Add2(key, data)

    member this.Class_(name: string) : int =
        let key = "7:" + name
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let nIdx = this.Utf8(name)
            let data = [| 7uy; byte (nIdx >>> 8); byte (nIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.String_(s: string) : int =
        let key = "8:" + s
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let sIdx = this.Utf8(s)
            let data = [| 8uy; byte (sIdx >>> 8); byte (sIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.NameAndType(name: string, descriptor: string) : int =
        let key = "12:" + name + ":" + descriptor
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let nIdx = this.Utf8(name)
            let dIdx = this.Utf8(descriptor)
            let data = [| 12uy; byte (nIdx >>> 8); byte (nIdx &&& 0xFF);
                                 byte (dIdx >>> 8); byte (dIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.Fieldref(className: string, name: string, desc: string) : int =
        let key = "9:" + className + "." + name + ":" + desc
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let cIdx = this.Class_(className)
            let nIdx = this.NameAndType(name, desc)
            let data = [| 9uy; byte (cIdx >>> 8); byte (cIdx &&& 0xFF);
                               byte (nIdx >>> 8); byte (nIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.Methodref(className: string, name: string, desc: string) : int =
        let key = "10:" + className + "." + name + ":" + desc
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let cIdx = this.Class_(className)
            let nIdx = this.NameAndType(name, desc)
            let data = [| 10uy; byte (cIdx >>> 8); byte (cIdx &&& 0xFF);
                                byte (nIdx >>> 8); byte (nIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.InterfaceMethodref
            (className: string, name: string, desc: string) : int =
        let key = "11:" + className + "." + name + ":" + desc
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let cIdx = this.Class_(className)
            let nIdx = this.NameAndType(name, desc)
            let data = [| 11uy; byte (cIdx >>> 8); byte (cIdx &&& 0xFF);
                                byte (nIdx >>> 8); byte (nIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.MethodHandle
            (refKind: int, className: string,
             name: string, desc: string) : int =
        let key = "15:" + string refKind + ":" + className + "." + name + ":" + desc
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let refIdx = this.Methodref(className, name, desc)
            let data = [| 15uy; byte refKind;
                                byte (refIdx >>> 8); byte (refIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.MethodType(descriptor: string) : int =
        let key = "16:" + descriptor
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let dIdx = this.Utf8(descriptor)
            let data = [| 16uy; byte (dIdx >>> 8); byte (dIdx &&& 0xFF) |]
            this.Add(key, data)

    member this.InvokeDynamic
            (bmIdx: int, name: string, descriptor: string) : int =
        let key = "18:" + string bmIdx + ":" + name + ":" + descriptor
        match cache.TryGetValue(key) with
        | true, slot -> slot
        | _ ->
            let nIdx = this.NameAndType(name, descriptor)
            let data = [| 18uy; byte (bmIdx >>> 8); byte (bmIdx &&& 0xFF);
                                byte (nIdx >>> 8); byte (nIdx &&& 0xFF) |]
            this.Add(key, data)

    /// Write constant_pool_count then all non-phantom entries to `out`.
    member _.WriteTo(out: JvmByteBuilder) : unit =
        out.AppendU2Be(nextSlot)   // JVMS: count = next available index
        for entry in entries do
            if entry.Length > 0 then   // skip phantom Long/Double second slots
                out.AppendBytes(entry)

/// Static shim routing Lyric `@externTarget` calls to `JvmConstantPool`.
[<Sealed; AbstractClass>]
type JvmPoolHost private () =

    static member New() : JvmConstantPool = JvmConstantPool()

    static member Utf8(pool: JvmConstantPool, s: string) : int =
        pool.Utf8(s)

    static member Integer(pool: JvmConstantPool, v: int) : int =
        pool.Integer(v)

    static member Float_(pool: JvmConstantPool, v: float) : int =
        pool.Float_(v)

    static member Long_(pool: JvmConstantPool, v: int64) : int =
        pool.Long_(v)

    static member Double_(pool: JvmConstantPool, v: float) : int =
        pool.Double_(v)

    static member Class_(pool: JvmConstantPool, name: string) : int =
        pool.Class_(name)

    static member String_(pool: JvmConstantPool, s: string) : int =
        pool.String_(s)

    static member NameAndType
            (pool: JvmConstantPool,
             name: string, descriptor: string) : int =
        pool.NameAndType(name, descriptor)

    static member Fieldref
            (pool: JvmConstantPool,
             className: string, name: string, desc: string) : int =
        pool.Fieldref(className, name, desc)

    static member Methodref
            (pool: JvmConstantPool,
             className: string, name: string, desc: string) : int =
        pool.Methodref(className, name, desc)

    static member InterfaceMethodref
            (pool: JvmConstantPool,
             className: string, name: string, desc: string) : int =
        pool.InterfaceMethodref(className, name, desc)

    static member MethodHandle
            (pool: JvmConstantPool,
             refKind: int, className: string,
             name: string, desc: string) : int =
        pool.MethodHandle(refKind, className, name, desc)

    static member MethodType
            (pool: JvmConstantPool, descriptor: string) : int =
        pool.MethodType(descriptor)

    static member InvokeDynamic
            (pool: JvmConstantPool,
             bmIdx: int, name: string, descriptor: string) : int =
        pool.InvokeDynamic(bmIdx, name, descriptor)

    static member WriteTo
            (pool: JvmConstantPool, out: JvmByteBuilder) : unit =
        pool.WriteTo(out)

    static member Count(pool: JvmConstantPool) : int =
        pool.Count
