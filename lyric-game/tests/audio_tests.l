@test_module
package Game.AudioTests

import Std.Core
import Std.Collections
import Std.Buffer as Buf
import Std.Testing
import Game.Audio

func u16(b: List[Byte], v: Int): Unit {
  b.add((v % 256).toByte())
  b.add((v / 256 % 256).toByte())
}

func u32(b: List[Byte], v: Int): Unit {
  u16(b, v % 65536)
  u16(b, v / 65536)
}

func ascii(b: List[Byte], a: Int, c: Int, d: Int, e: Int): Unit {
  b.add(a.toByte())
  b.add(c.toByte())
  b.add(d.toByte())
  b.add(e.toByte())
}

// A 16-bit PCM WAV of `values` (already two's complement unsigned 16-bit).
func wav16(frequency: Int, channels: Int, values: List[Int]): slice[Byte] {
  val b: List[Byte] = newList()
  ascii(b, 82, 73, 70, 70)
  u32(b, 36 + values.count * 2)
  ascii(b, 87, 65, 86, 69)
  ascii(b, 102, 109, 116, 32)
  u32(b, 16)
  u16(b, 1)
  u16(b, channels)
  u32(b, frequency)
  u32(b, frequency * channels * 2)
  u16(b, channels * 2)
  u16(b, 16)
  ascii(b, 100, 97, 116, 97)
  u32(b, values.count * 2)
  for v in values {
    u16(b, v)
  }
  b.toArray()
}

func near(a: Float, b: Float): Bool {
  val d = a - b
  d < 0.001f32 and d > -0.001f32
}

test "wav 16-bit mono decodes to floats" {
  val v: List[Int] = newList()
  v.add(0)
  v.add(16384)
  v.add(49152)
  v.add(32767)
  match decodeWav(wav16(8000, 1, v)) {
    case Err(e) -> assertTrue(false, e)
    case Ok(s) -> {
      assertEqualInt(s.frequency, 8000, "rate")
      assertEqualInt(s.channels, 1, "channels")
      assertEqualInt(frameCount(s), 4, "frames")
      assertTrue(near(s.samples[0], 0.0f32) and near(s.samples[1], 0.5f32) and near(s.samples[2], -0.5f32), "values")
      assertTrue(s.samples[3] < 1.0f32 and s.samples[3] > 0.99f32, "peak")
    }
  }
}

test "wav rejects damage" {
  match decodeWav(wav16(8000, 1, newList())) {
    case Ok(s) -> assertEqualInt(frameCount(s), 0, "empty data is an empty sound")
    case Err(e) -> assertTrue(false, e)
  }
  match decodeWav(Buf.fromSlice([1u8, 2u8, 3u8]).toSlice()) {
    case Ok(_) -> assertTrue(false, "should not decode")
    case Err(_) -> ()
  }
}

func ramp(): Sound {
  val v: List[Int] = newList()
  v.add(0)
  v.add(16384)
  v.add(32767)
  v.add(16384)
  match decodeWav(wav16(100, 1, v)) {
    case Ok(s) -> s
    case Err(e) -> {
      assertTrue(false, e)
      Sound(frequency = 100, channels = 1, samples = Buf.filled(1, 0.0f32))
    }
  }
}

test "mixer resamples, duplicates mono to both channels and plays mixed" {
  val m = newMixer(200)
  val id = play(m, ramp(), 1.0f32, false)
  assertTrue(id > 0, "voice id")
  val mixed = render(m, 4)
  assertEqualInt(mixed.length, 8, "stereo frames")
  assertTrue(near(mixed[0], 0.0f32) and near(mixed[1], 0.0f32), "first frame")
  assertTrue(near(mixed[2], 0.25f32) and near(mixed[3], 0.25f32), "interpolated midpoint")
  assertTrue(near(mixed[4], 0.5f32), "second source frame")
  assertEqualInt(voiceCount(m), 1, "still playing")
  val rest = render(m, 8)
  assertEqualInt(rest.length, 16, "frames asked for")
  assertEqualInt(voiceCount(m), 0, "played mixed")
}

test "mixer sums voices, applies gain and clips" {
  val m = newMixer(100)
  val a = play(m, ramp(), 1.0f32, false)
  val b = play(m, ramp(), 1.0f32, false)
  m.master = 4.0f32
  val mixed = render(m, 3)
  assertTrue(mixed[4] <= 1.0f32 and mixed[4] >= 0.999f32, "clipped high")
  stop(m, a)
  stop(m, b)
  assertEqualInt(voiceCount(m), 0, "stopped")
  stop(m, 99)
}

test "looping voices keep playing and rendering is repeatable" {
  val m1 = newMixer(100)
  val m2 = newMixer(100)
  val v1 = play(m1, ramp(), 0.5f32, true)
  val v2 = play(m2, ramp(), 0.5f32, true)
  var i = 0
  while i < 10 {
    val x = render(m1, 7)
    val y = render(m2, 7)
    var k = 0
    while k < x.length {
      assertTrue(x[k] == y[k], "identical samples")
      k = k + 1
    }
    i = i + 1
  }
  assertEqualInt(voiceCount(m1), 1, "looping stays")
  assertTrue(v1 == v2, "same ids")
}
