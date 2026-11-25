//! stdlib/tests/http_h2fuzz_tests.l — seeded property and fuzz suite for the
//! sans-IO HTTP/2 engine: the frame codec (`Std.HttpEngine.H2Frame`), HPACK
//! (`Std.HttpEngine.Hpack`) and `Std.HttpEngine.H2Conn` in both roles
//! (docs/72 slice 2, D801).
//!
//! Three properties, each checked over many generated inputs:
//!
//!   - **Chunking invariance.** The same bytes fed in one call, one byte at a
//!     time, or in random splits yield identical events and identical
//!     outbound bytes (the engine is boundary-agnostic by contract).
//!   - **Mutation robustness.** Valid wire scripts with bit flips,
//!     truncations, deletions, insertions and duplicated ranges, and streams
//!     of random raw frames, never panic. Every run either continues or fails
//!     the connection with a connection error; after each feed the connection
//!     still satisfies its structural invariants (bounded decoder buffer,
//!     bounded header-block buffer, bounded stream table, window ceilings,
//!     outbound that is itself a well-formed frame sequence, no more than a
//!     small constant of amplification).
//!   - **Bounded work on adversarial input.** Rapid Reset, malformed-request
//!     floods, CONTINUATION floods, oversized header lists, HPACK bombs,
//!     oversized frame declarations, byte-at-a-time dribbling, and PING and
//!     SETTINGS floods are shown to hit a limit (a connection error, or a
//!     structurally bounded table) instead of growing without limit.
//!
//! Every generated input is a pure function of an integer seed, so a failure
//! is reproducible: each case runs under `trapPanic`, and a panic or failed
//! assertion is rethrown with `seed=<n>` and the suite name. Defaults are
//! sized for CI; set `LYRIC_H2_FUZZ_ITERS` (iterations per property, default
//! 40) for a long run and `LYRIC_H2_FUZZ_SEED` (base seed, default 7200) to
//! replay a reported seed with `LYRIC_H2_FUZZ_ITERS=1`.
@test_module
package Std.HttpEngine.H2Fuzz.Tests

import Std.Core
import Std.Collections
import Std.Parse
import Std.Environment as Env
import Std.PanicTrapHost
import Std.HttpEngine
import Std.HttpEngine.H2Frame
import Std.HttpEngine.Hpack
import Std.HttpEngine.H2Conn as H2
import Std.Testing

// ---------------------------------------------------------------------------
// Seeded generator (Park-Miller; every product fits a Long, so the stream is
// identical on every target).
// ---------------------------------------------------------------------------
ref record Rng {
  var s: Long
}

func newRng(seed: in Int): Rng {
  Rng(s = (seed.toLong() % 2147483646i64) + 1i64)
}

func rnd(r: in Rng, bound: in Int): Int {
  r.s = (r.s * 48271i64) % 2147483647i64;
  ((r.s / 16i64) % bound.toLong()).toInt()
}

func rndBool(r: in Rng): Bool {
  rnd(r, 2) == 0
}

func envInt(name: in String, dflt: in Int): Int {
  match parseOptInt(Env.getVarOrDefault(name, "")) {
    case Some(n) -> n
    case None -> dflt
  }
}

func iterations(): Int {
  envInt("LYRIC_H2_FUZZ_ITERS", 40)
}

func baseSeed(): Int {
  envInt("LYRIC_H2_FUZZ_SEED", 7200)
}

/// Run one generated case under `trapPanic` so a panic or failed assertion
/// carries the suite name and seed that reproduce it.
func runCase(suite: in String, seed: in Int, body: in () -> Unit): Unit {
  match trapPanic(body) {
    case PtRan -> ()
    case PtPanicked(m) -> panic(suite + ": FAILED, seed=" + seed.toString() + ": " + m)
    case PtFailed(why) -> panic(suite + ": trap failed, seed=" + seed.toString() + ": " + why)
  }
}

// ---------------------------------------------------------------------------
// Byte helpers.
// ---------------------------------------------------------------------------
func emptyBytes(): slice[Byte] {
  val e: slice[Byte] = []
  e
}

func newBytesList(): List[Byte] {
  val l: List[Byte] = newList()
  l
}

func appendAll(dst: in List[Byte], src: in slice[Byte]): Unit {
  var i = 0
  while i < src.length {
    dst.add(src[i])
    i = i + 1
  }
}

func rndBytes(r: in Rng, n: in Int): slice[Byte] {
  val acc = newBytesList()
  var i = 0
  while i < n {
    acc.add(rnd(r, 256).toByte())
    i = i + 1
  }
  acc.toArray()
}

func fillBytes(n: in Int, fill: in Int): slice[Byte] {
  val acc = newBytesList()
  var i = 0
  while i < n {
    acc.add(fill.and(255).toByte())
    i = i + 1
  }
  acc.toArray()
}

/// A short, collision-resistant-enough summary of a byte string for comparing
/// two runs without building huge strings.
func digest(b: in slice[Byte]): String {
  var h = 17i64
  var i = 0
  while i < b.length {
    h = (h * 31i64 + b[i].toInt().toLong() + 1i64) % 1000000007i64
    i = i + 1
  }
  b.length.toString() + "/" + h.toString()
}

func hf(name: in String, value: in String): HeaderField {
  HeaderField(name = name, value = value)
}

func showHeaders(hs: in List[HeaderField]): String {
  var acc = ""
  var i = 0
  while i < hs.count {
    val h: HeaderField = hs[i]
    acc = acc + h.name + ":" + h.value + "|"
    i = i + 1
  }
  acc
}

func rawFrame(ftype: in Int, flags: in Int, sid: in Int, payload: in slice[Byte]): slice[Byte] {
  serializeFrameHeader(H2FrameHeader(length = payload.length, frameType = ftype, flags = flags, streamId = sid)).concat(
    payload
  )
}

// ---------------------------------------------------------------------------
// Random HPACK-able header lists.
// ---------------------------------------------------------------------------
func rndToken(r: in Rng, maxLen: in Int): String {
  val letters = "abcdefghijklmnopqrstuvwxyz0123456789-"
  var s = ""
  val n = 1 + rnd(r, maxLen)
  var i = 0
  while i < n {
    val k = rnd(r, 37)
    s = s + letters.substring(k, 1)
    i = i + 1
  }
  s
}

func rndValue(r: in Rng, maxLen: in Int): String {
  var s = ""
  val n = rnd(r, maxLen + 1)
  var i = 0
  while i < n {
    val c = 32 + rnd(r, 95)
    s = s + c.toChar().toString()
    i = i + 1
  }
  s
}

func rndHeaderList(r: in Rng): List[HeaderField] {
  val pool = ["content-type", "user-agent", "accept", "x-trace", "grpc-timeout", "cookie", "authorization"]
  val h: List[HeaderField] = newList()
  val n = 1 + rnd(r, 8)
  var i = 0
  while i < n {
    val name = if rnd(r, 3) == 0 { rndToken(r, 20) } else { pool[rnd(r, 7)] }
    val value = if rnd(r, 8) == 0 { rndValue(r, 300) } else { rndValue(r, 30) }
    h.add(hf(name, value))
    i = i + 1
  }
  h
}

func encodeBlockWith(enc: in HpackEncoder, headers: in List[HeaderField]): slice[Byte] {
  match encodeHeaderList(enc, headers) {
    case Ok(b) -> {
      val block: slice[Byte] = b
      block
    }
    case Err(_) -> emptyBytes()
  }
}

func requestHeaders(r: in Rng): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":method", if rndBool(r) { "POST" } else { "GET" }))
  h.add(hf(":scheme", "https"))
  h.add(hf(":path", "/svc/" + rndToken(r, 10)))
  h.add(hf(":authority", "example.test"))
  val extra = rnd(r, 4)
  var i = 0
  while i < extra {
    h.add(hf("x-" + rndToken(r, 8), rndValue(r, 40)))
    i = i + 1
  }
  h
}

func responseHeaders(r: in Rng): List[HeaderField] {
  val h: List[HeaderField] = newList()
  h.add(hf(":status", "200"))
  h.add(hf("content-type", "application/grpc"))
  val extra = rnd(r, 3)
  var i = 0
  while i < extra {
    h.add(hf("x-" + rndToken(r, 8), rndValue(r, 40)))
    i = i + 1
  }
  h
}

func headersFrame(sid: in Int, block: in slice[Byte], endStream: in Bool, endHeaders: in Bool): slice[Byte] {
  val none: Option[PriorityInfo] = None
  serializeFrame(
    HeadersFrame(
      streamId = sid,
      headerBlockFragment = block,
      endStream = endStream,
      endHeaders = endHeaders,
      priority = none
    )
  )
}

func continuationFrame(sid: in Int, block: in slice[Byte], endHeaders: in Bool): slice[Byte] {
  serializeFrame(ContinuationFrame(streamId = sid, headerBlockFragment = block, endHeaders = endHeaders))
}

func dataFrame(sid: in Int, data: in slice[Byte], endStream: in Bool): slice[Byte] {
  serializeFrame(DataFrame(streamId = sid, data = data, endStream = endStream, wireLength = data.length))
}

func emptySettingsFrame(): slice[Byte] {
  val p: List[SettingsParam] = newList()
  serializeFrame(SettingsFrame(settings = p, ack = false))
}

/// HEADERS, then CONTINUATION frames when `split` and the block is long enough.
func headerBlockFrames(sid: in Int, block: in slice[Byte], endStream: in Bool, split: in Bool): slice[Byte] {
  if split and block.length > 4 {
    val cut = block.length / 2
    headersFrame(sid, block.slice(0, cut), endStream, false).concat(
      continuationFrame(sid, block.slice(cut, block.length), true)
    )
  } else {
    headersFrame(sid, block, endStream, true)
  }
}

func without(src: in List[Int], idx: in Int): List[Int] {
  val acc0: List[Int] = newList()
  var i = 0
  while i < src.count {
    if i != idx {
      acc0.add(src[i])
    }
    i = i + 1
  }
  acc0
}

// ---------------------------------------------------------------------------
// Wire scripts. A server-role script is what a client sends (preface first); a
// client-role script is what a server sends to a client that already opened
// streams 1, 3, .. 2n-1 (see `newClientWithStreams`).
// ---------------------------------------------------------------------------
func genServerScript(r: in Rng): slice[Byte] {
  val acc0 = newBytesList()
  appendAll(acc0, connectionPreface())
  appendAll(acc0, emptySettingsFrame())
  val enc = newEncoder(4096, rndBool(r))
  var open: List[Int] = newList()
  var nextSid = 1
  val ops = 3 + rnd(r, 14)
  var i = 0
  while i < ops {
    val k = rnd(r, 10)
    if k < 4 {
      val sid = nextSid
      nextSid = nextSid + 2
      val endS = rnd(r, 3) == 0
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, requestHeaders(r)), endS, rnd(r, 3) == 0))
      if not endS {
        open.add(sid)
      }
    } else if k < 7 and open.count > 0 {
      val idx = rnd(r, open.count)
      val endS = rnd(r, 3) == 0
      val len = if rnd(r, 12) == 0 { 16384 } else { rnd(r, 3000) }
      appendAll(acc0, dataFrame(open[idx], fillBytes(len, rnd(r, 256)), endS))
      if endS {
        open = without(open, idx)
      }
    } else if k == 7 {
      appendAll(acc0, serializeFrame(PingFrame(opaqueData = rndBytes(r, 8), ack = false)))
    } else if k == 8 {
      val sid = if open.count > 0 and rndBool(r) { open[rnd(r, open.count)] } else { 0 }
      appendAll(acc0, serializeFrame(WindowUpdateFrame(streamId = sid, windowSizeIncrement = 1 + rnd(r, 100000))))
    } else if open.count > 0 {
      val idx = rnd(r, open.count)
      appendAll(acc0, serializeFrame(RstStreamFrame(streamId = open[idx], errorCode = H2Cancel)))
      open = without(open, idx)
    } else {
      appendAll(
        acc0,
        serializeFrame(
          PriorityFrame(streamId = 1, priority = PriorityInfo(exclusive = false, streamDependency = 0, weight = 16))
        )
      )
    }
    i = i + 1
  }
  if rnd(r, 6) == 0 {
    appendAll(acc0, serializeFrame(GoAwayFrame(lastStreamId = 0, errorCode = H2NoError, debugData = emptyBytes())))
  }
  acc0.toArray()
}

func clientStreamCount(r: in Rng): Int {
  1 + rnd(r, 4)
}

/// A client past its handshake with `n` open requests (ids 1, 3, ..). Both the
/// whole-feed and chunked runs build theirs through this one function, so the
/// two connections start identical.
func newClientWithStreams(n: in Int): H2.H2Connection {
  val c = H2.newClientConnection(H2.h2DefaultClientSettings())
  val s = H2.newServerConnection(H2.h2DefaultServerSettings())
  val hs = H2.feed(c, H2.serverInitialFrame(s))
  val h: List[HeaderField] = newList()
  h.add(hf(":method", "POST"))
  h.add(hf(":scheme", "https"))
  h.add(hf(":path", "/svc/Method"))
  h.add(hf(":authority", "example.test"))
  var i = 0
  while i < n {
    match H2.openStream(c, h, i % 2 == 1) {
      case Ok(_) -> ()
      case Err(_) -> assertTrue(false, "openStream refused during setup")
    }
    i = i + 1
  }
  c
}

func genClientScript(r: in Rng, n: in Int): slice[Byte] {
  val acc0 = newBytesList()
  appendAll(acc0, emptySettingsFrame())
  val enc = newEncoder(4096, rndBool(r))
  var s = 0
  while s < n {
    val sid = 1 + 2 * s
    val scenario = rnd(r, 6)
    val trailers: List[HeaderField] = newList()
    trailers.add(hf("grpc-status", "0"))
    trailers.add(hf("grpc-message", rndToken(r, 12)))
    if scenario == 0 {
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, responseHeaders(r)), false, rnd(r, 3) == 0))
      val chunks = rnd(r, 4)
      var c = 0
      while c < chunks {
        appendAll(acc0, dataFrame(sid, fillBytes(rnd(r, 2500), rnd(r, 256)), false))
        c = c + 1
      }
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, trailers), true, rnd(r, 3) == 0))
    } else if scenario == 1 {
      val h: List[HeaderField] = newList()
      h.add(hf(":status", "200"))
      h.add(hf("grpc-status", "5"))
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, h), true, false))
    } else if scenario == 2 {
      val info: List[HeaderField] = newList()
      info.add(hf(":status", "100"))
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, info), false, false))
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, responseHeaders(r)), false, false))
      appendAll(acc0, dataFrame(sid, fillBytes(rnd(r, 500), 3), true))
    } else if scenario == 3 {
      appendAll(acc0, serializeFrame(RstStreamFrame(streamId = sid, errorCode = H2RefusedStream)))
    } else if scenario == 4 {
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, responseHeaders(r)), false, true))
      appendAll(acc0, dataFrame(sid, fillBytes(rnd(r, 100), 1), true))
    } else {
      appendAll(acc0, serializeFrame(PingFrame(opaqueData = rndBytes(r, 8), ack = false)))
      appendAll(acc0, serializeFrame(WindowUpdateFrame(streamId = sid, windowSizeIncrement = 1 + rnd(r, 1000))))
      appendAll(acc0, headerBlockFrames(sid, encodeBlockWith(enc, responseHeaders(r)), true, false))
    }
    s = s + 1
  }
  if rnd(r, 6) == 0 {
    appendAll(
      acc0,
      serializeFrame(GoAwayFrame(lastStreamId = 2 * n - 1, errorCode = H2NoError, debugData = emptyBytes()))
    )
  }
  acc0.toArray()
}

/// Random raw frames: any type, any flags, any stream id, payload lengths that
/// sometimes match the fixed size of the type and sometimes do not.
func genRawFrames(r: in Rng, withPreface: in Bool): slice[Byte] {
  val acc0 = newBytesList()
  if withPreface {
    appendAll(acc0, connectionPreface())
    appendAll(acc0, emptySettingsFrame())
  }
  val n = 2 + rnd(r, 20)
  var i = 0
  while i < n {
    val ftype = if rnd(r, 8) == 0 { rnd(r, 256) } else { rnd(r, 11) }
    val sid = if rnd(r, 5) == 0 { 0 } else if rnd(r, 8) == 0 { rnd(r, 100000000) * 8 + rnd(r, 8) } else { 1 + rnd(r, 8) }
    val len = if rnd(r, 2) == 0 {
      if ftype == 6 {
        8
      } else if ftype == 3 or ftype == 8 {
        4
      } else if ftype == 2 {
        5
      } else {
        rnd(r, 40)
      }
    } else {
      rnd(r, 40)
    }
    appendAll(acc0, rawFrame(ftype, rnd(r, 256), sid, rndBytes(r, len)))
    i = i + 1
  }
  acc0.toArray()
}

func mutate(r: in Rng, bytes: in slice[Byte]): slice[Byte] {
  var cur = bytes
  val n = 1 + rnd(r, 3)
  var m = 0
  while m < n {
    val len = cur.length
    if len == 0 {
      return cur
    }
    val op = rnd(r, 6)
    if op == 0 {
      val acc = newBytesList()
      appendAll(acc, cur)
      val pos = rnd(r, len)
      acc[pos] = (acc[pos].toInt().xor(1.shl(rnd(r, 8)))).and(255).toByte()
      cur = acc.toArray()
    } else if op == 1 {
      cur = cur.slice(0, rnd(r, len))
    } else if op == 2 {
      val a = rnd(r, len)
      val b = a + rnd(r, len - a + 1)
      cur = cur.slice(0, a).concat(cur.slice(b, len))
    } else if op == 3 {
      val a = rnd(r, len + 1)
      cur = cur.slice(0, a).concat(rndBytes(r, 1 + rnd(r, 12))).concat(cur.slice(a, len))
    } else if op == 4 {
      val a = rnd(r, len)
      val b = a + rnd(r, len - a + 1)
      cur = cur.slice(0, b).concat(cur.slice(a, len))
    } else {
      val acc = newBytesList()
      appendAll(acc, cur)
      acc[rnd(r, len)] = (if rndBool(r) { 255 } else { 0 }).toByte()
      cur = acc.toArray()
    }
    m = m + 1
  }
  cur
}

/// Chunk sizes: 0 whole, 1 one byte, 2 random 1..64, 3 random 1..4096.
func nextChunk(r: in Rng, mode: in Int, remaining: in Int): Int {
  val want = if mode == 0 {
    remaining
  } else if mode == 1 {
    1
  } else if mode == 2 {
    1 + rnd(r, 64)
  } else {
    1 + rnd(r, 4096)
  }
  if want > remaining {
    remaining
  } else {
    want
  }
}

// ---------------------------------------------------------------------------
// Frame codec properties.
// ---------------------------------------------------------------------------
func showFrameEvent(ev: in FrameDecodeEvent): String {
  match ev {
    case FrameNeedMore -> ""
    case PrefaceReceived -> "preface;"
    case FrameDecoded(f) -> digest(serializeFrame(f)) + ";"
    case FrameFailed(e) -> "fail(" + errorCodeToLong(e.code).toString() + "," + e.connectionError.toString() + "," +
      e.message +
      ");"
  }
}

/// Decode `bytes` in chunks; returns the rendered event trace.
func decodeTrace(r: in Rng, bytes: in slice[Byte], mode: in Int, expectPreface: in Bool): String {
  var dec = newFrameDecoder(expectPreface)
  var trace = ""
  var pos = 0
  while pos < bytes.length and not isDecoderFailed(dec) {
    val n = nextChunk(r, mode, bytes.length - pos)
    val res = feedFrames(dec, bytes.slice(pos, pos + n))
    dec = res.decoder
    var i = 0
    while i < res.events.count {
      trace = trace + showFrameEvent(res.events[i])
      i = i + 1
    }
    assertTrue(
      dec.buf.length - dec.pos <= 9 + defaultMaxFrameSize() + 24,
      "decoder buffer bounded (" + (dec.buf.length - dec.pos).toString() + ")"
    )
    pos = pos + n
  }
  trace
}

func rndPriority(r: in Rng): PriorityInfo {
  PriorityInfo(exclusive = rndBool(r), streamDependency = rnd(r, 1000), weight = 1 + rnd(r, 256))
}

func rndValidFrame(r: in Rng): H2Frame {
  val k = rnd(r, 11)
  val sid = 1 + rnd(r, 1000000)
  if k == 0 {
    val d = rndBytes(r, rnd(r, 200))
    DataFrame(streamId = sid, data = d, endStream = rndBool(r), wireLength = d.length)
  } else if k == 1 {
    val prio: Option[PriorityInfo] = if rndBool(r) { Some(value = rndPriority(r)) } else { None }
    HeadersFrame(
      streamId = sid,
      headerBlockFragment = rndBytes(r, rnd(r, 100)),
      endStream = rndBool(r),
      endHeaders = rndBool(r),
      priority = prio
    )
  } else if k == 2 {
    PriorityFrame(streamId = sid, priority = rndPriority(r))
  } else if k == 3 {
    RstStreamFrame(streamId = sid, errorCode = errorCodeFromLong(rnd(r, 20).toLong()))
  } else if k == 4 {
    val ps: List[SettingsParam] = newList()
    val n = rnd(r, 4)
    var i = 0
    while i < n {
      ps.add(SettingsParam(id = settingsIdFromInt(1 + rnd(r, 6)), value = rnd(r, 100000).toLong()))
      i = i + 1
    }
    SettingsFrame(settings = ps, ack = false)
  } else if k == 5 {
    PushPromiseFrame(
      streamId = sid,
      promisedStreamId = 2 + 2 * rnd(r, 1000),
      headerBlockFragment = rndBytes(r, rnd(r, 60)),
      endHeaders = rndBool(r)
    )
  } else if k == 6 {
    PingFrame(opaqueData = rndBytes(r, 8), ack = rndBool(r))
  } else if k == 7 {
    GoAwayFrame(
      lastStreamId = rnd(r, 100000),
      errorCode = errorCodeFromLong(rnd(r, 16).toLong()),
      debugData = rndBytes(r, rnd(r, 30))
    )
  } else if k == 8 {
    WindowUpdateFrame(streamId = rnd(r, 1000), windowSizeIncrement = 1 + rnd(r, 2000000))
  } else if k == 9 {
    ContinuationFrame(streamId = sid, headerBlockFragment = rndBytes(r, rnd(r, 100)), endHeaders = rndBool(r))
  } else {
    UnknownFrame(
      header = H2FrameHeader(length = 0, frameType = 10 + rnd(r, 240), flags = rnd(r, 256), streamId = rnd(r, 1000)),
      payload = emptyBytes()
    )
  }
}

test "frame codec: random valid frames round-trip and decode identically under any chunking" {
  var it = 0
  while it < iterations() {
    val seed = baseSeed() + it
    runCase(
      "frame round-trip",
      seed,
      { ->
        val r = newRng(seed)
        val n = 1 + rnd(r, 12)
        val all = newBytesList()
        var expected = ""
        var i = 0
        while i < n {
          val f = rndValidFrame(r)
          val bytes = serializeFrame(f)
          appendAll(all, bytes)
          expected = expected + digest(bytes) + ";"
          i = i + 1
        }
        val input = all.toArray()
        assertEqual(decodeTrace(r, input, 0, false), expected, "whole feed re-serializes every frame")
        assertEqual(decodeTrace(r, input, 1, false), expected, "byte at a time")
        assertEqual(decodeTrace(r, input, 2, false), expected, "random small chunks")
        assertEqual(decodeTrace(r, input, 3, false), expected, "random large chunks")
      }
    )
    it = it + 1
  }
}

test "frame codec: mutated and random frame streams never panic and decode identically under any chunking" {
  var it = 0
  while it < iterations() {
    val seed = baseSeed() + 1000 + it
    runCase(
      "frame mutation",
      seed,
      { ->
        val r = newRng(seed)
        val n = 1 + rnd(r, 10)
        val all = newBytesList()
        var i = 0
        while i < n {
          appendAll(all, serializeFrame(rndValidFrame(r)))
          i = i + 1
        }
        val input = if rnd(r, 3) == 0 { genRawFrames(r, false) } else { mutate(r, all.toArray()) }
        val whole = decodeTrace(r, input, 0, false)
        assertEqual(decodeTrace(r, input, 1, false), whole, "byte at a time")
        assertEqual(decodeTrace(r, input, 2, false), whole, "random small chunks")
        assertEqual(decodeTrace(r, input, 3, false), whole, "random large chunks")
      }
    )
    it = it + 1
  }
}

test "frame codec: an oversized declared length is rejected from the header alone" {
  val lens = [16385, 65536, 1048576, 16777215]
  var i = 0
  while i < lens.length {
    val header = serializeFrameHeader(H2FrameHeader(length = lens[i], frameType = 0, flags = 0, streamId = 1))
    val res = feedFrames(newFrameDecoder(false), header)
    var failed = false
    var j = 0
    while j < res.events.count {
      match res.events[j] {
        case FrameFailed(e) -> {
          failed = true
          assertEqualLong(errorCodeToLong(e.code), errorCodeToLong(H2FrameSizeError), "FRAME_SIZE_ERROR")
          assertTrue(e.connectionError, "connection error")
        }
        case _ -> ()
      }
      j = j + 1
    }
    assertTrue(failed, "declared length " + lens[i].toString() + " fails before any payload byte")
    i = i + 1
  }
}

// ---------------------------------------------------------------------------
// HPACK properties.
// ---------------------------------------------------------------------------
func tableLimitOk(dec: in HpackDecoder): Unit {
  val t = decoderDynamicTable(dec)
  assertTrue(dynamicTableSize(t) <= dynamicTableMaxSize(t), "dynamic table within its limit")
}

func listWireSize(hs: in List[HeaderField]): Int {
  var n = 0
  var i = 0
  while i < hs.count {
    val h: HeaderField = hs[i]
    n = n + stringToOctetCount(h.name) + stringToOctetCount(h.value) + 32
    i = i + 1
  }
  n
}

func stringToOctetCount(s: in String): Int {
  match stringToOctets(s) {
    case Ok(o) -> {
      val b: slice[Byte] = o
      b.length
    }
    case Err(_) -> s.length
  }
}

test "hpack: encode then decode round-trips across blocks sharing a dynamic table" {
  var it = 0
  while it < iterations() {
    val seed = baseSeed() + 2000 + it
    runCase(
      "hpack round-trip",
      seed,
      { ->
        val r = newRng(seed)
        val sizes = [0, 64, 256, 4096]
        val tableSize = sizes[rnd(r, 4)]
        val enc = newEncoder(tableSize, rndBool(r))
        val dec = newDecoder(tableSize)
        val blocks = 1 + rnd(r, 6)
        var b = 0
        while b < blocks {
          val headers = rndHeaderList(r)
          val block = encodeBlockWith(enc, headers)
          match decodeHeaderBlock(dec, block) {
            case Ok(got) -> assertEqual(
              showHeaders(got),
              showHeaders(headers),
              "block " + b.toString() + " decodes to what was encoded"
            )
            case Err(_) -> assertTrue(false, "own encoding rejected by decoder")
          }
          tableLimitOk(dec)
          b = b + 1
        }
      }
    )
    it = it + 1
  }
}

test "hpack: mutated and random blocks never panic and respect the list and table limits" {
  var it = 0
  while it < iterations() {
    val seed = baseSeed() + 3000 + it
    runCase(
      "hpack mutation",
      seed,
      { ->
        val r = newRng(seed)
        val enc = newEncoder(4096, rndBool(r))
        val block = encodeBlockWith(enc, rndHeaderList(r))
        val input = if rnd(r, 4) == 0 { rndBytes(r, 1 + rnd(r, 200)) } else { mutate(r, block) }
        val limit = 2048
        val dec = newDecoder(4096)
        match decodeHeaderBlockLimited(dec, input, limit) {
          case Ok(got) -> assertTrue(listWireSize(got) <= limit, "an accepted list is within the limit")
          case Err(_) -> ()
        }
        tableLimitOk(dec)
        val dec2 = newDecoder(4096)
        match decodeHeaderBlock(dec2, input) {
          case Ok(_) -> ()
          case Err(_) -> ()
        }
        tableLimitOk(dec2)
        match huffmanDecode(input) {
          case Ok(_) -> ()
          case Err(_) -> ()
        }
        match decodeIntegerAt(input, rnd(r, input.length + 1), 1 + rnd(r, 8)) {
          case Ok(_) -> ()
          case Err(_) -> ()
        }
        match decodeStringLiteralAt(input, rnd(r, input.length + 1)) {
          case Ok(_) -> ()
          case Err(_) -> ()
        }
      }
    )
    it = it + 1
  }
}

test "hpack: a decompression bomb is stopped at the caller's list limit" {
  // One literal with incremental indexing puts a ~4 KiB value at dynamic
  // index 62; every following 0xBE byte (indexed, index 62) would expand to
  // that value again: 200 000 bytes decode to roughly 800 MB unbounded.
  val enc = newEncoder(4096, false)
  val big: List[HeaderField] = newList()
  big.add(hf("x-big", rndValue(newRng(1), 0) + stringOfLen(3900)))
  val seedBlock = encodeBlockWith(enc, big)
  val dec = newDecoder(4096)
  val bomb = newBytesList()
  appendAll(bomb, seedBlock)
  var i = 0
  while i < 200000 {
    bomb.add(190.toByte())
    i = i + 1
  }
  match decodeHeaderBlockLimited(dec, bomb.toArray(), 32768) {
    case Ok(_) -> assertTrue(false, "the bomb must not decode")
    case Err(e) -> match e {
      case HeaderListTooLarge(size, maxSize) -> {
        assertEqualInt(maxSize, 32768, "limit reported")
        assertTrue(size > 32768 and size < 32768 + 4096 + 64, "stopped within one field of the limit")
      }
      case _ -> assertTrue(false, "expected HeaderListTooLarge")
    }
  }
  tableLimitOk(dec)
}

func stringOfLen(n: in Int): String {
  var acc = "x"
  while acc.length < n {
    acc = acc + acc
  }
  acc.substring(0, n)
}

// ---------------------------------------------------------------------------
// H2Conn: runs, traces and invariants.
// ---------------------------------------------------------------------------
func showSettings(s: in H2.H2Settings): String {
  s.headerTableSize.toString() + "," + s.enablePush.toString() + "," + s.maxConcurrentStreams.toString() + "," +
    s.initialWindowSize.toString() +
    "," +
    s.maxFrameSize.toString() +
    "," +
    s.maxHeaderListSize.toString()
}

func showEvent(ev: in H2.H2Event): String {
  match ev {
    case H2NeedMore -> ""
    case H2SettingsReceived(s) -> "settings(" + showSettings(s) + ");"
    case H2SettingsAcknowledged -> "settingsAck;"
    case H2RequestHeaders(sid, hs, es) -> "reqH(" + sid.toString() + "," + showHeaders(hs) + es.toString() + ");"
    case H2RequestData(sid, d, es, w) -> "reqD(" + sid.toString() + "," + digest(d) + "," + es.toString() + "," +
      w.toString() +
      ");"
    case H2PingReceived(d) -> "ping(" + digest(d) + ");"
    case H2PingAcknowledged(d) -> "pong(" + digest(d) + ");"
    case H2WindowUpdated(sid) -> "win(" + sid.toString() + ");"
    case H2PeerReset(sid, c) -> "rst(" + sid.toString() + "," + errorCodeToLong(c).toString() + ");"
    case H2GoAwayReceived(l, c) -> "goaway(" + l.toString() + "," + errorCodeToLong(c).toString() + ");"
    case H2InformationalHeaders(sid, st, hs) -> "info(" + sid.toString() + "," + st.toString() + "," + showHeaders(hs) +
      ");"
    case H2ResponseHeaders(sid, st, hs, es) -> "respH(" + sid.toString() + "," + st.toString() + "," + showHeaders(hs) +
      es.toString() +
      ");"
    case H2ResponseData(sid, d, es, w) -> "respD(" + sid.toString() + "," + digest(d) + "," + es.toString() + "," +
      w.toString() +
      ");"
    case H2ResponseTrailers(sid, hs) -> "respT(" + sid.toString() + "," + showHeaders(hs) + ");"
    case H2StreamUnprocessed(sid) -> "unprocessed(" + sid.toString() + ");"
    case H2ConnError(c, m) -> "connErr(" + errorCodeToLong(c).toString() + "," + m + ");"
    case H2StreamErr(sid, c, m) -> "streamErr(" + sid.toString() + "," + errorCodeToLong(c).toString() + "," + m + ");"
  }
}

func hasConnError(events: in List[H2.H2Event]): Bool {
  var found = false
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ConnError(_, _) -> {
        found = true
      }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func connErrorCodeOf(events: in List[H2.H2Event]): Long {
  var code = -1i64
  var i = 0
  while i < events.count {
    match events[i] {
      case H2ConnError(c, _) -> {
        code = errorCodeToLong(c)
      }
      case _ -> ()
    }
    i = i + 1
  }
  code
}

func countOf(events: in List[H2.H2Event], prefix: in String): Int {
  var n = 0
  var i = 0
  while i < events.count {
    if showEvent(events[i]).startsWith(prefix) {
      n = n + 1
    }
    i = i + 1
  }
  n
}

/// The structural invariants that must hold after every feed of any input.
func checkConn(conn: in H2.H2Connection): Unit {
  if H2.isFailed(conn) {
    return
  }
  val buffered = conn.dec.buf.length - conn.dec.pos
  assertTrue(
    buffered <= 9 + conn.localSettings.maxFrameSize + 24,
    "decoder buffer bounded (" + buffered.toString() + ")"
  )
  match conn.cont {
    case Some(c) -> {
      val cs: H2.ContinuationState = c
      assertTrue(
        cs.buffer.count <= conn.localSettings.maxHeaderListSize,
        "header block buffer within SETTINGS_MAX_HEADER_LIST_SIZE (" + cs.buffer.count.toString() + ")"
      )
      assertTrue(cs.contFrames <= H2.maxContinuationFrames(), "CONTINUATION count bounded")
    }
    case None -> ()
  }
  assertTrue(
    conn.streams.count <= conn.localSettings.maxConcurrentStreams + H2.h2ClosedStreamRetentionWindow() + 64,
    "stream table bounded (" + conn.streams.count.toString() + ")"
  )
  assertTrue(H2.connectionSendWindow(conn) <= H2.h2MaxWindow(), "send window ceiling")
  assertTrue(H2.connectionReceiveWindow(conn) <= H2.h2MaxWindow(), "receive window ceiling")
}

/// Outbound bytes are always a well-formed frame sequence.
func checkOutbound(acc0: in slice[Byte]): Unit {
  val res = feedFrames(newFrameDecoder(false), acc0)
  var i = 0
  while i < res.events.count {
    match res.events[i] {
      case FrameFailed(e) -> assertTrue(false, "outbound frame malformed: " + e.message)
      case _ -> ()
    }
    i = i + 1
  }
  assertEqualInt(res.decoder.buf.length - res.decoder.pos, 0, "outbound ends on a frame boundary")
}

record ConnRun {
  trace: String
  outbound: String
  failed: Bool
  consumed: Int
}

/// Feed `bytes` to `conn` in `mode`-sized chunks until done or failed, checking
/// the invariants after every chunk.
func driveRun(r: in Rng, conn: in H2.H2Connection, bytes: in slice[Byte], mode: in Int): ConnRun {
  var trace = ""
  val outAll = newBytesList()
  var pos = 0
  while pos < bytes.length and not H2.isFailed(conn) {
    val n = nextChunk(r, mode, bytes.length - pos)
    val res = H2.feed(conn, bytes.slice(pos, pos + n))
    var i = 0
    while i < res.events.count {
      trace = trace + showEvent(res.events[i])
      i = i + 1
    }
    appendAll(outAll, res.outbound)
    assertEqual(
      H2.isFailed(conn).toString(),
      hasConnError(res.events).toString(),
      "failed exactly when a connection error was reported"
    )
    if hasConnError(res.events) {
      assertTrue(hasGoAway(res.outbound), "a connection error queues GOAWAY")
    }
    checkConn(conn)
    pos = pos + n
  }
  val outBytes = outAll.toArray()
  checkOutbound(outBytes)
  assertTrue(outBytes.length <= 4 * pos + 64, "outbound is at most a small multiple of the input")
  ConnRun(trace = trace, outbound = digest(outBytes), failed = H2.isFailed(conn), consumed = pos)
}

func hasGoAway(acc0: in slice[Byte]): Bool {
  val res = feedFrames(newFrameDecoder(false), acc0)
  var found = false
  var i = 0
  while i < res.events.count {
    match res.events[i] {
      case FrameDecoded(f) -> match f { case GoAwayFrame(_, _, _) -> { found = true }; case _ -> () }
      case _ -> ()
    }
    i = i + 1
  }
  found
}

func assertSameRun(a: in ConnRun, b: in ConnRun, label: in String): Unit {
  assertEqual(b.trace, a.trace, label + ": events")
  assertEqual(b.outbound, a.outbound, label + ": outbound")
  assertEqual(b.failed.toString(), a.failed.toString(), label + ": failed")
}

func newServer(): H2.H2Connection {
  H2.newServerConnection(H2.h2DefaultServerSettings())
}

func chunkingInvariance(role: in String, seedBase: in Int, mutated: in Bool): Unit {
  var it = 0
  while it < iterations() {
    val seed = baseSeed() + seedBase + it
    runCase(
      role + (if mutated { " mutation" } else { " chunking" }),
      seed,
      { ->
        val r = newRng(seed)
        val server = role == "server"
        val streams = clientStreamCount(r)
        val kind = rnd(r, 4)
        val valid = if server { genServerScript(r) } else { genClientScript(r, streams) }
        val input = if mutated { if kind == 0 { genRawFrames(r, server) } else { mutate(r, valid) } } else { valid }
        val whole = driveRun(r, if server { newServer() } else { newClientWithStreams(streams) }, input, 0)
        var mode = 1
        while mode <= 3 {
          val run = driveRun(r, if server { newServer() } else { newClientWithStreams(streams) }, input, mode)
          assertSameRun(whole, run, "chunk mode " + mode.toString())
          mode = mode + 1
        }
        if not mutated {
          assertFalse(whole.failed, "a valid script never fails the connection")
          assertEqualInt(whole.consumed, input.length, "a valid script is consumed whole")
        }
      }
    )
    it = it + 1
  }
}

test "server role: valid scripts are chunking-invariant and never fail" {
  chunkingInvariance("server", 4000, false)
}

test "client role: valid scripts are chunking-invariant and never fail" {
  chunkingInvariance("client", 5000, false)
}

test "server role: mutated and random frames never panic, hold the invariants and stay chunking-invariant" {
  chunkingInvariance("server", 6000, true)
}

test "client role: mutated and random frames never panic, hold the invariants and stay chunking-invariant" {
  chunkingInvariance("client", 7000, true)
}

// ---------------------------------------------------------------------------
// Bounded work on adversarial input.
// ---------------------------------------------------------------------------
func handshakenServer(): H2.H2Connection {
  val s = newServer()
  val res = H2.feed(s, connectionPreface().concat(emptySettingsFrame()))
  assertFalse(H2.isFailed(s), "handshake ok")
  s
}

test "server: Rapid Reset is cut off after maxRapidResets completed-and-reset streams" {
  val s = handshakenServer()
  val enc = newEncoder(4096, false)
  val rr = newRng(11)
  val limit = H2.maxRapidResets()
  var pairs = 0
  var failedAt = -1
  while pairs < 2000 and failedAt < 0 {
    val sid = 1 + 2 * pairs
    val bytes = headersFrame(sid, encodeBlockWith(enc, requestHeaders(rr)), false, true).concat(
      serializeFrame(RstStreamFrame(streamId = sid, errorCode = H2Cancel))
    )
    val res = H2.feed(s, bytes)
    checkConn(s)
    if H2.isFailed(s) {
      failedAt = pairs
      assertEqualLong(connErrorCodeOf(res.events), errorCodeToLong(H2EnhanceYourCalm), "ENHANCE_YOUR_CALM")
    }
    pairs = pairs + 1
  }
  assertTrue(failedAt >= 0, "the connection was torn down")
  assertTrue(failedAt <= limit + 1, "within one pair of the limit (failed at pair " + failedAt.toString() + ")")
}

test "server: a flood of malformed requests is cut off by the stream-error budget" {
  val s = handshakenServer()
  val enc = newEncoder(4096, false)
  var failedAt = -1
  var i = 0
  while i < 2000 and failedAt < 0 {
    val bad: List[HeaderField] = newList()
    bad.add(hf(":method", "GET"))
    val res = H2.feed(s, headersFrame(1 + 2 * i, encodeBlockWith(enc, bad), false, true))
    checkConn(s)
    if H2.isFailed(s) {
      failedAt = i
    }
    i = i + 1
  }
  assertTrue(failedAt >= 0, "the connection was torn down")
  assertTrue(
    failedAt <= H2.maxRapidResets() + 1,
    "within one request of the limit (failed at " + failedAt.toString() + ")"
  )
}

test "server: opening streams without finishing them is bounded by SETTINGS_MAX_CONCURRENT_STREAMS" {
  val s = handshakenServer()
  val enc = newEncoder(4096, false)
  val rr = newRng(12)
  var i = 0
  while i < 400 and not H2.isFailed(s) {
    val res = H2.feed(s, headersFrame(1 + 2 * i, encodeBlockWith(enc, requestHeaders(rr)), false, true))
    checkConn(s)
    assertTrue(H2.activeStreamCount(s) <= 128, "active streams never exceed the advertised limit")
    i = i + 1
  }
}

test "server and client: a CONTINUATION flood of empty fragments is cut off" {
  var role = 0
  while role < 2 {
    val conn = if role == 0 { handshakenServer() } else { newClientWithStreams(1) }
    val enc = newEncoder(4096, false)
    val rr = newRng(13)
    val first = if role == 0 {
      headersFrame(1, encodeBlockWith(enc, requestHeaders(rr)).slice(0, 3), false, false)
    } else {
      headersFrame(1, encodeBlockWith(enc, responseHeaders(rr)).slice(0, 2), false, false)
    }
    val head = H2.feed(conn, first)
    assertFalse(H2.isFailed(conn), "block opened")
    var sent = 0
    var failedAt = -1
    while sent < 3000 and failedAt < 0 {
      val res = H2.feed(conn, continuationFrame(1, emptyBytes(), false))
      checkConn(conn)
      if H2.isFailed(conn) {
        failedAt = sent
        assertEqualLong(connErrorCodeOf(res.events), errorCodeToLong(H2EnhanceYourCalm), "ENHANCE_YOUR_CALM")
      }
      sent = sent + 1
    }
    assertTrue(failedAt >= 0, "role " + role.toString() + ": flood cut off")
    assertTrue(failedAt <= H2.maxContinuationFrames() + 1, "role " + role.toString() + ": within the frame budget")
    role = role + 1
  }
}

test "server and client: header blocks past SETTINGS_MAX_HEADER_LIST_SIZE are cut off with a bounded buffer" {
  var role = 0
  while role < 2 {
    val conn = if role == 0 { handshakenServer() } else { newClientWithStreams(1) }
    val first = headersFrame(1, fillBytes(16000, 0), false, false)
    val head = H2.feed(conn, first)
    var sent = 0
    var failedAt = -1
    while sent < 20 and failedAt < 0 {
      val res = H2.feed(conn, continuationFrame(1, fillBytes(16000, 0), false))
      checkConn(conn)
      if H2.isFailed(conn) {
        failedAt = sent
        assertEqualLong(connErrorCodeOf(res.events), errorCodeToLong(H2EnhanceYourCalm), "ENHANCE_YOUR_CALM")
      }
      sent = sent + 1
    }
    assertTrue(failedAt >= 0 and failedAt <= 3, "role " + role.toString() + ": cut off within a few frames")
    role = role + 1
  }
}

test "server and client: an HPACK bomb in a header block is a connection error, not unbounded expansion" {
  var role = 0
  while role < 2 {
    val conn = if role == 0 { handshakenServer() } else { newClientWithStreams(1) }
    // Seed the decoder's dynamic table with a ~4 KiB entry, then reference it
    // ~12 000 times in one block (the block itself is under the header-list
    // budget, its expansion is about 47 MB).
    val enc = newEncoder(4096, false)
    val seedList: List[HeaderField] = newList()
    if role == 0 {
      seedList.add(hf(":method", "GET"))
      seedList.add(hf(":scheme", "https"))
      seedList.add(hf(":path", "/"))
      seedList.add(hf(":authority", "example.test"))
    } else {
      seedList.add(hf(":status", "200"))
    }
    seedList.add(hf("x-big", stringOfLen(3900)))
    val block = newBytesList()
    appendAll(block, encodeBlockWith(enc, seedList))
    var i = 0
    while i < 12000 {
      block.add(190.toByte())
      i = i + 1
    }
    val bytes = block.toArray()
    val frames = newBytesList()
    appendAll(frames, headersFrame(1, bytes.slice(0, 8000), false, false))
    appendAll(frames, continuationFrame(1, bytes.slice(8000, bytes.length), true))
    val res = H2.feed(conn, frames.toArray())
    checkConn(conn)
    assertTrue(H2.isFailed(conn), "role " + role.toString() + ": the bomb fails the connection")
    assertEqualLong(
      connErrorCodeOf(res.events),
      errorCodeToLong(H2EnhanceYourCalm),
      "ENHANCE_YOUR_CALM (decoded list over the header-list limit)"
    )
    role = role + 1
  }
}

test "server and client: an oversized frame declaration fails the connection from the header alone" {
  var role = 0
  while role < 2 {
    val conn = if role == 0 { handshakenServer() } else { newClientWithStreams(1) }
    val header = serializeFrameHeader(H2FrameHeader(length = 16777215, frameType = 0, flags = 0, streamId = 1))
    val res = H2.feed(conn, header)
    assertTrue(H2.isFailed(conn), "role " + role.toString() + ": failed without waiting for the payload")
    assertEqualLong(connErrorCodeOf(res.events), errorCodeToLong(H2FrameSizeError), "FRAME_SIZE_ERROR")
    role = role + 1
  }
}

test "server: a frame dribbled one byte at a time never buffers more than one frame" {
  val s = handshakenServer()
  val enc = newEncoder(4096, false)
  val rr = newRng(14)
  val bytes = headersFrame(1, encodeBlockWith(enc, requestHeaders(rr)), false, true).concat(
    dataFrame(1, fillBytes(16384, 5), true)
  )
  var i = 0
  while i < bytes.length {
    val res = H2.feed(s, bytes.slice(i, i + 1))
    checkConn(s)
    i = i + 1
  }
  assertFalse(H2.isFailed(s), "the dribbled request is accepted")
}

test "server and client: PING and SETTINGS floods are answered without amplification and without growth" {
  var role = 0
  while role < 2 {
    val conn = if role == 0 { handshakenServer() } else { newClientWithStreams(1) }
    val flood = newBytesList()
    var i = 0
    while i < 20000 {
      appendAll(flood, serializeFrame(PingFrame(opaqueData = fillBytes(8, i), ack = false)))
      appendAll(flood, emptySettingsFrame())
      i = i + 1
    }
    val input = flood.toArray()
    val res = H2.feed(conn, input)
    checkConn(conn)
    assertFalse(H2.isFailed(conn), "role " + role.toString() + ": floods of valid frames are legal")
    assertTrue(res.outbound.length <= input.length, "role " + role.toString() + ": outbound is no larger than the input")
    assertEqualInt(countOf(res.events, "ping("), 20000, "role " + role.toString() + ": one event per PING, none retained")
    role = role + 1
  }
}

test "server and client: many tiny DATA and WINDOW_UPDATE frames keep the window and table bounded" {
  val s = handshakenServer()
  val enc = newEncoder(4096, false)
  val rr = newRng(15)
  val head = H2.feed(s, headersFrame(1, encodeBlockWith(enc, requestHeaders(rr)), false, true))
  val flood = newBytesList()
  var i = 0
  while i < 20000 {
    appendAll(flood, dataFrame(1, emptyBytes(), false))
    appendAll(flood, serializeFrame(WindowUpdateFrame(streamId = 0, windowSizeIncrement = 1)))
    i = i + 1
  }
  val res = H2.feed(s, flood.toArray())
  checkConn(s)
  assertFalse(H2.isFailed(s) and not hasConnError(res.events), "failure is always reported")
  assertTrue(res.outbound.length <= flood.count, "no amplification")
}
