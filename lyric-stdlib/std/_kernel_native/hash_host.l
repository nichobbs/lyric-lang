//! std/_kernel_native/hash_host.l - native twin of `_kernel/hash_host.l`:
//! SHA-1, SHA-256 and SHA-512 in pure Lyric, and the hex encoder.
//!
//! The dotnet twin calls `System.Security.Cryptography`; native has no such
//! library, so the digests are computed here from the FIPS 180-4 definitions.
//! SHA-1 and SHA-256 do their 32-bit arithmetic in `Long`, masked to 32 bits;
//! SHA-512 relies on `Long` addition wrapping modulo 2^64, which native code
//! does (it emits no overflow checks). Right shifts of a possibly-negative
//! `Long` are arithmetic, so each is masked into a logical shift. The constant
//! tables are the standard ones (fractional parts of the cube and square roots
//! of the first primes), generated rather than typed, and checked against
//! reference digests by `lyric-stdlib/tests/hash_tests.l`.
//!
//! Internal: only Std.Hash should import this.
@io
package Std.HashHost

import Std.Core
import Std.Collections
import Std.FileHost

func byteAt(bytes: in slice[Byte], i: in Int): Long {
  bytes[i].toInt().and(255).toLong()
}

// `bytes`, a 0x80 byte, zero fill, then the message length in bits as a
// big-endian `lenBytes`-byte integer, to a multiple of `block` bytes.
func padMessage(bytes: in slice[Byte], block: in Int, lenBytes: in Int): List[Byte] {
  val digest: List[Byte] = newList()
  var i = 0
  while i < bytes.length {
    digest.add(bytes[i])
    i = i + 1
  }
  digest.add(128.toByte())
  while (digest.count + lenBytes) % block != 0 {
    digest.add(0.toByte())
  }
  val bits = bytes.length.toLong() * 8i64
  var p = 0
  while p < lenBytes {
    val shift = (lenBytes - 1 - p) * 8
    var v = 0i64
    if shift < 64 {
      v = bits.shr(shift).and(255i64)
    }
    digest.add(v.toInt().toByte())
    p = p + 1
  }
  digest
}

func wordBE32(m: in List[Byte], at: in Int): Long {
  m[at].toInt().and(255).toLong().shl(24).or(m[at + 1].toInt().and(255).toLong().shl(16)).or(m[at + 2].toInt().and(255).toLong().shl(8)).or(m[at + 3].toInt().and(255).toLong())
}

func rotl32(x: in Long, n: in Int): Long {
  x.shl(n).or(x.shr(32 - n)).and(0xFFFFFFFFi64)
}

func rotr32(x: in Long, n: in Int): Long {
  x.shr(n).or(x.shl(32 - n)).and(0xFFFFFFFFi64)
}

func appendWordBE32(digest: in List[Byte], v: in Long): Unit {
  digest.add(v.shr(24).and(255i64).toInt().toByte())
  digest.add(v.shr(16).and(255i64).toInt().toByte())
  digest.add(v.shr(8).and(255i64).toInt().toByte())
  digest.add(v.and(255i64).toInt().toByte())
}

/// SHA-1 of `bytes`: the raw 20-byte digest.
pub func hostSha1Bytes(bytes: in slice[Byte]): slice[Byte] {
  val m = padMessage(bytes, 64, 8)
  var h0 = 0x67452301i64
  var h1 = 0xEFCDAB89i64
  var h2 = 0x98BADCFEi64
  var h3 = 0x10325476i64
  var h4 = 0xC3D2E1F0i64
  var base = 0
  while base < m.count {
    val w: List[Long] = newList()
    var t = 0
    while t < 16 {
      w.add(wordBE32(m, base + t * 4))
      t = t + 1
    }
    while t < 80 {
      w.add(rotl32(w[t - 3].xor(w[t - 8]).xor(w[t - 14]).xor(w[t - 16]), 1))
      t = t + 1
    }
    var a = h0
    var b = h1
    var c = h2
    var d = h3
    var e = h4
    t = 0
    while t < 80 {
      var f = 0i64
      var k = 0i64
      if t < 20 {
        f = b.and(c).or(b.xor(0xFFFFFFFFi64).and(d))
        k = 0x5A827999i64
      } else if t < 40 {
        f = b.xor(c).xor(d)
        k = 0x6ED9EBA1i64
      } else if t < 60 {
        f = b.and(c).or(b.and(d)).or(c.and(d))
        k = 0x8F1BBCDCi64
      } else {
        f = b.xor(c).xor(d)
        k = 0xCA62C1D6i64
      }
      val temp = (rotl32(a, 5) + f + e + k + w[t]).and(0xFFFFFFFFi64)
      e = d
      d = c
      c = rotl32(b, 30)
      b = a
      a = temp
      t = t + 1
    }
    h0 = (h0 + a).and(0xFFFFFFFFi64)
    h1 = (h1 + b).and(0xFFFFFFFFi64)
    h2 = (h2 + c).and(0xFFFFFFFFi64)
    h3 = (h3 + d).and(0xFFFFFFFFi64)
    h4 = (h4 + e).and(0xFFFFFFFFi64)
    base = base + 64
  }
  val digest: List[Byte] = newList()
  appendWordBE32(digest, h0)
  appendWordBE32(digest, h1)
  appendWordBE32(digest, h2)
  appendWordBE32(digest, h3)
  appendWordBE32(digest, h4)
  digest.toArray()
}

func sha256K(): List[Long] {
  val k: List[Long] = newList()
  k.add(0x428A2F98i64)
  k.add(0x71374491i64)
  k.add(0xB5C0FBCFi64)
  k.add(0xE9B5DBA5i64)
  k.add(0x3956C25Bi64)
  k.add(0x59F111F1i64)
  k.add(0x923F82A4i64)
  k.add(0xAB1C5ED5i64)
  k.add(0xD807AA98i64)
  k.add(0x12835B01i64)
  k.add(0x243185BEi64)
  k.add(0x550C7DC3i64)
  k.add(0x72BE5D74i64)
  k.add(0x80DEB1FEi64)
  k.add(0x9BDC06A7i64)
  k.add(0xC19BF174i64)
  k.add(0xE49B69C1i64)
  k.add(0xEFBE4786i64)
  k.add(0x0FC19DC6i64)
  k.add(0x240CA1CCi64)
  k.add(0x2DE92C6Fi64)
  k.add(0x4A7484AAi64)
  k.add(0x5CB0A9DCi64)
  k.add(0x76F988DAi64)
  k.add(0x983E5152i64)
  k.add(0xA831C66Di64)
  k.add(0xB00327C8i64)
  k.add(0xBF597FC7i64)
  k.add(0xC6E00BF3i64)
  k.add(0xD5A79147i64)
  k.add(0x06CA6351i64)
  k.add(0x14292967i64)
  k.add(0x27B70A85i64)
  k.add(0x2E1B2138i64)
  k.add(0x4D2C6DFCi64)
  k.add(0x53380D13i64)
  k.add(0x650A7354i64)
  k.add(0x766A0ABBi64)
  k.add(0x81C2C92Ei64)
  k.add(0x92722C85i64)
  k.add(0xA2BFE8A1i64)
  k.add(0xA81A664Bi64)
  k.add(0xC24B8B70i64)
  k.add(0xC76C51A3i64)
  k.add(0xD192E819i64)
  k.add(0xD6990624i64)
  k.add(0xF40E3585i64)
  k.add(0x106AA070i64)
  k.add(0x19A4C116i64)
  k.add(0x1E376C08i64)
  k.add(0x2748774Ci64)
  k.add(0x34B0BCB5i64)
  k.add(0x391C0CB3i64)
  k.add(0x4ED8AA4Ai64)
  k.add(0x5B9CCA4Fi64)
  k.add(0x682E6FF3i64)
  k.add(0x748F82EEi64)
  k.add(0x78A5636Fi64)
  k.add(0x84C87814i64)
  k.add(0x8CC70208i64)
  k.add(0x90BEFFFAi64)
  k.add(0xA4506CEBi64)
  k.add(0xBEF9A3F7i64)
  k.add(0xC67178F2i64)
  k
}

func sha256H(): List[Long] {
  val h: List[Long] = newList()
  h.add(0x6A09E667i64)
  h.add(0xBB67AE85i64)
  h.add(0x3C6EF372i64)
  h.add(0xA54FF53Ai64)
  h.add(0x510E527Fi64)
  h.add(0x9B05688Ci64)
  h.add(0x1F83D9ABi64)
  h.add(0x5BE0CD19i64)
  h
}

/// SHA-256 of `bytes`: the raw 32-byte digest.
pub func hostSha256Bytes(bytes: in slice[Byte]): slice[Byte] {
  val m = padMessage(bytes, 64, 8)
  val k = sha256K()
  val h = sha256H()
  var base = 0
  while base < m.count {
    val w: List[Long] = newList()
    var t = 0
    while t < 16 {
      w.add(wordBE32(m, base + t * 4))
      t = t + 1
    }
    while t < 64 {
      val x = w[t - 15]
      val y = w[t - 2]
      val s0 = rotr32(x, 7).xor(rotr32(x, 18)).xor(x.shr(3))
      val s1 = rotr32(y, 17).xor(rotr32(y, 19)).xor(y.shr(10))
      w.add((w[t - 16] + s0 + w[t - 7] + s1).and(0xFFFFFFFFi64))
      t = t + 1
    }
    var a = h[0]
    var b = h[1]
    var c = h[2]
    var d = h[3]
    var e = h[4]
    var f = h[5]
    var g = h[6]
    var hh = h[7]
    t = 0
    while t < 64 {
      val bigS1 = rotr32(e, 6).xor(rotr32(e, 11)).xor(rotr32(e, 25))
      val ch = e.and(f).xor(e.xor(0xFFFFFFFFi64).and(g))
      val t1 = hh + bigS1 + ch + k[t] + w[t]
      val bigS0 = rotr32(a, 2).xor(rotr32(a, 13)).xor(rotr32(a, 22))
      val maj = a.and(b).xor(a.and(c)).xor(b.and(c))
      val t2 = bigS0 + maj
      hh = g
      g = f
      f = e
      e = (d + t1).and(0xFFFFFFFFi64)
      d = c
      c = b
      b = a
      a = (t1 + t2).and(0xFFFFFFFFi64)
      t = t + 1
    }
    h[0] = (h[0] + a).and(0xFFFFFFFFi64)
    h[1] = (h[1] + b).and(0xFFFFFFFFi64)
    h[2] = (h[2] + c).and(0xFFFFFFFFi64)
    h[3] = (h[3] + d).and(0xFFFFFFFFi64)
    h[4] = (h[4] + e).and(0xFFFFFFFFi64)
    h[5] = (h[5] + f).and(0xFFFFFFFFi64)
    h[6] = (h[6] + g).and(0xFFFFFFFFi64)
    h[7] = (h[7] + hh).and(0xFFFFFFFFi64)
    base = base + 64
  }
  val digest: List[Byte] = newList()
  var i = 0
  while i < 8 {
    appendWordBE32(digest, h[i])
    i = i + 1
  }
  digest.toArray()
}

// Logical right shift of a 64-bit value by 1..63.
func lshr64(x: in Long, n: in Int): Long {
  x.shr(n).and(1i64.shl(64 - n) - 1i64)
}

func rotr64(x: in Long, n: in Int): Long {
  lshr64(x, n).or(x.shl(64 - n))
}

func wordBE64(m: in List[Byte], at: in Int): Long {
  var v = 0i64
  var i = 0
  while i < 8 {
    v = v.shl(8).or(m[at + i].toInt().and(255).toLong())
    i = i + 1
  }
  v
}

func sha512K(): List[Long] {
  val k: List[Long] = newList()
  k.add(4794697086780616226i64)
  k.add(8158064640168781261i64)
  k.add(-5349999486874862801i64)
  k.add(-1606136188198331460i64)
  k.add(4131703408338449720i64)
  k.add(6480981068601479193i64)
  k.add(-7908458776815382629i64)
  k.add(-6116909921290321640i64)
  k.add(-2880145864133508542i64)
  k.add(1334009975649890238i64)
  k.add(2608012711638119052i64)
  k.add(6128411473006802146i64)
  k.add(8268148722764581231i64)
  k.add(-9160688886553864527i64)
  k.add(-7215885187991268811i64)
  k.add(-4495734319001033068i64)
  k.add(-1973867731355612462i64)
  k.add(-1171420211273849373i64)
  k.add(1135362057144423861i64)
  k.add(2597628984639134821i64)
  k.add(3308224258029322869i64)
  k.add(5365058923640841347i64)
  k.add(6679025012923562964i64)
  k.add(8573033837759648693i64)
  k.add(-7476448914759557205i64)
  k.add(-6327057829258317296i64)
  k.add(-5763719355590565569i64)
  k.add(-4658551843659510044i64)
  k.add(-4116276920077217854i64)
  k.add(-3051310485924567259i64)
  k.add(489312712824947311i64)
  k.add(1452737877330783856i64)
  k.add(2861767655752347644i64)
  k.add(3322285676063803686i64)
  k.add(5560940570517711597i64)
  k.add(5996557281743188959i64)
  k.add(7280758554555802590i64)
  k.add(8532644243296465576i64)
  k.add(-9096487096722542874i64)
  k.add(-7894198246740708037i64)
  k.add(-6719396339535248540i64)
  k.add(-6333637450476146687i64)
  k.add(-4446306890439682159i64)
  k.add(-4076793802049405392i64)
  k.add(-3345356375505022440i64)
  k.add(-2983346525034927856i64)
  k.add(-860691631967231958i64)
  k.add(1182934255886127544i64)
  k.add(1847814050463011016i64)
  k.add(2177327727835720531i64)
  k.add(2830643537854262169i64)
  k.add(3796741975233480872i64)
  k.add(4115178125766777443i64)
  k.add(5681478168544905931i64)
  k.add(6601373596472566643i64)
  k.add(7507060721942968483i64)
  k.add(8399075790359081724i64)
  k.add(8693463985226723168i64)
  k.add(-8878714635349349518i64)
  k.add(-8302665154208450068i64)
  k.add(-8016688836872298968i64)
  k.add(-6606660893046293015i64)
  k.add(-4685533653050689259i64)
  k.add(-4147400797238176981i64)
  k.add(-3880063495543823972i64)
  k.add(-3348786107499101689i64)
  k.add(-1523767162380948706i64)
  k.add(-757361751448694408i64)
  k.add(500013540394364858i64)
  k.add(748580250866718886i64)
  k.add(1242879168328830382i64)
  k.add(1977374033974150939i64)
  k.add(2944078676154940804i64)
  k.add(3659926193048069267i64)
  k.add(4368137639120453308i64)
  k.add(4836135668995329356i64)
  k.add(5532061633213252278i64)
  k.add(6448918945643986474i64)
  k.add(6902733635092675308i64)
  k.add(7801388544844847127i64)
  k
}

func sha512H(): List[Long] {
  val h: List[Long] = newList()
  h.add(7640891576956012808i64)
  h.add(-4942790177534073029i64)
  h.add(4354685564936845355i64)
  h.add(-6534734903238641935i64)
  h.add(5840696475078001361i64)
  h.add(-7276294671716946913i64)
  h.add(2270897969802886507i64)
  h.add(6620516959819538809i64)
  h
}

/// SHA-512 of `bytes`: the raw 64-byte digest.
pub func hostSha512Bytes(bytes: in slice[Byte]): slice[Byte] {
  val m = padMessage(bytes, 128, 16)
  val k = sha512K()
  val h = sha512H()
  var base = 0
  while base < m.count {
    val w: List[Long] = newList()
    var t = 0
    while t < 16 {
      w.add(wordBE64(m, base + t * 8))
      t = t + 1
    }
    while t < 80 {
      val x = w[t - 15]
      val y = w[t - 2]
      val s0 = rotr64(x, 1).xor(rotr64(x, 8)).xor(lshr64(x, 7))
      val s1 = rotr64(y, 19).xor(rotr64(y, 61)).xor(lshr64(y, 6))
      w.add(w[t - 16] + s0 + w[t - 7] + s1)
      t = t + 1
    }
    var a = h[0]
    var b = h[1]
    var c = h[2]
    var d = h[3]
    var e = h[4]
    var f = h[5]
    var g = h[6]
    var hh = h[7]
    t = 0
    while t < 80 {
      val bigS1 = rotr64(e, 14).xor(rotr64(e, 18)).xor(rotr64(e, 41))
      val ch = e.and(f).xor(e.xor(-1i64).and(g))
      val t1 = hh + bigS1 + ch + k[t] + w[t]
      val bigS0 = rotr64(a, 28).xor(rotr64(a, 34)).xor(rotr64(a, 39))
      val maj = a.and(b).xor(a.and(c)).xor(b.and(c))
      val t2 = bigS0 + maj
      hh = g
      g = f
      f = e
      e = d + t1
      d = c
      c = b
      b = a
      a = t1 + t2
      t = t + 1
    }
    h[0] = h[0] + a
    h[1] = h[1] + b
    h[2] = h[2] + c
    h[3] = h[3] + d
    h[4] = h[4] + e
    h[5] = h[5] + f
    h[6] = h[6] + g
    h[7] = h[7] + hh
    base = base + 128
  }
  val digest: List[Byte] = newList()
  var i = 0
  while i < 8 {
    var shift = 56
    while shift >= 0 {
      digest.add(h[i].shr(shift).and(255i64).toInt().toByte())
      shift = shift - 8
    }
    i = i + 1
  }
  digest.toArray()
}

/// SHA-512 of the file at `path`. The file is read whole (the dotnet twin
/// streams it); an unreadable file panics, as the dotnet twin throws.
pub func hostSha512File(path: in String): slice[Byte] {
  hostSha512Bytes(hostReadAllBytes(path))
}

/// Convert a byte slice to an uppercase hexadecimal string (one `[0-9A-F]`
/// pair per byte; no separator).
pub func hostBytesToHex(bytes: in slice[Byte]): String {
  val digits = "0123456789ABCDEF"
  var s = ""
  var i = 0
  while i < bytes.length {
    val v = bytes[i].toInt().and(255)
    s = s + digits.substring(v.shr(4), 1) + digits.substring(v.and(15), 1)
    i = i + 1
  }
  s
}
