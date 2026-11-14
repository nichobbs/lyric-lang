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
import Lyric.Tir

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

func sameBytes(a: in slice[Byte], b: in slice[Byte]): Bool {
  if a.length != b.length {
    return false
  }
  var i = 0
  while i < a.length {
    if a[i] != b[i] {
      return false
    }
    i = i + 1
  }
  true
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

func putFields(w: in IfaceWriter, it: in DefPathInterner, fs: in List[IfField]) {
  putU(w, fs.count)
  for f in fs {
    putStr(w, f.name)
    putTy(w, it, f.ty)
    putBool(w, f.mutable)
    putBool(w, f.hasDefault)
    match f.dflt {
      case Some(d) -> {
        putBool(w, true)
        putExpr(w, it, d)
        putEntries(w, it, f.dfltEntries)
      }
      case None -> putBool(w, false)
    }
  }
}

func readFields(r: in IfaceReader, it: in DefPathInterner): List[IfField] {
  val n = readCount(r)
  val res: List[IfField] = newList()
  var k = 0
  while k < n and not r.failed {
    val name = readStr(r)
    val ty = readTy(r, it)
    val mutable = readBool(r)
    val hasDefault = readBool(r)
    var dflt: Option[TExpr] = None
    var es: List[TSymEntry] = newList()
    if readBool(r) {
      dflt = Some(value = readExpr(r, it))
      es = readEntries(r, it)
    }
    res.add(IfField(name = name, ty = ty, mutable = mutable, hasDefault = hasDefault, dflt = dflt, dfltEntries = es))
    k = k + 1
  }
  res
}

func putDetail(w: in IfaceWriter, it: in DefPathInterner, d: in IfDetail) {
  match d {
    case IfDNone -> putU(w, 0)
    case IfDFunc(tps, ps, ret, isAsync, isAxiom, isPure) -> {
      putU(w, 1)
      putTypeParams(w, it, tps)
      putU(w, ps.count)
      for p in ps {
        putStr(w, p.name)
        putU(w, modeCode(p.mode))
        putTy(w, it, p.ty)
        putBool(w, p.hasDefault)
        match p.dflt {
          case Some(d) -> {
            putBool(w, true)
            putExpr(w, it, d)
            putEntries(w, it, p.dfltEntries)
          }
          case None -> putBool(w, false)
        }
      }
      putTy(w, it, ret)
      putBool(w, isAsync)
      putBool(w, isAxiom)
      putBool(w, isPure)
    }
    case IfDRecord(tps, fs) -> {
      putU(w, 2)
      putTypeParams(w, it, tps)
      putFields(w, it, fs)
    }
    case IfDType(tps) -> {
      putU(w, 3)
      putTypeParams(w, it, tps)
    }
    case IfDAlias(tps, underlying) -> {
      putU(w, 4)
      putTypeParams(w, it, tps)
      putTy(w, it, underlying)
    }
    case IfDCase(fs) -> {
      putU(w, 5)
      putFields(w, it, fs)
    }
    case IfDValue(ty, mutable, value) -> {
      putU(w, 6)
      putTy(w, it, ty)
      putBool(w, mutable)
      match value {
        case None -> putBool(w, false)
        case Some(l) -> {
          putBool(w, true)
          putLit(w, l)
        }
      }
    }
    case IfDExtern(tps, host) -> {
      putU(w, 7)
      putTypeParams(w, it, tps)
      putStr(w, host)
    }
  }
}

func readDetail(r: in IfaceReader, it: in DefPathInterner): IfDetail {
  val tag = readU(r)
  if r.failed {
    return IfDNone
  }
  match tag {
    case 0 -> IfDNone
    case 1 -> {
      val tps = readTypeParams(r, it)
      val n = readCount(r)
      val ps: List[IfParam] = newList()
      var k = 0
      while k < n and not r.failed {
        val name = readStr(r)
        val mc = readU(r)
        val ty = readTy(r, it)
        val hasDefault = readBool(r)
        var dflt: Option[TExpr] = None
        var des: List[TSymEntry] = newList()
        if readBool(r) {
          dflt = Some(value = readExpr(r, it))
          des = readEntries(r, it)
        }
        match modeOfCode(mc) {
          case Some(m) -> ps.add(IfParam(name = name, mode = m, ty = ty, hasDefault = hasDefault, dflt = dflt, dfltEntries = des))
          case None -> readFail(r, "unknown parameter mode " + toString(mc))
        }
        k = k + 1
      }
      val ret = readTy(r, it)
      val isAsync = readBool(r)
      val isAxiom = readBool(r)
      val isPure = readBool(r)
      IfDFunc(typeParams = tps, params = ps, ret = ret, isAsync = isAsync, isAxiom = isAxiom, isPure = isPure)
    }
    case 2 -> {
      val tps = readTypeParams(r, it)
      IfDRecord(typeParams = tps, fields = readFields(r, it))
    }
    case 3 -> IfDType(typeParams = readTypeParams(r, it))
    case 4 -> {
      val tps = readTypeParams(r, it)
      IfDAlias(typeParams = tps, underlying = readTy(r, it))
    }
    case 5 -> IfDCase(fields = readFields(r, it))
    case 6 -> {
      val ty = readTy(r, it)
      val mutable = readBool(r)
      val value = if readBool(r) then Some(value = readLit(r)) else None
      IfDValue(ty = ty, mutable = mutable, value = value)
    }
    case 7 -> {
      val tps = readTypeParams(r, it)
      IfDExtern(typeParams = tps, host = readStr(r))
    }
    case _ -> {
      readFail(r, "unknown declaration detail tag " + toString(tag))
      IfDNone
    }
  }
}

/// The canonical bytes of `i`, or the reason it cannot be written: a type
/// that names a declaration `it` has no DefPath for.
pub func encodeIface(i: in Iface, it: in DefPathInterner): Result[slice[Byte], String] {
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
    putDetail(w, it, d.detail)
  }
  if w.err.length > 0 {
    Err(error = w.err)
  } else {
    Ok(value = finishIface(w))
  }
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
pub func decodeIface(bytes: in slice[Byte], it: in DefPathInterner): Result[Iface, String] {
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
    val detail = readDetail(r, it)
    if not r.failed {
      match ifKindOfCode(kindCode) {
        case None -> readFail(r, "unknown declaration kind " + toString(kindCode))
        case Some(kind) -> match ifVisOfCode(visCode) {
          case None -> readFail(r, "unknown visibility " + toString(visCode))
          case Some(vis) -> decls.add(IfDecl(path = path, kind = kind, vis = vis, detail = detail))
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
      match encodeIface(iface, it) {
        case Err(msg) -> Err(error = msg)
        case Ok(again) -> if not sameBytes(again, bytes) {
          Err(error = "the interface is not in canonical form")
        } else {
          Ok(value = iface)
        }
      }
    }
  }
}
