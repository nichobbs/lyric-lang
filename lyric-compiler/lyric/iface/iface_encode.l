//! iface_encode.l - encoding, decoding, canonical order and hash of a
//! `Lyric.Iface.Iface` (docs/70 §9.6).
//!
//! `encodeIface` writes the canonical form: declarations sorted by DefPath key,
//! and the string lists (re-exports, annotations, targets, built-against)
//! sorted, so the bytes do not depend on the order a producer happened to
//! collect them in.  `decodeIface` is its inverse and returns the canonical
//! order.  `ifaceHash` is the SHA-256 of the canonical bytes, the hash a
//! dependent records in its `builtAgainst`.
package Lyric.Iface

import Std.Core
import Std.Collections
import Std.Hash as Hash
import Std.String as Str
import Std.Sort as Sort
import Lyric.Symbols

func sortedStrings(xs: in List[String]): List[String] {
  val sorted = Sort.sort(xs.toArray(), { a, b -> Str.compare(a, b) })
  val buf: List[String] = newList()
  var i = 0
  while i < sorted.length {
    buf.add(sorted[i])
    i = i + 1
  }
  buf
}

func declKey(d: in IfDecl): String {
  defPathKey(d.path)
}

/// The canonical form of `i`: the order `encodeIface` writes and
/// `decodeIface` returns.
pub func canonicalIface(i: in Iface): Iface {
  val decls = Sort.sort(i.decls.toArray(), { a, b -> Str.compare(declKey(a), declKey(b)) })
  val outDecls: List[IfDecl] = newList()
  var k = 0
  while k < decls.length {
    outDecls.add(decls[k])
    k = k + 1
  }
  val against = Sort.sort(i.header.builtAgainst.toArray(), { a, b -> Str.compare(a.pkg, b.pkg) })
  val outAgainst: List[IfBuiltAgainst] = newList()
  var j = 0
  while j < against.length {
    outAgainst.add(against[j])
    j = j + 1
  }
  Iface(
    header = IfHeader(
      formatVersion = ifaceFormatVersion,
      pkg = i.header.pkg,
      builtAgainst = outAgainst,
      verification = i.header.verification,
      consumerAnnotations = sortedStrings(i.header.consumerAnnotations),
      targets = sortedStrings(i.header.targets)
    ),
    decls = outDecls,
    reexports = sortedStrings(i.reexports)
  )
}

func putStrList(w: in IfaceWriter, xs: in List[String]) {
  putU(w, xs.count)
  for s in xs {
    putStr(w, s)
  }
}

func putDefPath(w: in IfaceWriter, p: in DefPath) {
  putStr(w, p.pkg)
  putU(w, p.segments.count)
  for s in p.segments {
    putStr(w, s)
  }
}

/// The canonical bytes of `i`.
pub func encodeIface(i: in Iface): slice[Byte] {
  val c = canonicalIface(i)
  val w = newIfaceWriter()
  putStr(w, c.header.pkg)
  putU(w, c.header.builtAgainst.count)
  for b in c.header.builtAgainst {
    putStr(w, b.pkg)
    putStr(w, b.version)
    putStr(w, b.hash)
  }
  putU(w, ifVerifCode(c.header.verification))
  putStrList(w, c.header.consumerAnnotations)
  putStrList(w, c.header.targets)
  putStrList(w, c.reexports)
  putU(w, c.decls.count)
  for d in c.decls {
    putDefPath(w, d.path)
    putU(w, ifKindCode(d.kind))
    putU(w, ifVisCode(d.vis))
  }
  finishIface(w)
}

/// The interface hash of §9.6: SHA-256 of the canonical bytes, as lower-case hex.
pub func ifaceHash(bytes: in slice[Byte]): String {
  Str.toLower(Hash.sha256OfBytes(bytes))
}

func readStrList(r: in IfaceReader): List[String] {
  val n = readCount(r)
  val buf: List[String] = newList()
  var k = 0
  while k < n and not r.failed {
    buf.add(readStr(r))
    k = k + 1
  }
  buf
}

func readDefPath(r: in IfaceReader): DefPath {
  val pkg = readStr(r)
  val n = readCount(r)
  val segs: List[String] = newList()
  var k = 0
  while k < n and not r.failed {
    segs.add(readStr(r))
    k = k + 1
  }
  DefPath(pkg = pkg, segments = segs)
}

/// Decodes `bytes`.  The error names the first problem and the byte it was
/// found at; a file whose body is followed by extra bytes, or whose lists are
/// not in canonical order, is rejected too, so one interface has one image.
pub func decodeIface(bytes: in slice[Byte]): Result[Iface, String] {
  val r = newIfaceReader(bytes)
  readIfacePrelude(r)
  val pkg = readStr(r)
  val nAgainst = readCount(r)
  val against: List[IfBuiltAgainst] = newList()
  var a = 0
  while a < nAgainst and not r.failed {
    val p = readStr(r)
    val v = readStr(r)
    val h = readStr(r)
    against.add(IfBuiltAgainst(pkg = p, version = v, hash = h))
    a = a + 1
  }
  val verifCode = readU(r)
  val annotations = readStrList(r)
  val targets = readStrList(r)
  val reexports = readStrList(r)
  val nDecls = readCount(r)
  val decls: List[IfDecl] = newList()
  var d = 0
  while d < nDecls and not r.failed {
    val path = readDefPath(r)
    val kindCode = readU(r)
    val visCode = readU(r)
    if not r.failed {
      match ifKindOfCode(kindCode) {
        case None -> readFail(r, "unknown declaration kind " + toString(kindCode))
        case Some(kind) -> match ifVisOfCode(visCode) {
          case None -> readFail(r, "unknown visibility " + toString(visCode))
          case Some(vis) -> decls.add(IfDecl(path = path, kind = kind, vis = vis))
        }
      }
    }
    d = d + 1
  }
  if r.failed {
    return Err(error = r.err)
  }
  if not readAtEnd(r) {
    return Err(error = "trailing bytes after the interface body (at byte " + toString(r.pos) + ")")
  }
  match ifVerifOfCode(verifCode) {
    case None -> Err(error = "unknown verification level " + toString(verifCode))
    case Some(verification) -> {
      val iface = Iface(
        header = IfHeader(
          formatVersion = ifaceFormatVersion,
          pkg = pkg,
          builtAgainst = against,
          verification = verification,
          consumerAnnotations = annotations,
          targets = targets
        ),
        decls = decls,
        reexports = reexports
      )
      val again = encodeIface(iface)
      if again.length != bytes.length or ifaceHash(again) != ifaceHash(bytes) {
        Err(error = "the interface is not in canonical form")
      } else {
        Ok(value = iface)
      }
    }
  }
}
