// metadata_reader_tests.l — exercises `Msil.MetadataReader` against the
// running test PE itself.  The test DLL is a real .NET assembly emitted by
// the compiler's own metadata *writer*, so parsing it back is a
// reader-vs-writer round-trip oracle that needs no version-specific
// reference-pack path.  Auto-discovered by
// `bootstrap/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs`.
// Exit 0 + "ok" in stdout means every assertion held.

package Msil.MetadataReader.Tests

import Std.Core
import Std.Collections
import Std.Testing
import Std.String as Str
import Std.Path as Path
import Std.Environment as Environment
import Std.File as File
import Msil.MetadataReader

// ── Locate + load the running test DLL ───────────────────────────────────────
//
// `StdlibLyricTests.fs::assemblyNameOf` emits this program as
// `metadata_reader_tests.dll` (filename stem, hyphens/dots → underscores).
// `Std.Environment.appBaseDirectory()` reports the load directory.

func selfBytes(): slice[Byte] {
  val p = Path.join(Environment.appBaseDirectory(), "metadata_reader_tests.dll")
  File.readBytesOrPanic(p)
}

func loadPe(): PeImage {
  match readPe(selfBytes()) {
    case Ok(img) -> img
    case Err(e)  -> panic("readPe failed: " + e)
  }
}

func loadRoot(img: in PeImage): MetadataRoot {
  match readMetadataRoot(img) {
    case Ok(r)  -> r
    case Err(e) -> panic("readMetadataRoot failed: " + e)
  }
}

func loadTables(img: in PeImage, root: in MetadataRoot): TablesHeader {
  match readTablesHeader(img, root) {
    case Ok(t)  -> t
    case Err(e) -> panic("readTablesHeader failed: " + e)
  }
}

// ── Tests ────────────────────────────────────────────────────────────────────

// The PE container parses and the metadata root is located inside a section.
func testPeContainer(): Unit {
  val img = loadPe()
  assertTrue(img.peHeaderOff > 0, "pe_container: PE header offset positive")
  assertTrue(img.numSections > 0, "pe_container: at least one section")
  assertTrue(img.cliHeaderRva > 0, "pe_container: managed assembly (CLI RVA set)")
  assertTrue(img.metadataRva > 0, "pe_container: metadata RVA set")
  assertTrue(img.metadataOff > 0, "pe_container: metadata file offset resolved")
  assertTrue(img.metadataOff + img.metadataSize <= img.bytes.length,
    "pe_container: metadata region within file")
}

// RVA→offset maps the CLI-header RVA back to a valid in-file offset, and an
// RVA below every section maps to -1 (unmapped).
func testRvaMapping(): Unit {
  val img = loadPe()
  val off = rvaToOffset(img, img.cliHeaderRva)
  assertTrue(off > 0, "rva_mapping: CLI RVA maps to a positive offset")
  assertTrue(off + img.cliHeaderSize <= img.bytes.length,
    "rva_mapping: CLI header within file")
  assertEqualInt(rvaToOffset(img, 0), -1, "rva_mapping: RVA 0 is unmapped")
}

// The metadata root carries a non-empty version string and the standard set
// of streams; `#~` and `#Strings` are always present; a bogus name is absent.
func testMetadataRoot(): Unit {
  val img  = loadPe()
  val root = loadRoot(img)
  assertTrue(root.versionString.length > 0, "md_root: non-empty version string")
  assertTrue(root.streams.count >= 2, "md_root: at least two streams")
  match findStream(root, "#~") {
    case Some(s) -> assertTrue(s.size > 0, "md_root: #~ stream non-empty")
    case None    -> panic("md_root: #~ stream missing")
  }
  match findStream(root, "#Strings") {
    case Some(s) -> assertTrue(s.fileOff > img.metadataOff, "md_root: #Strings after root")
    case None    -> panic("md_root: #Strings stream missing")
  }
  match findStream(root, "#NoSuchStream") {
    case Some(_) -> panic("md_root: bogus stream name should be absent")
    case None    -> ()
  }
}

// The `#~` header decodes heap-index widths and per-table row counts.  Every
// Lyric-emitted assembly has exactly one Module row and at least one TypeDef
// and one MethodDef.
func testTablesHeader(): Unit {
  val img  = loadPe()
  val root = loadRoot(img)
  val th   = loadTables(img, root)
  assertTrue(th.presentCount > 0, "tables: at least one present table")
  // Table ids: Module=0x00, TypeDef=0x02, MethodDef=0x06.
  assertEqualInt(rowCountOf(th, 0x00), 1, "tables: exactly one Module row")
  assertTrue(rowCountOf(th, 0x02) > 0, "tables: at least one TypeDef row")
  assertTrue(rowCountOf(th, 0x06) > 0, "tables: at least one MethodDef row")
  // Absent / out-of-range table ids read 0.
  assertEqualInt(rowCountOf(th, 63), 0, "tables: absent high table reads 0")
  assertEqualInt(rowCountOf(th, -1), 0, "tables: negative table id reads 0")
  // Heap-width flags must agree with the raw HeapSizes byte.
  assertTrue(th.stringsWide == ((th.heapSizes / 1) % 2 == 1),
    "tables: #Strings width flag matches HeapSizes bit 0")
  assertTrue(th.blobWide == ((th.heapSizes / 4) % 2 == 1),
    "tables: #Blob width flag matches HeapSizes bit 2")
}

// ── Driver ───────────────────────────────────────────────────────────────────

func main(): Int {
  testPeContainer()
  testRvaMapping()
  testMetadataRoot()
  testTablesHeader()
  println("metadata-reader self-test: ok")
  return 0
}
