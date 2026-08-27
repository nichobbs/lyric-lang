//! jvm/contract_meta_jar.l — JAR-embedded `Lyric.Contract` metadata reader (#3094).
//!
//! JVM counterpart of `Lyric.ContractMeta`'s PE-metadata resource reader
//! (`readAllContractsFromFile`, `Msil.MetadataReader`-backed): a Lyric-JVM
//! producer JAR embeds its per-package contract JSON as plain ZIP entries
//! (`Lyric.Contract` / `Lyric.Contract.<Pkg>`, written by
//! `Jvm.Bridge`'s contract-embedding step) rather than a .NET manifest
//! resource, so restoring it needs the ZIP central-directory reader
//! (`Jvm.ZipReader`, already shared with auto-FFI's `.jmod`/JAR reading)
//! instead of `Msil.MetadataReader`.
//!
//! `loadRestoredPackageJvm` mirrors `Lyric.RestoredPackages.loadRestoredPackage`
//! exactly, down to the `RestoredArtifact` / `RestoredLoadError` shapes — only
//! the entry-extraction step differs, so both backends share
//! `Lyric.RestoredPackages.loadRestoredPackageFromEntries` (and, downstream,
//! `synthesiseArtifact`) unchanged.
package Jvm.ContractMetaJar

import Std.Core
import Std.Collections
import Std.Char as CharMod
import Std.File as File
import Std.String as Str
import Lyric.ContractMeta as Meta
import Lyric.RestoredPackages
import Jvm.ZipReader as ZipReader

func rdU8At(b: in List[Int], o: in Int): Int {
  b[o]
}

// Decode a UTF-8 byte sequence (`List[Int]`, values 0-255, as produced by
// `Jvm.ZipReader.extractEntry`) into a `String`.  Handles the full 1-4 byte
// UTF-8 encoding: a 4-byte (astral) sequence is emitted as a UTF-16
// surrogate pair since `Std.Char.fromInt` only accepts a single code UNIT
// (0..65535).  `Lyric.ContractMeta.escapeJson` deliberately does not
// `\u`-escape non-ASCII text (identifiers can be non-ASCII per the lexer's
// UAX #31 support), so a real contract payload can carry raw multi-byte
// UTF-8 — unlike `Jvm.ClassReader.readUtf8Entry`, which only ever sees JVM
// class/method names and so skips the 4-byte case as unreachable.
// A truncated/malformed lead byte at the end of the buffer is skipped
// rather than panicking — a corrupted JAR degrades to a missing character,
// not a build crash.
func decodeUtf8Bytes(b: in List[Int]): String {
  var s = ""
  var i = 0
  val n = b.count
  while i < n {
    val c0 = rdU8At(b, i)
    if c0 < 128 {
      s = s + ("" + CharMod.fromInt(c0))
      i = i + 1
    } else if c0 / 32 == 6 and i + 1 < n {
      val c1 = rdU8At(b, i + 1)
      val cp = (c0 % 32) * 64 + c1 % 64
      s = s + ("" + CharMod.fromInt(cp))
      i = i + 2
    } else if c0 / 16 == 14 and i + 2 < n {
      val c1 = rdU8At(b, i + 1)
      val c2 = rdU8At(b, i + 2)
      val cp = (c0 % 16) * 4096 + (c1 % 64) * 64 + c2 % 64
      s = s + ("" + CharMod.fromInt(cp))
      i = i + 3
    } else if c0 / 8 == 30 and i + 3 < n {
      val c1 = rdU8At(b, i + 1)
      val c2 = rdU8At(b, i + 2)
      val c3 = rdU8At(b, i + 3)
      val cp = (c0 % 8) * 262144 + (c1 % 64) * 4096 + (c2 % 64) * 64 + c3 % 64
      val adjusted = cp - 65536
      val hi = 55296 + adjusted / 1024
      val lo = 56320 + adjusted % 1024
      s = s + ("" + CharMod.fromInt(hi)) + ("" + CharMod.fromInt(lo))
      i = i + 4
    } else {
      i = i + 1
    }
  }
  s
}

/// Walk every `Lyric.Contract` / `Lyric.Contract.<Pkg>` ZIP entry in
/// `jarPath` and return each as a `Meta.ContractEntry`.  Returns an empty
/// list when the file is missing, unreadable as a ZIP, or carries no such
/// entry (e.g. a non-Lyric JAR) — mirroring
/// `Lyric.ContractMeta.readAllContractsFromFile`'s "absent = empty" contract.
@stable(since = "0.1")
pub func readAllContractsFromJar(jarPath: in String): List[Meta.ContractEntry] {
  val result: List[Meta.ContractEntry] = newList()
  if not File.fileExists(jarPath) {
    return result
  }
  val bytes = File.readBytesOrPanic(jarPath)
  val entries = ZipReader.readZipEntries(bytes)
  val prefix = "Lyric.Contract."
  var i = 0
  while i < entries.count {
    val ent = entries[i]
    if ent.name == "Lyric.Contract" {
      val data = ZipReader.extractEntry(bytes, ent)
      result.add(Meta.ContractEntry(packageName = "", json = decodeUtf8Bytes(data)))
    } else if Str.startsWith(ent.name, prefix) {
      val pkgName = ent.name.substring(prefix.length, ent.name.length - prefix.length)
      val data = ZipReader.extractEntry(bytes, ent)
      result.add(Meta.ContractEntry(packageName = pkgName, json = decodeUtf8Bytes(data)))
    }
    i = i + 1
  }
  result
}

/// Load every restored-dependency contract from a Lyric-JVM producer JAR.
/// JVM counterpart of `Lyric.RestoredPackages.loadRestoredPackage` — same
/// `RestoredArtifact` / `RestoredLoadError` result shape, sourced from the
/// JAR's ZIP entries instead of a PE `Lyric.Contract` resource.
@stable(since = "0.1")
pub func loadRestoredPackageJvm(jarPath: in String): Result[List[RestoredArtifact], RestoredLoadError] {
  if not File.fileExists(jarPath) {
    return Err(error = DllMissing(path = jarPath))
  }
  val entries = readAllContractsFromJar(jarPath)
  loadRestoredPackageFromEntries(jarPath, entries)
}
