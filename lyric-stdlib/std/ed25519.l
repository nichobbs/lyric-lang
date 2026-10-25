//! std/ed25519.l - Ed25519 signatures (RFC 8032), in pure Lyric.
//!
//! One implementation for every target (D248): no platform crypto kernel is
//! involved beyond SHA-512, which `Std.HashHost` provides everywhere.
//!
//! - A private key is the 32-byte seed of RFC 8032 §5.1.5. Generate one with
//!   `Std.SecureRandom.secureGetBytes(32)`.
//! - `ed25519PublicKey(seed)` derives the 32-byte public key.
//! - `ed25519Sign(seed, message)` returns the 64-byte signature. The public
//!   key is derived from the seed on every call, never taken as an argument,
//!   so a caller cannot sign with a mismatched public key (which would leak
//!   the private scalar).
//! - `ed25519Verify(publicKey, message, signature)` checks a signature.
//!
//! Verification is strict (D248 Decision 2): it rejects a signature whose
//! scalar `S` is not below the group order, a public key whose encoding is not
//! canonical (a `y` coordinate not below the field prime, or the encoding of
//! `x = 0` with its sign bit set), a public key of small order, and a
//! signature whose `R` is not the canonical encoding of the point the check
//! computes. The check is the cofactorless equation `[S]B = R + [h]A`.
//!
//! The arithmetic follows TweetNaCl: a field element of GF(2^255 - 19) is 16
//! signed 64-bit limbs in radix 2^16. Signing and key derivation have no
//! branches or table indices that depend on secret data: the scalar
//! multiplication swaps points with masks, and limb carries and the final
//! reduction are straight-line. Verification handles only public data and
//! returns early on malformed input.
@runtime_checked
@pure
package Std.Ed25519

import Std.Core
import Std.Collections
import Std.HashHost

// ---- Field arithmetic -------------------------------------------------------
func feZero(): List[Long] {
  val o: List[Long] = newList()
  var i = 0
  while i < 16 {
    o.add(0i64)
    i = i + 1
  }
  o
}

func feOf(limbs: in slice[Long]): List[Long] {
  val o = feZero()
  var i = 0
  while i < 16 {
    o[i] = limbs[i]
    i = i + 1
  }
  o
}

func feCopy(a: in List[Long]): List[Long] {
  val o = feZero()
  feSet(o, a)
  o
}

func feSet(o: in List[Long], a: in List[Long]): Unit {
  var i = 0
  while i < 16 {
    o[i] = a[i]
    i = i + 1
  }
}

func feOne(): List[Long] {
  val o = feZero()
  o[0] = 1i64
  o
}

// d = -121665/121666
func feD(): List[Long] {
  feOf(
    [
      0x78a3i64,
      0x1359i64,
      0x4dcai64,
      0x75ebi64,
      0xd8abi64,
      0x4141i64,
      0x0a4di64,
      0x0070i64,
      0xe898i64,
      0x7779i64,
      0x4079i64,
      0x8cc7i64,
      0xfe73i64,
      0x2b6fi64,
      0x6ceei64,
      0x5203i64
    ]
  )
}

// 2 * d
func feD2(): List[Long] {
  feOf(
    [
      0xf159i64,
      0x26b2i64,
      0x9b94i64,
      0xebd6i64,
      0xb156i64,
      0x8283i64,
      0x149ai64,
      0x00e0i64,
      0xd130i64,
      0xeef3i64,
      0x80f2i64,
      0x198ei64,
      0xfce7i64,
      0x56dfi64,
      0xd9dci64,
      0x2406i64
    ]
  )
}

// The base point's x coordinate.
func feBaseX(): List[Long] {
  feOf(
    [
      0xd51ai64,
      0x8f25i64,
      0x2d60i64,
      0xc956i64,
      0xa7b2i64,
      0x9525i64,
      0xc760i64,
      0x692ci64,
      0xdc5ci64,
      0xfdd6i64,
      0xe231i64,
      0xc0a4i64,
      0x53fei64,
      0xcd6ei64,
      0x36d3i64,
      0x2169i64
    ]
  )
}

// The base point's y coordinate, 4/5.
func feBaseY(): List[Long] {
  feOf(
    [
      0x6658i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64,
      0x6666i64
    ]
  )
}

// sqrt(-1)
func feSqrtM1(): List[Long] {
  feOf(
    [
      0xa0b0i64,
      0x4a0ei64,
      0x1b27i64,
      0xc4eei64,
      0xe478i64,
      0xad2fi64,
      0x1806i64,
      0x2f43i64,
      0xd7a7i64,
      0x3dfbi64,
      0x0099i64,
      0x2b4di64,
      0xdf0bi64,
      0x4fc1i64,
      0x2480i64,
      0x2b83i64
    ]
  )
}

// Propagates carries so every limb is back in 0..2^16, folding the carry out
// of the top limb into the bottom one times 38 (2^256 = 38 mod p).
func feCarry(o: in List[Long]): Unit {
  var i = 0
  while i < 16 {
    o[i] = o[i] + 65536i64
    val c = o[i].shr(16)
    if i < 15 {
      o[i + 1] = o[i + 1] + c - 1i64
    } else {
      o[0] = o[0] + c - 1i64 + 37i64 * (c - 1i64)
    }
    o[i] = o[i] - c.shl(16)
    i = i + 1
  }
}

// Swaps `p` and `q` when `b` is 1 and leaves them when it is 0, by masking.
func feSwap(p: in List[Long], q: in List[Long], b: in Long): Unit {
  val mask = 0i64 - b
  var i = 0
  while i < 16 {
    val t = mask.and(p[i].xor(q[i]))
    p[i] = p[i].xor(t)
    q[i] = q[i].xor(t)
    i = i + 1
  }
}

// The canonical 32-byte little-endian encoding of a field element.
func fePack(n: in List[Long]): slice[Byte] {
  val t = feCopy(n)
  feCarry(t)
  feCarry(t)
  feCarry(t)
  val m = feZero()
  var j = 0
  while j < 2 {
    m[0] = t[0] - 0xffedi64
    var i = 1
    while i < 15 {
      m[i] = t[i] - 0xffffi64 - m[i - 1].shr(16).and(1i64)
      m[i - 1] = m[i - 1].and(0xffffi64)
      i = i + 1
    }
    m[15] = t[15] - 0x7fffi64 - m[14].shr(16).and(1i64)
    val b = m[15].shr(16).and(1i64)
    m[14] = m[14].and(0xffffi64)
    feSwap(t, m, 1i64 - b)
    j = j + 1
  }
  val acc: List[Byte] = newList()
  var k = 0
  while k < 16 {
    acc.add(t[k].and(0xffi64).toByte())
    acc.add(t[k].shr(8).and(0xffi64).toByte())
    k = k + 1
  }
  acc.toArray()
}

// Decodes 32 little-endian bytes, ignoring the top bit.
func feUnpack(bytes: in slice[Byte]): List[Long] {
  val o = feZero()
  var i = 0
  while i < 16 {
    o[i] = bytes[2 * i].toLong() + bytes[2 * i + 1].toLong().shl(8)
    i = i + 1
  }
  o[15] = o[15].and(0x7fffi64)
  o
}

func bytesEqual(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var diff = 0
  var i = 0
  while i < a.length {
    diff = diff.or(a[i].toInt().xor(b[i].toInt()))
    i = i + 1
  }
  diff == 0
}

func feEqual(a: in List[Long], b: in List[Long]): Bool {
  bytesEqual(fePack(a), fePack(b))
}

func feIsZero(a: in List[Long]): Bool {
  val packed = fePack(a)
  var acc = 0
  var i = 0
  while i < 32 {
    acc = acc.or(packed[i].toInt())
    i = i + 1
  }
  acc == 0
}

// The low bit of the canonical encoding (the "sign" of x in RFC 8032).
func feParity(a: in List[Long]): Int {
  fePack(a)[0].toInt().and(1)
}

func feAdd(o: in List[Long], a: in List[Long], b: in List[Long]): Unit {
  var i = 0
  while i < 16 {
    o[i] = a[i] + b[i]
    i = i + 1
  }
}

func feSub(o: in List[Long], a: in List[Long], b: in List[Long]): Unit {
  var i = 0
  while i < 16 {
    o[i] = a[i] - b[i]
    i = i + 1
  }
}

// o = a * b. `o` may be `a` or `b`: the product is built in a scratch list.
func feMul(o: in List[Long], a: in List[Long], b: in List[Long]): Unit {
  val t: List[Long] = newList()
  var k = 0
  while k < 31 {
    t.add(0i64)
    k = k + 1
  }
  var i = 0
  while i < 16 {
    val ai = a[i]
    var j = 0
    while j < 16 {
      t[i + j] = t[i + j] + ai * b[j]
      j = j + 1
    }
    i = i + 1
  }
  i = 0
  while i < 15 {
    t[i] = t[i] + 38i64 * t[i + 16]
    i = i + 1
  }
  i = 0
  while i < 16 {
    o[i] = t[i]
    i = i + 1
  }
  feCarry(o)
  feCarry(o)
}

func feSquare(o: in List[Long], a: in List[Long]): Unit {
  feMul(o, a, a)
}

// o = a^(p - 2) = 1/a.
func feInvert(o: in List[Long], a: in List[Long]): Unit {
  val c = feCopy(a)
  var e = 253
  while e >= 0 {
    feSquare(c, c)
    if e != 2 and e != 4 {
      feMul(c, c, a)
    }
    e = e - 1
  }
  feSet(o, c)
}

// o = a^((p - 5) / 8), used to take square roots.
func fePow2523(o: in List[Long], a: in List[Long]): Unit {
  val c = feCopy(a)
  var e = 250
  while e >= 0 {
    feSquare(c, c)
    if e != 1 {
      feMul(c, c, a)
    }
    e = e - 1
  }
  feSet(o, c)
}

// ---- Points -----------------------------------------------------------------
// A point in extended twisted Edwards coordinates: x = X/Z, y = Y/Z,
// x * y = T/Z. The lists are mutated in place.
record Point {
  x: List[Long]
  y: List[Long]
  z: List[Long]
  t: List[Long]
}

func pointIdentity(): Point {
  Point(x = feZero(), y = feOne(), z = feOne(), t = feZero())
}

func pointCopy(p: in Point): Point {
  Point(x = feCopy(p.x), y = feCopy(p.y), z = feCopy(p.z), t = feCopy(p.t))
}

func pointBase(): Point {
  val bx = feBaseX()
  val by = feBaseY()
  val bt = feZero()
  feMul(bt, bx, by)
  Point(x = bx, y = by, z = feOne(), t = bt)
}

// p = p + q (complete addition; also correct when p and q are the same point).
func pointAdd(p: in Point, q: in Point): Unit {
  val a = feZero()
  val b = feZero()
  val c = feZero()
  val d = feZero()
  val t = feZero()
  val e = feZero()
  val f = feZero()
  val g = feZero()
  val h = feZero()
  feSub(a, p.y, p.x)
  feSub(t, q.y, q.x)
  feMul(a, a, t)
  feAdd(b, p.x, p.y)
  feAdd(t, q.x, q.y)
  feMul(b, b, t)
  feMul(c, p.t, q.t)
  feMul(c, c, feD2())
  feMul(d, p.z, q.z)
  feAdd(d, d, d)
  feSub(e, b, a)
  feSub(f, d, c)
  feAdd(g, d, c)
  feAdd(h, b, a)
  feMul(p.x, e, f)
  feMul(p.y, h, g)
  feMul(p.z, g, f)
  feMul(p.t, e, h)
}

func pointSwap(p: in Point, q: in Point, b: in Long): Unit {
  feSwap(p.x, q.x, b)
  feSwap(p.y, q.y, b)
  feSwap(p.z, q.z, b)
  feSwap(p.t, q.t, b)
}

func pointPack(p: in Point): slice[Byte] {
  val zi = feZero()
  val tx = feZero()
  val ty = feZero()
  feInvert(zi, p.z)
  feMul(tx, p.x, zi)
  feMul(ty, p.y, zi)
  val acc = fePack(ty)
  val top = acc[31].toInt().xor(feParity(tx).shl(7))
  val list: List[Byte] = newList()
  var i = 0
  while i < 31 {
    list.add(acc[i])
    i = i + 1
  }
  list.add(top.toByte())
  list.toArray()
}

// [s]q for a 32-byte little-endian scalar, as a fixed sequence of 256 masked
// swaps, additions and doublings (a Montgomery ladder over `p` and `q`).
func scalarMult(q0: in Point, s: in slice[Byte]): Point {
  val p = pointIdentity()
  val q = pointCopy(q0)
  var i = 255
  while i >= 0 {
    val bit = s[i / 8].toLong().shr(i % 8).and(1i64)
    pointSwap(p, q, bit)
    pointAdd(q, p)
    pointAdd(p, p)
    pointSwap(p, q, bit)
    i = i - 1
  }
  p
}

func scalarBase(s: in slice[Byte]): Point {
  scalarMult(pointBase(), s)
}

// Decodes a public key and negates it (verification needs -A). None when the
// encoding is not a point or is not canonical.
func decodeNegatedPoint(bytes: in slice[Byte]): Option[Point] {
  val y = feUnpack(bytes)
  // Canonical y: re-encoding must give back the input with its sign bit cleared.
  val reencoded = fePack(y)
  var i = 0
  while i < 31 {
    if reencoded[i] != bytes[i] {
      return None
    }
    i = i + 1
  }
  if reencoded[31].toInt() != bytes[31].toInt().and(0x7f) {
    return None
  }
  val one = feOne()
  val num = feZero()
  val den = feZero()
  feSquare(num, y)
  feMul(den, num, feD())
  feSub(num, num, one)
  feAdd(den, one, den)
  val den2 = feZero()
  val den4 = feZero()
  val den6 = feZero()
  val t = feZero()
  feSquare(den2, den)
  feSquare(den4, den2)
  feMul(den6, den4, den2)
  feMul(t, den6, num)
  feMul(t, t, den)
  fePow2523(t, t)
  feMul(t, t, num)
  feMul(t, t, den)
  feMul(t, t, den)
  val x = feZero()
  feMul(x, t, den)
  val chk = feZero()
  feSquare(chk, x)
  feMul(chk, chk, den)
  if not feEqual(chk, num) {
    feMul(x, x, feSqrtM1())
  }
  feSquare(chk, x)
  feMul(chk, chk, den)
  if not feEqual(chk, num) {
    return None
  }
  val signBit = bytes[31].toInt().shr(7)
  if feIsZero(x) and signBit == 1 {
    return None
  }
  if feParity(x) == signBit {
    feSub(x, feZero(), x)
  }
  val xy = feZero()
  feMul(xy, x, y)
  Some(value = Point(x = x, y = y, z = one, t = xy))
}

func isSmallOrder(p: in Point): Bool {
  val q = pointCopy(p)
  pointAdd(q, q)
  pointAdd(q, q)
  pointAdd(q, q)
  feIsZero(q.x) and feEqual(q.y, q.z)
}

// ---- Scalars mod L ----------------------------------------------------------
// The group order L = 2^252 + 27742317777372353535851937790883648493, little-endian.
func orderL(): slice[Long] {
  [
    0xedi64,
    0xd3i64,
    0xf5i64,
    0x5ci64,
    0x1ai64,
    0x63i64,
    0x12i64,
    0x58i64,
    0xd6i64,
    0x9ci64,
    0xf7i64,
    0xa2i64,
    0xdei64,
    0xf9i64,
    0xdei64,
    0x14i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0i64,
    0x10i64
  ]
}

// Reduces the 64-limb little-endian number in `x` (limbs may exceed a byte)
// modulo L, returning 32 bytes.
func modL(x: in List[Long]): slice[Byte] {
  val l = orderL()
  var i = 63
  while i >= 32 {
    var carry = 0i64
    var j = i - 32
    while j < i - 12 {
      x[j] = x[j] + carry - 16i64 * x[i] * l[j - (i - 32)]
      carry = (x[j] + 128i64).shr(8)
      x[j] = x[j] - carry.shl(8)
      j = j + 1
    }
    x[j] = x[j] + carry
    x[i] = 0i64
    i = i - 1
  }
  var carry2 = 0i64
  var k = 0
  while k < 32 {
    x[k] = x[k] + carry2 - x[31].shr(4) * l[k]
    carry2 = x[k].shr(8)
    x[k] = x[k].and(255i64)
    k = k + 1
  }
  k = 0
  while k < 32 {
    x[k] = x[k] - carry2 * l[k]
    k = k + 1
  }
  val acc: List[Byte] = newList()
  k = 0
  while k < 32 {
    x[k + 1] = x[k + 1] + x[k].shr(8)
    acc.add(x[k].and(255i64).toByte())
    k = k + 1
  }
  acc.toArray()
}

// Reduces a 64-byte hash modulo L.
func reduceHash(h: in slice[Byte]): slice[Byte] {
  val x: List[Long] = newList()
  var i = 0
  while i < 64 {
    x.add(h[i].toLong())
    i = i + 1
  }
  modL(x)
}

// Whether the 32-byte little-endian scalar is below L.
func scalarIsCanonical(s: in slice[Byte]): Bool {
  val l = orderL()
  var i = 31
  while i >= 0 {
    val si = s[i].toLong()
    if si < l[i] {
      return true
    }
    if si > l[i] {
      return false
    }
    i = i - 1
  }
  false
}

// The clamped secret scalar of RFC 8032 §5.1.5: the low 32 bytes of
// SHA-512(seed), with the low three bits and the top bit cleared and bit 254 set.
func clampedScalar(digest: in slice[Byte]): slice[Byte] {
  val a: List[Byte] = newList()
  var i = 0
  while i < 32 {
    var v = digest[i].toInt()
    if i == 0 {
      v = v.and(248)
    }
    if i == 31 {
      v = v.and(127).or(64)
    }
    a.add(v.toByte())
    i = i + 1
  }
  a.toArray()
}

// ---- Public API -------------------------------------------------------------
/// The 32-byte public key of a 32-byte seed (RFC 8032 §5.1.5).
@experimental
pub func ed25519PublicKey(seed: in slice[Byte]): slice[Byte]
  requires: seed.length == 32
  ensures: result.length == 32
{
  val digest = hostSha512Bytes(seed)
  pointPack(scalarBase(clampedScalar(digest)))
}

/// The 64-byte signature of `message` under the private key `seed`
/// (RFC 8032 §5.1.6). Signing is deterministic: the same seed and message
/// always give the same signature.
@experimental
pub func ed25519Sign(seed: in slice[Byte], message: in slice[Byte]): slice[Byte]
  requires: seed.length == 32
  ensures: result.length == 64
{
  val digest = hostSha512Bytes(seed)
  val a = clampedScalar(digest)
  val publicKey = pointPack(scalarBase(a))
  val prefix = digest.slice(32, 64)
  val r = reduceHash(hostSha512Bytes(prefix.concat(message)))
  val encodedR = pointPack(scalarBase(r))
  val h = reduceHash(hostSha512Bytes(encodedR.concat(publicKey).concat(message)))
  val x: List[Long] = newList()
  var i = 0
  while i < 64 {
    x.add(if i < 32 { r[i].toLong() } else { 0i64 })
    i = i + 1
  }
  i = 0
  while i < 32 {
    val hi = h[i].toLong()
    var j = 0
    while j < 32 {
      x[i + j] = x[i + j] + hi * a[j].toLong()
      j = j + 1
    }
    i = i + 1
  }
  encodedR.concat(modL(x))
}

/// Whether `signature` is a valid Ed25519 signature of `message` under
/// `publicKey` (RFC 8032 §5.1.7, with the strict checks described in the
/// module documentation). A key or signature of the wrong length is not
/// valid.
@experimental
pub func ed25519Verify(publicKey: in slice[Byte], message: in slice[Byte], signature: in slice[Byte]): Bool {
  if publicKey.length != 32 or signature.length != 64 {
    return false
  }
  val encodedR = signature.slice(0, 32)
  val s = signature.slice(32, 64)
  if not scalarIsCanonical(s) {
    return false
  }
  match decodeNegatedPoint(publicKey) {
    case None -> false
    case Some(negA) -> {
      if isSmallOrder(negA) {
        return false
      }
      val h = reduceHash(hostSha512Bytes(encodedR.concat(publicKey).concat(message)))
      val p = scalarMult(negA, h)
      pointAdd(p, scalarBase(s))
      bytesEqual(pointPack(p), encodedR)
    }
  }
}
