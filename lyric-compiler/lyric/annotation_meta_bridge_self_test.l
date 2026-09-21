//! annotation_meta_bridge_self_test.l — end-to-end regression coverage for
//! the `Lyric.AnnotationMeta` resource embedding added to `Msil.Bridge` /
//! `Jvm.Bridge` (#6866 PR 1, D-progress-941).
//!
//! `annotation_meta_emit_self_test.l` only covers the pure JSON collection/
//! serialization logic (`collectAnnotatedFields`/`emitAnnotationMetaJson`)
//! against a parsed `SourceFile` — it never compiles anything, so the actual
//! new codegen (`embedLyricAnnotationMeta`'s manual `ManifestResource`
//! offset/byte wiring on MSIL, `annotationMetaZipEntry`'s JAR entry
//! accumulation on JVM) had zero coverage reading the resource back from a
//! real compiled binary. This exercises the WRITER side end to end on both
//! targets: compile a small `config { }` fixture with an annotated field,
//! then read the embedded `Lyric.AnnotationMeta`[`.<Pkg>`] resource back out
//! of the produced binary via the same pure-byte readers
//! `Lyric.ContractMeta` uses for `Lyric.Contract` (`Msil.MetadataReader`/
//! `Jvm.ZipReader`), mirroring `msil_project_bridge_self_test.l`'s #6390
//! resource-embedding regression test.
//!
//! Run in CI via:
//!   lyric test lyric-compiler/lyric/annotation_meta_bridge_self_test.l
@test_module
package Lyric.AnnotationMetaBridgeSelfTest

import Std.Core
import Std.Collections
import Std.Errors
import Std.File as File
import Std.String as Str
import Std.Path as Path
import Std.Testing
import Std.Uuid
import Std.Environment as Environment
import Std.Encoding as Encoding
import Msil.Bridge
import Msil.MetadataReader as Mdr
import Jvm.Bridge
import Jvm.ZipReader as JvmZip

func tempBase(): String {
  Environment.getVarOrDefault("TMPDIR", Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp")))
}

func freshTempDir(label: in String): String {
  val root = Path.join(tempBase(), "lyric-annometa-bridge-" + label + "-" + uuidToString(newUuid()))
  match File.createDir(root) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot create temp dir " + root + ": " + IOError.message(e))
  }
  root
}

func cleanup(dir: in String): Unit {
  match File.deleteDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(_) -> ()
  }
}

// A literal default (not a required field) so this never needs to actually
// RUN the compiled binary or set an env var — the test only compiles and
// reads the embedded resource back, never executes `main`.
func fixtureSource(pkgName: in String): String {
  "package " + pkgName + "\n\n" + "config Db {\n" + "  @secretsManager(key = \"prod/db/password\")\n" +
    "  password: String = \"unused\"\n" +
    "}\n"
}

func intsToByteSlice(xs: in List[Int]): slice[Byte] {
  val bs: List[Byte] = newList()
  var i = 0
  while i < xs.count {
    bs.add(xs[i].toByte())
    i = i + 1
  }
  bs.toArray()
}

test "MSIL: single-package compile embeds Lyric.AnnotationMeta, readable back with the annotated field" {
  val dir = freshTempDir("msil")
  defer {
    cleanup(dir)
  }
  val dllPath = Path.join(dir, "AnnoMetaBridgeRepro.dll")
  val noStdlibSrcs: List[String] = newList()
  val ok = Msil.Bridge.compileToMsil(fixtureSource("AnnoMetaBridgeRepro"), dllPath, noStdlibSrcs)
  assertTrue(ok, "compile: fixture config-block package compiles to a DLL")

  match Mdr.openResourceImage(dllPath) {
    case None -> assertTrue(false, "openResourceImage failed to parse the compiled DLL")
    case Some(ri) -> {
      match Mdr.tryReadResourceIn(ri, "Lyric.AnnotationMeta") {
        case None -> assertTrue(false, "no embedded Lyric.AnnotationMeta resource found")
        case Some(bytes) -> {
          match Encoding.tryDecodeUtf8(bytes) {
            case None -> assertTrue(false, "Lyric.AnnotationMeta resource is not valid UTF-8")
            case Some(json) -> {
              assertTrue(Str.contains(json, "\"config\":\"Db\""), "resource JSON names the config block")
              assertTrue(Str.contains(json, "\"field\":\"password\""), "resource JSON names the annotated field")
              assertTrue(Str.contains(json, "\"annotation\":\"secretsManager\""), "resource JSON names the annotation")
              assertTrue(Str.contains(json, "\"prod/db/password\""), "resource JSON carries the arg value")
            }
          }
        }
      }
    }
  }
}

test "JVM: single-package compile embeds Lyric.AnnotationMeta.<Pkg>, readable back with the annotated field" {
  val dir = freshTempDir("jvm")
  defer {
    cleanup(dir)
  }
  val jarPath = Path.join(dir, "AnnoMetaBridgeRepro.jar")
  val noStdlibSrcs: List[String] = newList()
  val ok = Jvm.Bridge.compileToJarBundled(
    fixtureSource("AnnoMetaBridgeRepro"),
    jarPath,
    "AnnoMetaBridgeRepro",
    noStdlibSrcs,
    "0.1.0"
  )
  assertTrue(ok, "compile: fixture config-block package compiles to a JAR")
  assertTrue(File.fileExists(jarPath), "compile: JAR file exists")

  val bytes = File.readBytesOrPanic(jarPath)
  val entries = JvmZip.readZipEntries(bytes)
  var found: Option[String] = None
  var i = 0
  while i < entries.count {
    val e = entries[i]
    if e.name == "Lyric.AnnotationMeta.AnnoMetaBridgeRepro" {
      match Encoding.tryDecodeUtf8(intsToByteSlice(JvmZip.extractEntry(bytes, e))) {
        case Some(json) -> {
          found = Some(value = json)
        }
        case None -> ()
      }
    }
    i = i + 1
  }
  match found {
    case None -> assertTrue(false, "no Lyric.AnnotationMeta.AnnoMetaBridgeRepro JAR entry found")
    case Some(json) -> {
      assertTrue(Str.contains(json, "\"config\":\"Db\""), "resource JSON names the config block")
      assertTrue(Str.contains(json, "\"field\":\"password\""), "resource JSON names the annotated field")
      assertTrue(Str.contains(json, "\"annotation\":\"secretsManager\""), "resource JSON names the annotation")
      assertTrue(Str.contains(json, "\"prod/db/password\""), "resource JSON carries the arg value")
    }
  }
}
