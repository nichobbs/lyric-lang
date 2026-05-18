// jvm/zip.l — Stage B11: minimal ZIP/JAR assembler (STORED, no compression).
//
// Produces a valid ZIP archive from a list of named byte entries using the
// STORED compression method (uncompressed).  Suitable for assembling JARs
// from class files and text resources (MANIFEST.MF, lyric-contract JSON,
// native-image JSON configs).
//
// ZIP format (PKWARE Application Note §4.3):
//   - Local file headers + data (one per entry)
//   - Central directory (one entry per file)
//   - End of central directory record
//
// CRC32 (ISO 3309) is computed via Jvm.Kernel.crc32; all multi-byte integers
// in ZIP headers are little-endian (unlike class-file big-endian).

package Jvm.Zip

import Std.Core
import Std.Collections
import Jvm.Kernel

// One file entry to be stored in the JAR.
pub record ZipEntry {
  name: String       // path inside the archive, e.g. "META-INF/MANIFEST.MF"
  data: List[Byte]   // raw (uncompressed) file content
}

// Encode a String as UTF-8 bytes via the Jvm.Kernel ByteWriter.
// Used for both entry names and text-content entries (MANIFEST.MF, JSON).
pub func stringToUtf8Bytes(s: in String): List[Byte] {
  val w = writerNew()
  writerModifiedUtf8(w, s)
  writerToList(w)
}

// Encode a String as UTF-8 bytes for ZIP local/central headers.
// PKWARE spec §4.4.17.1: paths use standard UTF-8 with flag bit 11 set.
func encodeNameBytes(name: in String): List[Byte] {
  stringToUtf8Bytes(name)
}

// Write one local file header + data.  Returns the byte offset at which
// this entry's local header begins (needed for the central directory).
func writeLocalEntry(w: in ByteWriter, ent: in ZipEntry, nameBytes: in List[Byte], checksum: in Int): Unit {
  val nameLen  = nameBytes.count
  val dataSize = ent.data.count

  writerU4Le(w,0x04034B50)  // local file header signature PK\x03\x04
  writerU2Le(w,20)           // version needed: 2.0
  writerU2Le(w,2048)         // flags: bit 11 = UTF-8 names
  writerU2Le(w,0)            // compression: STORED
  writerU2Le(w,0)            // mod time
  writerU2Le(w,0)            // mod date
  writerU4Le(w,checksum)     // CRC-32
  writerU4Le(w,dataSize)     // compressed size (= uncompressed for STORED)
  writerU4Le(w,dataSize)     // uncompressed size
  writerU2Le(w,nameLen)      // file name length
  writerU2Le(w,0)            // extra field length
  writerByteList(w,nameBytes)
  writerByteList(w, ent.data)
}

// Write one central directory file header.
func writeCentralEntry(w: in ByteWriter, ent: in ZipEntry, nameBytes: in List[Byte], checksum: in Int, localOffset: in Int): Unit {
  val nameLen  = nameBytes.count
  val dataSize = ent.data.count

  writerU4Le(w,0x02014B50)  // central directory signature PK\x01\x02
  writerU2Le(w,0)            // version made by
  writerU2Le(w,20)           // version needed
  writerU2Le(w,2048)         // flags: UTF-8
  writerU2Le(w,0)            // compression: STORED
  writerU2Le(w,0)            // mod time
  writerU2Le(w,0)            // mod date
  writerU4Le(w,checksum)     // CRC-32
  writerU4Le(w,dataSize)     // compressed size
  writerU4Le(w,dataSize)     // uncompressed size
  writerU2Le(w,nameLen)      // file name length
  writerU2Le(w,0)            // extra field length
  writerU2Le(w,0)            // file comment length
  writerU2Le(w,0)            // disk number start
  writerU2Le(w,0)            // internal file attributes
  writerU4Le(w,0)            // external file attributes
  writerU4Le(w,localOffset)  // relative offset of local file header
  writerByteList(w,nameBytes)
}

// Write the end of central directory record.
func writeEndOfCentralDir(w: in ByteWriter, entryCount: in Int, cdOffset: in Int, cdSize: in Int): Unit {
  writerU4Le(w,0x06054B50)  // EOCD signature PK\x05\x06
  writerU2Le(w,0)            // disk number
  writerU2Le(w,0)            // disk with central directory
  writerU2Le(w,entryCount)   // entries on this disk
  writerU2Le(w,entryCount)   // total entries
  writerU4Le(w,cdSize)       // size of central directory
  writerU4Le(w,cdOffset)     // offset of central directory
  writerU2Le(w,0)            // comment length
}

// Assemble a ZIP/JAR archive from a list of entries.
// Entries are stored uncompressed (STORED method).
// Name bytes are encoded twice (local + central) to avoid List[List[Byte]],
// which the current emitter does not support.
pub func buildJar(entries: in List[ZipEntry]): List[Byte] {
  val w         = writerNew()
  val checksums: List[Int] = newList()
  val offsets:   List[Int] = newList()

  // Pass 1: write local file headers + data.
  var ei = 0
  while ei < entries.count {
    val ent       = entries[ei]
    val nameBytes = encodeNameBytes(ent.name)
    val checksum  = crc32(ent.data)
    checksums.add(checksum)
    offsets.add(writerPos(w))
    writeLocalEntry(w, ent, nameBytes, checksum)
    ei = ei + 1
  }

  // Pass 2: write central directory (name bytes recomputed from entry names).
  val cdOffset = writerPos(w)
  var ci = 0
  while ci < entries.count {
    val nameBytes = encodeNameBytes(entries[ci].name)
    val cent = entries[ci]
    writeCentralEntry(w, cent, nameBytes, checksums[ci], offsets[ci])
    ci = ci + 1
  }
  val cdSize = writerPos(w) - cdOffset

  writeEndOfCentralDir(w, entries.count, cdOffset, cdSize)

  writerToList(w)
}
