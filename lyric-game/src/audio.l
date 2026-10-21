//! audio.l - Game.Audio: WAV decoding and a software mixer (docs/67 G7).
//!
//! `decodeWav` reads RIFF/WAVE files holding integer PCM (8, 16, 24 or 32 bits) or 32-bit float
//! samples in any channel count, into interleaved floats in -1 to 1.  A `Mixer` plays `Sound`s as
//! voices: it resamples each to the output rate with linear interpolation, applies a gain,
//! optionally loops, sums into interleaved stereo and clips.  `render` is a pure function of the
//! mixer's state, so a game's audio is as reproducible as its logic; the platform loop only
//! queues the buffers it returns to the sound card.
package Game.Audio

import Std.Core
import Std.Collections
import Std.Buffer as Buf

/// Decoded audio: `channels` interleaved samples per frame, `frequency` frames per second.
pub record Sound {
  frequency: Int
  channels: Int
  samples: buffer[Float]
}

/// Whole frames in `s`.
pub func frameCount(s: in Sound): Int {
  s.samples.length / s.channels
}

func le16(d: slice[Byte], at: Int): Int {
  d[at].toInt().or(d[at + 1].toInt().shl(8))
}

func le32(d: slice[Byte], at: Int): Int {
  d[at].toInt().or(d[at + 1].toInt().shl(8)).or(d[at + 2].toInt().shl(16)).or(d[at + 3].toInt().shl(24))
}

func tag(d: slice[Byte], at: Int, a: Int, b: Int, c: Int, e: Int): Bool {
  d[at].toInt() == a and d[at + 1].toInt() == b and d[at + 2].toInt() == c and d[at + 3].toInt() == e
}

/// Decodes a WAV file.  `Err` names the first thing that is malformed or unsupported.
pub func decodeWav(file: in slice[Byte]): Result[Sound, String] {
  if file.length < 12 or not tag(file, 0, 82, 73, 70, 70) or not tag(file, 8, 87, 65, 86, 69) {
    return Err(error = "wav: not a RIFF/WAVE file")
  }
  var format = 0
  var channels = 0
  var frequency = 0
  var bits = 0
  var dataAt = -1
  var dataLen = 0
  var pos = 12
  while pos + 8 <= file.length and dataAt < 0 {
    val len = le32(file, pos + 4)
    if len < 0 {
      return Err(error = "wav: chunk too large")
    }
    val body = pos + 8
    if tag(file, pos, 102, 109, 116, 32) {
      if len < 16 or body + 16 > file.length {
        return Err(error = "wav: truncated fmt chunk")
      }
      format = le16(file, body)
      channels = le16(file, body + 2)
      frequency = le32(file, body + 4)
      bits = le16(file, body + 14)
      if format == 65534 and len >= 26 and body + 26 <= file.length {
        format = le16(file, body + 24)
      }
    } else if tag(file, pos, 100, 97, 116, 97) {
      dataAt = body
      dataLen = if body + len > file.length { file.length - body } else { len }
    }
    pos = body + len + len % 2
  }
  if channels == 0 {
    return Err(error = "wav: no fmt chunk")
  }
  if dataAt < 0 {
    return Err(error = "wav: no data chunk")
  }
  if channels < 1 or channels > 8 or frequency < 1 {
    return Err(error = "wav: unsupported channel count or rate")
  }
  val isFloat = format == 3
  if not ((format == 1 and (bits == 8 or bits == 16 or bits == 24 or bits == 32)) or (isFloat and bits == 32)) {
    return Err(error = "wav: unsupported encoding (format " + format.toString() + ", " + bits.toString() + " bits)")
  }
  val bytesPer = bits / 8
  val count = dataLen / bytesPer / channels * channels
  var samples = Buf.filled(count, 0.0f32)
  var i = 0
  while i < count {
    val at = dataAt + i * bytesPer
    var v = 0.0f32
    if bits == 8 {
      v = (file[at].toInt() - 128).toFloat() / 128.0f32
    } else if bits == 16 {
      var s = le16(file, at)
      if s >= 32768 {
        s = s - 65536
      }
      v = s.toFloat() / 32768.0f32
    } else if bits == 24 {
      var s = file[at].toInt().or(file[at + 1].toInt().shl(8)).or(file[at + 2].toInt().shl(16))
      if s >= 8388608 {
        s = s - 16777216
      }
      v = s.toFloat() / 8388608.0f32
    } else if isFloat {
      v = floatFromBits(le32(file, at))
    } else {
      v = le32(file, at).toDouble().toFloat() / 2147483648.0f32
    }
    samples[i] = v
    i = i + 1
  }
  Ok(value = Sound(frequency = frequency, channels = channels, samples = samples))
}

func floatFromBits(bits: Int): Float {
  val sign = if bits.shr(31).and(1) == 1 { -1.0 } else { 1.0 }
  val exponent = bits.shr(23).and(255)
  val fraction = bits.and(8388607)
  if exponent == 255 {
    return 0.0f32
  }
  if exponent == 0 {
    return (sign * fraction.toDouble() * pow2(-149)).toFloat()
  }
  (sign * (1.0 + fraction.toDouble() / 8388608.0) * pow2(exponent - 127)).toFloat()
}

func pow2(e: Int): Double {
  var r = 1.0
  var n = e
  while n > 0 {
    r = r * 2.0
    n = n - 1
  }
  while n < 0 {
    r = r / 2.0
    n = n + 1
  }
  r
}

/// One playing sound.
pub record Voice {
  id: Int
  sound: Sound
  gain: Float
  looping: Bool
  var position: Double
}

/// The mixer: voices playing into interleaved stereo at `frequency`.
pub record Mixer {
  frequency: Int
  var master: Float
  var voices: List[Voice]
  var nextId: Int
}

pub func newMixer(frequency: in Int): Mixer
  requires: frequency > 0
{
  Mixer(frequency = frequency, master = 1.0f32, voices = newList(), nextId = 1)
}

/// Starts `sound` at `gain` and returns the voice id for `stop`.
pub func play(m: in Mixer, sound: in Sound, gain: in Float, looping: in Bool): Int {
  val id = m.nextId
  m.nextId = id + 1
  m.voices.add(Voice(id = id, sound = sound, gain = gain, looping = looping, position = 0.0))
  id
}

/// Stops a voice; an id that has finished or never existed is ignored.
pub func stop(m: in Mixer, id: in Int): Unit {
  val kept: List[Voice] = newList()
  for v in m.voices {
    if v.id != id {
      kept.add(v)
    }
  }
  m.voices = kept
}

pub func voiceCount(m: in Mixer): Int {
  m.voices.count
}

func sampleOf(s: Sound, frame: Int, channel: Int): Float {
  val c = if channel < s.channels { channel } else { s.channels - 1 }
  s.samples[frame * s.channels + c]
}

/// Mixes the next `frames` frames of every voice into interleaved stereo floats (two per frame),
/// clipped to -1 to 1, and drops voices that have played out.
pub func render(m: in Mixer, frames: in Int): buffer[Float]
  requires: frames >= 0
  ensures: result.length == frames * 2
{
  var mix = Buf.filled(frames * 2, 0.0f32)
  val alive: List[Voice] = newList()
  for v in m.voices {
    val total = frameCount(v.sound)
    val step = v.sound.frequency.toDouble() / m.frequency.toDouble()
    var f = 0
    var done = total == 0
    while f < frames and not done {
      var i0 = v.position.toInt()
      if i0 >= total {
        if v.looping {
          v.position = v.position - total.toDouble() * (v.position / total.toDouble()).toInt().toDouble()
          i0 = v.position.toInt()
        } else {
          done = true
        }
      }
      if not done {
        val frac = (v.position - i0.toDouble()).toFloat()
        var i1 = i0 + 1
        if i1 >= total {
          i1 = if v.looping { 0 } else { i0 }
        }
        val l0 = sampleOf(v.sound, i0, 0)
        val l1 = sampleOf(v.sound, i1, 0)
        val r0 = sampleOf(v.sound, i0, 1)
        val r1 = sampleOf(v.sound, i1, 1)
        val g = v.gain * m.master
        mix[f * 2] = mix[f * 2] + (l0 + (l1 - l0) * frac) * g
        mix[f * 2 + 1] = mix[f * 2 + 1] + (r0 + (r1 - r0) * frac) * g
        v.position = v.position + step
        f = f + 1
      }
    }
    if not done and (v.looping or v.position.toInt() < total) {
      alive.add(v)
    }
  }
  m.voices = alive
  var j = 0
  while j < mix.length {
    if mix[j] > 1.0f32 {
      mix[j] = 1.0f32
    } else if mix[j] < -1.0f32 {
      mix[j] = -1.0f32
    }
    j = j + 1
  }
  mix
}
