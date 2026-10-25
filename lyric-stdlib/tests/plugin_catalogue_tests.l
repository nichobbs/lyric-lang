//! Std.PluginCatalogue tests (D248 Decisions 8-10): catalogue times and
//! versions, a catalogue built and followed from a local directory, installing
//! from it, and every refusal: K0120 (signature), K0121 (expiry), K0122
//! (rollback), K0123 (artifact mismatch), a refused artifact signature, yanked
//! entries, key rotation, entry ids and versions that are not paths, and the
//! zip extraction rules.
@test_module
package Std.PluginCatalogue.Tests

import Std.Core
import Std.Collections
import Std.Ed25519
import Std.Encoding
import Std.Environment
import Std.Errors
import Std.File
import Std.Hash
import Std.PluginCatalogue
import Std.PluginSign
import Std.Plugin
import Std.String
import Std.Testing
import Std.Zip

func seed(hex: in String): slice[Byte] {
  match tryDecodeHex(hex) {
    case Some(b) -> b
    case None -> panic("bad seed")
  }
}

// The catalogue key, its replacement for rotation, and the publisher key.
func catSeed(): slice[Byte] = seed("A1A2A3A4A5A6A7A8A9AAABACADAEAFB0B1B2B3B4B5B6B7B8B9BABBBCBDBEBFC0")

func catSeed2(): slice[Byte] = seed("C1C2C3C4C5C6C7C8C9CACBCCCDCECFD0D1D2D3D4D5D6D7D8D9DADBDCDDDEDFE0")

func pubSeed(): slice[Byte] = seed("0102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F20")

func oneSeed(s: in slice[Byte]): List[slice[Byte]] {
  val xs: List[slice[Byte]] = newList()
  xs.add(s)
  xs
}

func oneFollowed(f: in FollowedCatalogue): List[FollowedCatalogue] {
  val xs: List[FollowedCatalogue] = newList()
  xs.add(f)
  xs
}

// `b` with one more byte, built through a list so the slice has the same
// representation on every backend.
func withTrailingZero(b: in slice[Byte]): slice[Byte] {
  val acc: List[Byte] = newList()
  for x in b {
    acc.add(x)
  }
  acc.add(0u8)
  acc.toArray()
}

func scratch(label: in String): String {
  val base = getVarOrDefault("TMPDIR", "/tmp")
  val dir = base + "/lyric_catalogue_tests_" + label
  val _ = deleteDirRecursive(dir)
  val _ = createDir(dir)
  dir
}

func write(path: in String, text: in String): Unit {
  match writeText(path, text) {
    case Ok(_) -> ()
    case Err(e) -> panic("cannot write " + path + ": " + IOError.message(e))
  }
}

func ok[T](r: in Result[T, CatalogueError], label: in String): T {
  match r {
    case Ok(v) -> v
    case Err(e) -> panic(label + ": " + catalogueErrorMessage(e))
  }
}

func expectCode[T](r: in Result[T, CatalogueError], code: in String, label: in String): Unit {
  match r {
    case Ok(_) -> panic(label + ": expected " + code)
    case Err(e) -> assertEqual(catalogueErrorCode(e), code, label + " (" + catalogueErrorMessage(e) + ")")
  }
}

func manifestJson(version: in String): String {
  "{\"schema\": 1, \"id\": \"acme.tools\", \"version\": \"" + version + "\", \"publisher\": \"acme\", " +
    "\"points\": [{\"point\": \"Acme.Api.Tool\", \"version\": \"1.0\"}], " +
    "\"capabilities\": {\"required\": [], \"optional\": []}, " +
    "\"payloads\": [{\"mode\": \"wasm\", \"module\": \"plugin.wasm\"}]}\n"
}

// A signed artifact directory for acme.tools at `version`, zipped.
func artifactZip(work: in String, version: in String, signer: in slice[Byte]): slice[Byte] {
  val dir = work + "/build-" + version + "/acme.tools-" + version
  val _ = deleteDirRecursive(work + "/build-" + version)
  val _ = createDir(work + "/build-" + version)
  val _ = createDir(dir)
  write(dir + "/plugin.json", manifestJson(version))
  write(dir + "/plugin.wasm", "wasm " + version)
  match signArtifact(dir, signer) {
    case Ok(sig) -> match writePluginSignature(dir, sig) { case Ok(_) -> (); case Err(m) -> panic(m) }
    case Err(ps) -> panic("sign: " + ps[0])
  }
  ok(zipArtifactDir(dir, newList()), "zip")
}

// A catalogue in `<work>/cat` with acme.tools at each version in `versions`.
func buildCatalogue(work: in String, versions: in List[String]): Catalogue {
  val catDir = work + "/cat"
  val _ = createDir(catDir)
  val _ = createDir(catDir + "/artifacts")
  var c = withPublisherKey(
    newCatalogue("acme-editor", ed25519PublicKey(catSeed())),
    "acme",
    ed25519PublicKey(pubSeed())
  )
  for v in versions {
    val zip = artifactZip(work, v, pubSeed())
    val rel = "artifacts/acme.tools-" + v + ".zip"
    match writeBytes(catDir + "/" + rel, zip) {
      case Ok(_) -> ()
      case Err(e) -> panic(IOError.message(e))
    }
    c = withEntry(c, ok(catalogueEntryForZip(c, zip, rel, work + "/scratch-" + v), "entry " + v))
  }
  c
}

func publish(work: in String, c: in Catalogue, current: in slice[Byte], rotate: in Option[slice[Byte]]): Catalogue {
  match signCatalogue(c, current, rotate, 30) {
    case Ok(pair) -> {
      val (json, sig) = pair
      write(work + "/cat/catalogue.json", json)
      write(work + "/cat/catalogue.sig", sig)
      match parseCatalogue(json) {
        case Ok(next) -> next
        case Err(e) -> panic(e)
      }
    }
    case Err(e) -> panic(e)
  }
}

func source(work: in String): CatalogueSource {
  CatalogueSource(location = work + "/cat", pinnedKey = ed25519PublicKey(catSeed()))
}

test "catalogue times round-trip" {
  match parseCatalogueTime("2026-12-01T00:00:00Z") {
    case Some(t) -> assertEqualLong(t, 1796083200i64, "a known time")
    case None -> panic("parse")
  }
  assertEqual(formatCatalogueTime(946684799i64), "1999-12-31T23:59:59Z", "a known time formats")
  assertEqual(formatCatalogueTime(1796083200i64), "2026-12-01T00:00:00Z", "and back")
  assertTrue(parseCatalogueTime("2026-12-01 00:00:00Z").isNone(), "a space instead of T")
  assertTrue(parseCatalogueTime("2026-13-01T00:00:00Z").isNone(), "month 13")
}

test "plugin versions order by semantic version precedence" {
  assertTrue(comparePluginVersions("1.10.0", "1.9.9") > 0, "numeric, not text")
  assertTrue(comparePluginVersions("1.0.0-beta", "1.0.0") < 0, "a prerelease is lower")
  assertTrue(comparePluginVersions("1.0.0-alpha.2", "1.0.0-alpha.10") < 0, "numeric prerelease identifiers")
  assertTrue(comparePluginVersions("1.0.0+build.5", "1.0.0") == 0, "build metadata is ignored")
}

test "a followed catalogue installs the newest version that is not yanked" {
  val work = scratch("install")
  val versions: List[String] = newList()
  versions.add("1.0.0")
  versions.add("1.2.0")
  versions.add("1.1.0")
  var c = buildCatalogue(work, versions)
  c = match withYanked(c, "acme.tools", "1.2.0") { case Some(y) -> y; case None -> panic("yank") }
  val _ = publish(work, c, catSeed(), None)
  val followed = ok(updateCatalogue(source(work), work + "/state"), "update")
  assertTrue(not followed.stale, "fresh")
  val plugins = work + "/plugins"
  val _ = ok(installPlugin(followed, "acme.tools", Some(value = "1.0.0"), plugins), "install 1.0.0")
  val installed = ok(installPlugin(followed, "acme.tools", None, plugins), "install newest")
  assertTrue(installed.endsWith("acme.tools-1.1.0"), "1.1.0 is the newest not yanked: " + installed)
  assertTrue(not dirExists(plugins + "/acme.tools-1.0.0"), "the older version was removed")
  match verifyArtifact(installed, catalogueKeys(followed.catalogue), followed.catalogue.revokedKeys) {
    case Ok(signer) -> assertEqual(signer.publisher, "acme", "the installed artifact verifies")
    case Err(p) -> panic(signatureProblemMessage(p))
  }
  expectCode(installPlugin(followed, "acme.tools", Some(value = "1.2.0"), plugins), "", "a yanked version")
  val loaded = ok(loadFollowedCatalogue(source(work), work + "/state"), "load")
  assertEqualLong(loaded.catalogue.serial, 1i64, "the stored copy")
  val trust = catalogueTrust(newList(), oneFollowed(loaded), false)
  assertEqualInt(trust.keys.count, 1, "the catalogue's publisher key")
}

test "K0120: a catalogue not signed by the current key" {
  val work = scratch("k0120")
  val versions: List[String] = newList()
  versions.add("1.0.0")
  val c = buildCatalogue(work, versions)
  val json = catalogueToJson(c)
  write(work + "/cat/catalogue.json", json)
  val signers: List[slice[Byte]] = newList()
  signers.add(pubSeed())
  write(work + "/cat/catalogue.sig", signCatalogueBytes(encodeUtf8(json), signers))
  expectCode(updateCatalogue(source(work), work + "/state"), "K0120", "signed by another key")
}

test "K0121 and K0122: expiry and rollback" {
  val work = scratch("k0121")
  val versions: List[String] = newList()
  versions.add("1.0.0")
  val c = buildCatalogue(work, versions)
  val first = publish(work, c, catSeed(), None)
  val firstJson = catalogueToJson(first)
  val firstSig = signCatalogueBytes(encodeUtf8(firstJson), oneSeed(catSeed()))
  val _ = ok(updateCatalogue(source(work), work + "/state"), "first")
  val second = publish(work, first, catSeed(), None)
  val _ = ok(updateCatalogue(source(work), work + "/state"), "second")
  assertEqualLong(second.serial, 2i64, "two publishes")
  // Serving the first catalogue again is a rollback.
  write(work + "/cat/catalogue.json", firstJson)
  write(work + "/cat/catalogue.sig", firstSig)
  expectCode(updateCatalogue(source(work), work + "/state"), "K0122", "a lower serial")
  // The same serial with other contents.
  val other = Catalogue(
    name = "renamed",
    serial = second.serial,
    expires = second.expires,
    catalogueKey = second.catalogueKey,
    publishers = second.publishers,
    revokedKeys = second.revokedKeys,
    plugins = second.plugins
  )
  val otherJson = catalogueToJson(other)
  write(work + "/cat/catalogue.json", otherJson)
  write(work + "/cat/catalogue.sig", signCatalogueBytes(encodeUtf8(otherJson), oneSeed(catSeed())))
  expectCode(updateCatalogue(source(work), work + "/state"), "K0122", "the same serial with other contents")
  // An expired catalogue.
  val expired = Catalogue(
    name = second.name,
    serial = 10i64,
    expires = "1999-12-31T23:59:59Z",
    catalogueKey = second.catalogueKey,
    publishers = second.publishers,
    revokedKeys = second.revokedKeys,
    plugins = second.plugins
  )
  val expiredJson = catalogueToJson(expired)
  write(work + "/cat/catalogue.json", expiredJson)
  write(work + "/cat/catalogue.sig", signCatalogueBytes(encodeUtf8(expiredJson), oneSeed(catSeed())))
  expectCode(updateCatalogue(source(work), work + "/state"), "K0121", "an expired catalogue")
  val stillLoaded = ok(loadFollowedCatalogue(source(work), work + "/state"), "the last verified copy")
  assertEqualLong(stillLoaded.catalogue.serial, 2i64, "an expired update leaves the stored copy")
}

test "a rotation needs both signatures, and the new key is then current" {
  val work = scratch("rotation")
  val versions: List[String] = newList()
  versions.add("1.0.0")
  val c = buildCatalogue(work, versions)
  val first = publish(work, c, catSeed(), None)
  val _ = ok(updateCatalogue(source(work), work + "/state"), "first")
  // A catalogue naming a new key but signed only by the old one is refused.
  val half = Catalogue(
    name = first.name,
    serial = 5i64,
    expires = first.expires,
    catalogueKey = ed25519PublicKey(catSeed2()),
    publishers = first.publishers,
    revokedKeys = first.revokedKeys,
    plugins = first.plugins
  )
  val halfJson = catalogueToJson(half)
  write(work + "/cat/catalogue.json", halfJson)
  write(work + "/cat/catalogue.sig", signCatalogueBytes(encodeUtf8(halfJson), oneSeed(catSeed())))
  expectCode(updateCatalogue(source(work), work + "/state"), "K0120", "a rotation signed by one key")
  val rotated = publish(work, first, catSeed(), Some(value = catSeed2()))
  val _ = ok(updateCatalogue(source(work), work + "/state"), "the rotation")
  // Now only the new key is current.
  val next = publish(work, rotated, catSeed2(), None)
  val _ = ok(updateCatalogue(source(work), work + "/state"), "signed by the new key")
  val stale = Catalogue(
    name = next.name,
    serial = next.serial + 1i64,
    expires = next.expires,
    catalogueKey = ed25519PublicKey(catSeed()),
    publishers = next.publishers,
    revokedKeys = next.revokedKeys,
    plugins = next.plugins
  )
  val staleJson = catalogueToJson(stale)
  write(work + "/cat/catalogue.json", staleJson)
  write(work + "/cat/catalogue.sig", signCatalogueBytes(encodeUtf8(staleJson), oneSeed(catSeed())))
  expectCode(updateCatalogue(source(work), work + "/state"), "K0120", "the old key alone after a rotation")
}

test "K0123 and refused artifacts" {
  val work = scratch("k0123")
  val versions: List[String] = newList()
  versions.add("1.0.0")
  val c = buildCatalogue(work, versions)
  val _ = publish(work, c, catSeed(), None)
  val followed = ok(updateCatalogue(source(work), work + "/state"), "update")
  // A changed zip no longer matches its sha256.
  val zipPath = work + "/cat/artifacts/acme.tools-1.0.0.zip"
  val good = match readBytes(zipPath) { case Ok(b) -> b; case Err(e) -> panic(IOError.message(e)) }
  val _ = writeBytes(zipPath, withTrailingZero(good))
  expectCode(installPlugin(followed, "acme.tools", None, work + "/plugins"), "K0123", "a changed zip")
  assertTrue(not dirExists(work + "/plugins/acme.tools-1.0.0"), "nothing was installed")
  // A zip signed by a key the catalogue does not list.
  val rogue = artifactZip(work, "1.0.0", catSeed2())
  val _ = writeBytes(zipPath, rogue)
  val entry = CatalogueEntry(
    id = "acme.tools",
    version = "1.0.0",
    publisher = "acme",
    points = newList(),
    url = "artifacts/acme.tools-1.0.0.zip",
    sha256 = encodeHex(sha256Digest(rogue)).toLower(),
    sigSha256 = followed.catalogue.plugins[0].sigSha256,
    yanked = false
  )
  val _ = publish(work, withEntry(followed.catalogue, entry), catSeed(), None)
  val again = ok(updateCatalogue(source(work), work + "/state"), "update with the rogue entry")
  expectCode(
    installPlugin(again, "acme.tools", None, work + "/plugins"),
    "K0106",
    "an artifact signed by an unlisted key"
  )
}

test "the extraction rules refuse a hostile zip" {
  val work = scratch("extract")
  val files: List[ZipFile] = newList()
  files.add(ZipFile(name = "acme.tools-1.0.0/plugin.json", data = encodeUtf8("{}")))
  files.add(ZipFile(name = "elsewhere/evil.txt", data = encodeUtf8("x")))
  expectCode(
    extractArtifactZip(writeZip(files), "acme.tools-1.0.0", work + "/a"),
    "",
    "an entry outside the top directory"
  )
  val dots: List[ZipFile] = newList()
  dots.add(ZipFile(name = "acme.tools-1.0.0/../evil.txt", data = encodeUtf8("x")))
  expectCode(extractArtifactZip(writeZip(dots), "acme.tools-1.0.0", work + "/b"), "", "a '..' segment")
  val cases: List[ZipFile] = newList()
  cases.add(ZipFile(name = "acme.tools-1.0.0/Readme", data = encodeUtf8("1")))
  cases.add(ZipFile(name = "acme.tools-1.0.0/README", data = encodeUtf8("2")))
  expectCode(extractArtifactZip(writeZip(cases), "acme.tools-1.0.0", work + "/c"), "", "names differing only in case")
  val fine: List[ZipFile] = newList()
  fine.add(ZipFile(name = "acme.tools-1.0.0/plugin.json", data = encodeUtf8("{}")))
  fine.add(ZipFile(name = "acme.tools-1.0.0/bin/run", data = encodeUtf8("#!/bin/sh\n"), executable = true))
  val _ = ok(extractArtifactZip(writeZip(fine), "acme.tools-1.0.0", work + "/d"), "a well-formed zip")
  assertTrue(fileExists(work + "/d/bin/run"), "nested files are extracted")
  assertTrue(dirExists(work + "/d") and not dirExists(work + "/a"), "a refused zip writes nothing")
}

test "an entry id or version that is not a plugin id or version is refused" {
  val work = scratch("identity")
  val versions: List[String] = newList()
  versions.add("1.0.0")
  val c = buildCatalogue(work, versions)
  val good = c.plugins[0]
  val bad: List[CatalogueEntry] = newList()
  bad.add(
    CatalogueEntry(
      id = "..",
      version = good.version,
      publisher = good.publisher,
      points = good.points,
      url = good.url,
      sha256 = good.sha256,
      sigSha256 = good.sigSha256,
      yanked = false
    )
  )
  bad.add(
    CatalogueEntry(
      id = good.id,
      version = "1.0.0/../../outside",
      publisher = good.publisher,
      points = good.points,
      url = good.url,
      sha256 = good.sha256,
      sigSha256 = good.sigSha256,
      yanked = false
    )
  )
  for entry in bad {
    val one: List[CatalogueEntry] = newList()
    one.add(entry)
    val hostile = Catalogue(
      name = c.name,
      serial = 1i64,
      expires = "2999-01-01T00:00:00Z",
      catalogueKey = c.catalogueKey,
      publishers = c.publishers,
      revokedKeys = c.revokedKeys,
      plugins = one
    )
    match parseCatalogue(catalogueToJson(hostile)) {
      case Ok(_) -> panic("parseCatalogue accepted " + entry.id + " " + entry.version)
      case Err(_) -> ()
    }
    // A catalogue built in code is checked again before install.
    val followed = FollowedCatalogue(catalogue = hostile, location = work + "/cat", stale = false)
    expectCode(installPlugin(followed, entry.id, Some(value = entry.version), work + "/plugins"), "", "install")
  }
  assertTrue(not dirExists(work + "/outside"), "nothing was written outside the plugins directory")
}
