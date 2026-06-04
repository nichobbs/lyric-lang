// metadata_reader_tests.l — exercises `Msil.MetadataReader` against the
// running test PE itself.  The test DLL is a real .NET assembly emitted by
// the compiler's own metadata *writer*, so parsing it back is a
// reader-vs-writer round-trip oracle that needs no version-specific
// reference-pack path.  Auto-discovered by
// `bootstrap/tests/Lyric.Emitter.Tests/StdlibLyricTests.fs`.
// Exit 0 + "ok" in stdout means every assertion held.
//
// Placement note: this test lives here, not under `lyric-compiler/`, because
// it must compile *and run* a program that emits a real PE (then parse that
// PE back) — and the `*_tests.l` auto-discovery harness is the only mechanism
// that does so without adding a per-test F# runner (which the project
// disallows).  The import direction (a stdlib-tests file depending on a
// compiler package) is a test-harness artefact, not a library dependency:
// the stdlib library itself does not import `Msil.*`.  Moving this test
// under `lyric-compiler/tests/` is a follow-up once that directory exists
// and gains a parallel auto-discovery hook.

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

// A method with primitive parameters, used by the Phase 3b overload-resolution
// tests to resolve against this program's own metadata.
func addInts(a: Int, b: Int): Int { a + b }

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
  assertTrue(th.guidWide == ((th.heapSizes / 2) % 2 == 1),
    "tables: #GUID width flag matches HeapSizes bit 1")
  assertTrue(th.blobWide == ((th.heapSizes / 4) % 2 == 1),
    "tables: #Blob width flag matches HeapSizes bit 2")
}

func loadLayout(img: in PeImage, th: in TablesHeader): TableLayout {
  match computeLayout(img, loadRoot(img), th) {
    case Ok(l)  -> l
    case Err(e) -> panic("computeLayout failed: " + e)
  }
}

// The compressed-uint reader inverts the writer's three-form encoding.
func testCompressedUInt(): Unit {
  // 1-byte form: 0x03 → 3.
  val one: List[Byte] = newList()
  one.add(0x03u8)
  val r1 = readCompressedUInt(one.toArray(), 0)
  assertEqualInt(r1.value, 3, "cuint: 1-byte value")
  assertEqualInt(r1.byteWidth, 1, "cuint: 1-byte width")
  // 2-byte form: 0x81 0x00 → 0x100 = 256.
  val two: List[Byte] = newList()
  two.add(0x81u8)  two.add(0x00u8)
  val r2 = readCompressedUInt(two.toArray(), 0)
  assertEqualInt(r2.value, 256, "cuint: 2-byte value")
  assertEqualInt(r2.byteWidth, 2, "cuint: 2-byte width")
  // 4-byte form: 0xC0 0x00 0x40 0x00 → 0x4000 = 16384.
  val four: List[Byte] = newList()
  four.add(0xC0u8)  four.add(0x00u8)  four.add(0x40u8)  four.add(0x00u8)
  val r4 = readCompressedUInt(four.toArray(), 0)
  assertEqualInt(r4.value, 16384, "cuint: 4-byte value")
  assertEqualInt(r4.byteWidth, 4, "cuint: 4-byte width")
  // Boundary: 0x7F → 127 — last value still in the 1-byte form.
  val max1: List[Byte] = newList()
  max1.add(0x7Fu8)
  val rMax1 = readCompressedUInt(max1.toArray(), 0)
  assertEqualInt(rMax1.value, 127, "cuint: max 1-byte (0x7F)")
  assertEqualInt(rMax1.byteWidth, 1, "cuint: width at 1-byte ceiling")
  // Boundary: 0x80 0x80 → 128 — first value that requires the 2-byte form.
  val min2: List[Byte] = newList()
  min2.add(0x80u8)  min2.add(0x80u8)
  val rMin2 = readCompressedUInt(min2.toArray(), 0)
  assertEqualInt(rMin2.value, 128, "cuint: min 2-byte (0x80 0x80)")
  assertEqualInt(rMin2.byteWidth, 2, "cuint: width at 2-byte floor")
  // Boundary: 0xBF 0xFF → 16383 — last value still in the 2-byte form.
  val max2: List[Byte] = newList()
  max2.add(0xBFu8)  max2.add(0xFFu8)
  val rMax2 = readCompressedUInt(max2.toArray(), 0)
  assertEqualInt(rMax2.value, 16383, "cuint: max 2-byte (0xBF 0xFF)")
  assertEqualInt(rMax2.byteWidth, 2, "cuint: width at 2-byte ceiling")
}

// Layer 4 oracle: the running test PE's metadata tables decode to the
// expected type and method names.  The Lyric emitter compiles this program's
// package `Msil.MetadataReader.Tests` into a TypeDef named `Program` (with the
// package as its namespace) whose methods include the program entry `main`.
func testTableRows(): Unit {
  val img    = loadPe()
  val root   = loadRoot(img)
  val th     = loadTables(img, root)
  val layout = loadLayout(img, th)
  val typeCount = rowCountOf(th, 0x02)
  assertTrue(typeCount >= 2, "rows: at least <Module> + one real TypeDef")

  // Find the `Program` type and confirm its namespace and a `main` method.
  var foundProgram = false
  var foundMain    = false
  var ti = 1
  while ti <= typeCount {
    val td = readTypeDef(img, layout, ti)
    if td.name == "Program" and Str.contains(td.namespaceName, "MetadataReader.Tests") {
      foundProgram = true
      val mr = methodRange(img, layout, th, ti)
      var mi = mr.start
      while mi <= mr.endRow {
        val md = readMethodDef(img, layout, mi)
        if md.name == "main" { foundMain = true }
        // Every method name resolves to a non-empty #Strings entry.
        assertTrue(md.name.length > 0, "rows: method name non-empty")
        // `addInts(a: Int, b: Int): Int` is defined here for the overload-
        // resolution tests; its Param rows give the running-PE oracle for
        // `readParam`.  Row[paramListStart] is `a` (sequence 1), the next
        // row is `b` (sequence 2).
        if md.name == "addInts" {
          val p1 = readParam(img, layout, md.paramListStart)
          assertEqualInt(p1.sequence, 1, "rows: addInts param0 sequence=1")
          assertEqual(p1.name, "a", "rows: addInts param0 name")
          val p2 = readParam(img, layout, md.paramListStart + 1)
          assertEqualInt(p2.sequence, 2, "rows: addInts param1 sequence=2")
          assertEqual(p2.name, "b", "rows: addInts param1 name")
        }
        mi = mi + 1
      }
    }
    ti = ti + 1
  }
  assertTrue(foundProgram, "rows: found the `Program` TypeDef in this package")
  assertTrue(foundMain, "rows: `Program` owns a `main` method")

  // The very first TypeDef row is always the `<Module>` pseudo-type.
  assertEqual(readTypeDef(img, layout, 1).name, "<Module>",
    "rows: TypeDef[1] is <Module>")
}

// MethodDef signatures resolve to a non-empty #Blob (every method has a
// MethodDefSig), and the blob's first byte is a valid calling convention.
func testMethodSigBlobs(): Unit {
  val img    = loadPe()
  val th     = loadTables(img, loadRoot(img))
  val layout = loadLayout(img, th)
  val methodCount = rowCountOf(th, 0x06)
  assertTrue(methodCount > 0, "sig: at least one MethodDef")
  val md  = readMethodDef(img, layout, 1)
  val sig = blobAt(img, layout, md.sigBlob)
  assertTrue(sig.length > 0, "sig: MethodDef[1] has a non-empty signature blob")
  // Low nibble of the calling convention is DEFAULT(0)/VARARG(5)/GENERIC(0x10)
  // etc.; the HASTHIS(0x20)/EXPLICITTHIS(0x40) bits may also be set.  At minimum
  // the byte is < 0x80 (no reserved high bit) for a MethodDefSig.
  assertTrue((sig[0] * 1) < 0x80, "sig: calling-convention byte is well-formed")
}

// Extract the element-type byte of an `STPrim`, or -1 for any other shape.
func primByte(t: in SigType): Int {
  match t {
    case STPrim(e) -> e
    case _         -> -1
  }
}

// Layer 5: the signature decoder is the inverse of the emitter's
// `buildStaticMethodSig`/`buildInstanceMethodSig` + `bufMsilType`.  These
// blobs are exactly what those writers emit for the given shapes.
func testSigDecodeRoundTrip(): Unit {
  // Static `(Int, String): Bool` → DEFAULT, 2 params, BOOLEAN ret, I4, STRING.
  val s1: List[Byte] = newList()
  s1.add(0x00u8)  s1.add(0x02u8)  s1.add(0x02u8)  s1.add(0x08u8)  s1.add(0x0Eu8)
  match decodeMethodSig(s1.toArray()) {
    case Err(e) -> panic("sigrt: static decode failed: " + e)
    case Ok(d) -> {
      assertTrue(not d.hasThis, "sigrt: static has no `this`")
      assertEqualInt(d.paramTypes.count, 2, "sigrt: static param count")
      assertEqualInt(primByte(d.returnType), 0x02, "sigrt: static returns Bool")
      assertEqualInt(primByte(d.paramTypes[0]), 0x08, "sigrt: param0 is I4")
      assertEqualInt(primByte(d.paramTypes[1]), 0x0E, "sigrt: param1 is String")
    }
  }
  // Instance `(): Void` → HASTHIS, 0 params, VOID ret.
  val s2: List[Byte] = newList()
  s2.add(0x20u8)  s2.add(0x00u8)  s2.add(0x01u8)
  match decodeMethodSig(s2.toArray()) {
    case Err(e) -> panic("sigrt: instance decode failed: " + e)
    case Ok(d) -> {
      assertTrue(d.hasThis, "sigrt: instance has `this`")
      assertEqualInt(d.paramTypes.count, 0, "sigrt: instance param count")
      assertEqualInt(primByte(d.returnType), 0x01, "sigrt: instance returns Void")
    }
  }
  // Static `(slice[Byte]): Void` → DEFAULT, 1 param, VOID ret, SZARRAY of U1.
  val s3: List[Byte] = newList()
  s3.add(0x00u8)  s3.add(0x01u8)  s3.add(0x01u8)  s3.add(0x1Du8)  s3.add(0x05u8)
  match decodeMethodSig(s3.toArray()) {
    case Err(e) -> panic("sigrt: array decode failed: " + e)
    case Ok(d) -> {
      assertEqualInt(d.paramTypes.count, 1, "sigrt: array param count")
      match d.paramTypes[0] {
        case STSzArray(elem) ->
          assertEqualInt(primByte(elem), 0x05, "sigrt: array element is U1")
        case _ -> panic("sigrt: expected an SZARRAY parameter")
      }
    }
  }
  // Empty blob is rejected.
  val empty: List[Byte] = newList()
  match decodeMethodSig(empty.toArray()) {
    case Ok(_)  -> panic("sigrt: empty blob should be rejected")
    case Err(_) -> ()
  }
  // Static `(ByRef Int): Void` → DEFAULT, 1 param, VOID ret, BYREF I4.
  val sByRef: List[Byte] = newList()
  sByRef.add(0x00u8)  sByRef.add(0x01u8)  sByRef.add(0x01u8)
  sByRef.add(0x10u8)  sByRef.add(0x08u8)
  match decodeMethodSig(sByRef.toArray()) {
    case Err(e) -> panic("sigrt: byref decode failed: " + e)
    case Ok(d) -> {
      assertEqualInt(d.paramTypes.count, 1, "sigrt: byref param count")
      match d.paramTypes[0] {
        case STByRef(inner) ->
          assertEqualInt(primByte(inner), 0x08, "sigrt: byref inner is I4")
        case _ -> panic("sigrt: expected an STByRef parameter")
      }
    }
  }
  // Static `(Ptr Bool): Void` → DEFAULT, 1 param, VOID ret, PTR Bool.
  val sPtr: List[Byte] = newList()
  sPtr.add(0x00u8)  sPtr.add(0x01u8)  sPtr.add(0x01u8)
  sPtr.add(0x0Fu8)  sPtr.add(0x02u8)
  match decodeMethodSig(sPtr.toArray()) {
    case Err(e) -> panic("sigrt: ptr decode failed: " + e)
    case Ok(d) -> {
      match d.paramTypes[0] {
        case STPtr(inner) ->
          assertEqualInt(primByte(inner), 0x02, "sigrt: ptr inner is Bool")
        case _ -> panic("sigrt: expected an STPtr parameter")
      }
    }
  }
  // Static `(Var 0): Void` → DEFAULT, 1 param, VOID ret, VAR 0.
  val sVar: List[Byte] = newList()
  sVar.add(0x00u8)  sVar.add(0x01u8)  sVar.add(0x01u8)
  sVar.add(0x13u8)  sVar.add(0x00u8)
  match decodeMethodSig(sVar.toArray()) {
    case Err(e) -> panic("sigrt: var decode failed: " + e)
    case Ok(d) -> {
      match d.paramTypes[0] {
        case STVar(idx) -> assertEqualInt(idx, 0, "sigrt: var index is 0")
        case _ -> panic("sigrt: expected an STVar parameter")
      }
    }
  }
  // Static `(MVar 1): Void` → DEFAULT, 1 param, VOID ret, MVAR 1.
  val sMVar: List[Byte] = newList()
  sMVar.add(0x00u8)  sMVar.add(0x01u8)  sMVar.add(0x01u8)
  sMVar.add(0x1Eu8)  sMVar.add(0x01u8)
  match decodeMethodSig(sMVar.toArray()) {
    case Err(e) -> panic("sigrt: mvar decode failed: " + e)
    case Ok(d) -> {
      match d.paramTypes[0] {
        case STMVar(idx) -> assertEqualInt(idx, 1, "sigrt: mvar index is 1")
        case _ -> panic("sigrt: expected an STMVar parameter")
      }
    }
  }
  // Static `(GenericInst Class(tok=5) [Int]): Void` → DEFAULT, 1 param, VOID
  // ret, GENERICINST CLASS token 1 arg I4.
  val sGi: List[Byte] = newList()
  sGi.add(0x00u8)  sGi.add(0x01u8)  sGi.add(0x01u8)
  sGi.add(0x15u8)  sGi.add(0x12u8)  sGi.add(0x05u8)
  sGi.add(0x01u8)  sGi.add(0x08u8)
  match decodeMethodSig(sGi.toArray()) {
    case Err(e) -> panic("sigrt: gi decode failed: " + e)
    case Ok(d) -> {
      match d.paramTypes[0] {
        case STGenericInst(_, tok, args) -> {
          assertEqualInt(tok, 5, "sigrt: gi token is 5")
          assertEqualInt(args.count, 1, "sigrt: gi has 1 arg")
          assertEqualInt(primByte(args[0]), 0x08, "sigrt: gi arg0 is I4")
        }
        case _ -> panic("sigrt: expected an STGenericInst parameter")
      }
    }
  }
}

// Layer 5 oracle: every MethodDefSig in the running PE decodes, and the
// program entry `main` decodes to a static, parameterless method.
func testSigDecodeOnSelf(): Unit {
  val img    = loadPe()
  val th     = loadTables(img, loadRoot(img))
  val layout = loadLayout(img, th)
  val methodCount = rowCountOf(th, 0x06)
  var mi = 1
  var checkedMain = false
  while mi <= methodCount {
    val md  = readMethodDef(img, layout, mi)
    val sig = blobAt(img, layout, md.sigBlob)
    match decodeMethodSig(sig) {
      case Err(e) -> panic("sigself: MethodDef[" + Str.fromInt(mi) + "] (" + md.name + ") failed: " + e)
      case Ok(d) -> {
        if md.name == "main" {
          checkedMain = true
          assertTrue(not d.hasThis, "sigself: main is static")
          assertEqualInt(d.paramTypes.count, 0, "sigself: main has no parameters")
        }
      }
    }
    mi = mi + 1
  }
  assertTrue(checkedMain, "sigself: decoded the `main` signature")
}

// Resolve a CLASS / VALUETYPE SigType's TypeDefOrRef token to a name, or "".
func resolveSigType(img: in PeImage, layout: in TableLayout, th: in TablesHeader,
                    t: in SigType): String {
  val tok = sigClassToken(t)
  if tok < 0 { "" } else { resolveTypeDefOrRefName(img, layout, th, tok) }
}

// A CLASS / VALUETYPE method-signature token resolves to the referenced type's
// fully-qualified name.  The running PE's own helper methods return records
// (e.g. `loadPe(): PeImage`), which are emitted as classes, so their return
// signature carries a TypeDefOrRef token naming this package's type.
func testTypeRefResolution(): Unit {
  val img    = loadPe()
  val th     = loadTables(img, loadRoot(img))
  val layout = loadLayout(img, th)
  val methodCount = rowCountOf(th, 0x06)
  var mi = 1
  var resolvedSome = false
  var sawPeImage = false
  while mi <= methodCount {
    val md = readMethodDef(img, layout, mi)
    match decodeMethodSig(blobAt(img, layout, md.sigBlob)) {
      case Err(_) -> {}
      case Ok(d) -> {
        val rn = resolveSigType(img, layout, th, d.returnType)
        if rn.length > 0 {
          resolvedSome = true
          // A resolved type name is a real (possibly namespaced) identifier
          // — it never contains an embedded space.
          assertTrue(not Str.contains(rn, " "), "typeref: resolved name contains no spaces")
          if Str.contains(rn, "PeImage") { sawPeImage = true }
        }
        var pj = 0
        while pj < d.paramTypes.count {
          val pn = resolveSigType(img, layout, th, d.paramTypes[pj])
          if pn.length > 0 { resolvedSome = true }
          pj = pj + 1
        }
      }
    }
    mi = mi + 1
  }
  assertTrue(resolvedSome, "typeref: at least one class-typed signature token resolved")
  assertTrue(sawPeImage, "typeref: a method returning PeImage resolved to its type name")
}

// Phase 3a (hermetic): a type→assembly index built over the running test DLL
// resolves this package's own `Program` type back to the test assembly.
func testTypeIndexSelf(): Unit {
  val dll = Path.join(Environment.appBaseDirectory(), "metadata_reader_tests.dll")
  val paths: List[String] = newList()
  paths.add(dll)
  val idx = buildTypeIndex(paths)
  match assemblyForType(idx, "Msil.MetadataReader.Tests.Program") {
    case None    -> panic("index: own Program type not found")
    case Some(a) -> assertEqual(a, "metadata_reader_tests", "index: Program → test assembly")
  }
  match assemblyForType(idx, "No.Such.Type") {
    case Some(_) -> panic("index: bogus type should be absent")
    case None    -> ()
  }
}

// Phase 3a: the reference-assembly pack is discoverable, and a type→assembly
// index over System.Runtime.dll resolves a known BCL type.  (The .NET ref pack
// is present wherever the toolchain builds against net10.0, so discovery is
// expected to succeed in any build environment.)
func testRefPackDiscovery(): Unit {
  match refPackDir() {
    case None -> panic("discovery: reference-assembly pack not found")
    case Some(dir) -> {
      assertTrue(File.dirExists(dir), "discovery: ref dir exists")
      val asms = enumRefAssemblies(dir)
      assertTrue(asms.count > 0, "discovery: ref pack has assemblies")
      val rt = Path.join(dir, "System.Runtime.dll")
      assertTrue(File.fileExists(rt), "discovery: System.Runtime.dll present")
      val one: List[String] = newList()
      one.add(rt)
      val idx = buildTypeIndex(one)
      match assemblyForType(idx, "System.Object") {
        case None    -> panic("discovery: System.Object not indexed")
        case Some(a) -> assertEqual(a, "System.Runtime", "discovery: System.Object → System.Runtime")
      }
      match assemblyForType(idx, "System.Math") {
        case None    -> panic("discovery: System.Math not indexed")
        case Some(a) -> assertEqual(a, "System.Runtime", "discovery: System.Math → System.Runtime")
      }
    }
  }
}

func prim(b: in Int): SigType { STPrim(elemByte = b) }

// scoreSigType invariance for `STSzArray`: CLR single-dimension arrays
// are invariant at the IL level, so `int[]` must NOT score positively
// against `long[]` (a widening on the element would mis-bind at JIT).
// Direct unit-test of the matcher PR #1881 hardened.
func testScoreSigTypeArrayInvariance(): Unit {
  val i4Arr = STSzArray(elem = prim(0x08))   // int32[]
  val i8Arr = STSzArray(elem = prim(0x0A))   // int64[]
  assertEqualInt(scoreSigType(i4Arr, i4Arr), 2,
    "score: int[] vs int[] is exact (2)")
  assertEqualInt(scoreSigType(i4Arr, i8Arr), -1,
    "score: int[] vs long[] is reject (-1) — arrays invariant")
  assertEqualInt(scoreSigType(i8Arr, i4Arr), -1,
    "score: long[] vs int[] is reject (-1) — arrays invariant")
}

// Phase 3b (hermetic): overload resolution against this program's own
// metadata.  `addInts(Int, Int): Int` resolves for matching and widening
// argument types and rejects an arity mismatch.
func testOverloadResolveSelf(): Unit {
  val img    = loadPe()
  val th     = loadTables(img, loadRoot(img))
  val layout = loadLayout(img, th)
  val fqn    = "Msil.MetadataReader.Tests.Program"

  // Exact match: (I4, I4).
  val i4i4: List[SigType] = newList()
  i4i4.add(prim(0x08))  i4i4.add(prim(0x08))
  match resolveOverloadIn(img, layout, th, fqn, "addInts", i4i4) {
    case None -> panic("overload: addInts(Int,Int) not resolved")
    case Some(m) -> {
      assertTrue(m.isStatic, "overload: addInts is static")
      assertEqualInt(m.paramTypes.count, 2, "overload: addInts arity 2")
      match m.returnType {
        case STPrim(e) -> assertEqualInt(e, 0x08, "overload: addInts returns Int")
        case _         -> panic("overload: addInts return not primitive")
      }
    }
  }

  // Widening: (I2, I2) still binds addInts(Int, Int).
  val i2i2: List[SigType] = newList()
  i2i2.add(prim(0x06))  i2i2.add(prim(0x06))
  match resolveOverloadIn(img, layout, th, fqn, "addInts", i2i2) {
    case None    -> panic("overload: addInts should accept widening (I2→I4)")
    case Some(_) -> ()
  }

  // Arity mismatch: a single argument does not bind the 2-parameter method.
  val one: List[SigType] = newList()
  one.add(prim(0x08))
  match resolveOverloadIn(img, layout, th, fqn, "addInts", one) {
    case Some(_) -> panic("overload: arity mismatch should not resolve")
    case None    -> ()
  }

  // Unknown member / unknown type resolve to None.
  match resolveOverloadIn(img, layout, th, fqn, "noSuchMethod", i4i4) {
    case Some(_) -> panic("overload: unknown member should be None")
    case None    -> ()
  }
  match resolveOverloadIn(img, layout, th, "No.Such.Type", "addInts", i4i4) {
    case Some(_) -> panic("overload: unknown type should be None")
    case None    -> ()
  }
}

// Phase 3b: overload selection among real BCL overloads.  `System.Math.Max`
// has int/long/float/double overloads; (Int,Int) must bind the int overload
// (Int return) and (Long,Long) the long overload (Long return).
func testOverloadResolveBcl(): Unit {
  match refPackDir() {
    case None -> panic("overload-bcl: reference-assembly pack not found")
    case Some(dir) -> {
      val rt = Path.join(dir, "System.Runtime.dll")
      val i4i4: List[SigType] = newList()
      i4i4.add(prim(0x08))  i4i4.add(prim(0x08))
      match resolveOverload(rt, "System.Math", "Max", i4i4) {
        case None -> panic("overload-bcl: Math.Max(int,int) not resolved")
        case Some(m) -> {
          assertTrue(m.isStatic, "overload-bcl: Math.Max is static")
          match m.returnType {
            case STPrim(e) -> assertEqualInt(e, 0x08, "overload-bcl: Max(int,int) returns Int")
            case _         -> panic("overload-bcl: Max(int,int) return not primitive")
          }
        }
      }
      val i8i8: List[SigType] = newList()
      i8i8.add(prim(0x0A))  i8i8.add(prim(0x0A))
      match resolveOverload(rt, "System.Math", "Max", i8i8) {
        case None -> panic("overload-bcl: Math.Max(long,long) not resolved")
        case Some(m) -> match m.returnType {
          case STPrim(e) -> assertEqualInt(e, 0x0A, "overload-bcl: Max(long,long) returns Long")
          case _         -> panic("overload-bcl: Max(long,long) return not primitive")
        }
      }
    }
  }
}

// resolveExtern composes discovery + overload resolution: given a prebuilt
// type→assembly index it finds the owning assembly and resolves the overload.
func testResolveExtern(): Unit {
  match refPackDir() {
    case None -> panic("resolveExtern: reference-assembly pack not found")
    case Some(dir) -> {
      val rt = Path.join(dir, "System.Runtime.dll")
      val one: List[String] = newList()
      one.add(rt)
      val typeIndex = buildTypeIndex(one)
      val pathIndex = buildPathIndex(one)
      val i4i4: List[SigType] = newList()
      i4i4.add(prim(0x08))  i4i4.add(prim(0x08))
      match resolveExtern(typeIndex, pathIndex, "System.Math", "Max", i4i4) {
        case None -> panic("resolveExtern: Math.Max(int,int) not resolved")
        case Some(re) -> {
          assertEqual(re.assemblyName, "System.Runtime", "resolveExtern: Math.Max owned by System.Runtime")
          assertTrue(re.sig.isStatic, "resolveExtern: Math.Max is static")
          match re.sig.returnType {
            case STPrim(e) -> assertEqualInt(e, 0x08, "resolveExtern: Max(int,int) returns Int")
            case _         -> panic("resolveExtern: return not primitive")
          }
        }
      }
      // Unknown type → None.
      match resolveExtern(typeIndex, pathIndex, "No.Such.Type", "X", i4i4) {
        case Some(_) -> panic("resolveExtern: unknown type should be None")
        case None    -> ()
      }
      // Assembly found in the index, but the member is absent → None.
      match resolveExtern(typeIndex, pathIndex, "System.Math", "NoSuchMethodXyz", i4i4) {
        case Some(_) -> panic("resolveExtern: absent member should be None")
        case None    -> ()
      }
      // Type known to `typeIndex` but its owning assembly missing from
      // `pathIndex` → the middle None arm in the nested match (between the
      // "no such type" and "no such method" cases).
      val emptyPaths: Map[String, String] = newMap()
      match resolveExtern(typeIndex, emptyPaths, "System.Math", "Max", i4i4) {
        case Some(_) -> panic("resolveExtern: empty pathIndex should be None")
        case None    -> ()
      }
    }
  }
}

// Value-type parameters and returns resolve to FQN-named SigTypes:
// `TimeSpan.FromMinutes(double)` returns a `TimeSpan` value type, and
// `TimeSpan.Compare(TimeSpan, TimeSpan)` accepts value-type arguments described
// by FQN and returns Int.
func testResolveExternValueType(): Unit {
  match refPackDir() {
    case None -> panic("vt: reference-assembly pack not found")
    case Some(dir) -> {
      val rt = Path.join(dir, "System.Runtime.dll")
      val one: List[String] = newList()
      one.add(rt)
      val typeIndex = buildTypeIndex(one)
      val pathIndex = buildPathIndex(one)
      // FromMinutes(double): TimeSpan — value-type return.
      val dargs: List[SigType] = newList()
      dargs.add(prim(0x0D))
      match resolveExtern(typeIndex, pathIndex, "System.TimeSpan", "FromMinutes", dargs) {
        case None -> panic("vt: TimeSpan.FromMinutes not resolved")
        case Some(re) -> {
          assertTrue(re.sig.isStatic, "vt: FromMinutes is static")
          assertEqual(sigNamedFqn(re.sig.returnType), "System.TimeSpan", "vt: FromMinutes returns TimeSpan")
          assertTrue(sigNamedIsValueType(re.sig.returnType), "vt: TimeSpan is a value type")
        }
      }
      // Compare(TimeSpan, TimeSpan): int — value-type params, primitive return.
      val cargs: List[SigType] = newList()
      cargs.add(mkNamedSig("System.TimeSpan", true))
      cargs.add(mkNamedSig("System.TimeSpan", true))
      match resolveExtern(typeIndex, pathIndex, "System.TimeSpan", "Compare", cargs) {
        case None -> panic("vt: TimeSpan.Compare not resolved")
        case Some(re) -> assertEqualInt(sigPrimByte(re.sig.returnType), 0x08, "vt: Compare returns Int")
      }
      // GetType(string): Type — class (reference) return, named by FQN with the
      // value-type flag false.
      val sargs: List[SigType] = newList()
      sargs.add(prim(0x0E))
      match resolveExtern(typeIndex, pathIndex, "System.Type", "GetType", sargs) {
        case None -> panic("vt: Type.GetType not resolved")
        case Some(re) -> {
          assertEqual(sigNamedFqn(re.sig.returnType), "System.Type", "vt: GetType returns Type")
          assertTrue(not sigNamedIsValueType(re.sig.returnType), "vt: Type is a reference type")
        }
      }
    }
  }
}

// ── Driver ───────────────────────────────────────────────────────────────────

func main(): Int {
  testPeContainer()
  testRvaMapping()
  testMetadataRoot()
  testTablesHeader()
  testCompressedUInt()
  testTableRows()
  testMethodSigBlobs()
  testSigDecodeRoundTrip()
  testSigDecodeOnSelf()
  testTypeRefResolution()
  testTypeIndexSelf()
  testRefPackDiscovery()
  testOverloadResolveSelf()
  testOverloadResolveBcl()
  testResolveExtern()
  testResolveExternValueType()
  testScoreSigTypeArrayInvariance()
  println("metadata-reader self-test: ok")
  return 0
}
