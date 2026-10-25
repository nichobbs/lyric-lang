//! Std.PluginSign tests (D248): key formats, the canonical listing and its
//! rules, plugin.sig round trips, signing and every verification outcome
//! (K0105-K0110). Each test builds its own artifact under $TMPDIR.
@test_module
package Std.PluginSign.Tests

import Std.Core
import Std.Collections
import Std.Encoding
import Std.Ed25519
import Std.Environment
import Std.Errors
import Std.File
import Std.PluginSign
import Std.Process
import Std.String
import Std.Testing

func seedA(): slice[Byte] {
  match tryDecodeHex("000102030405060708090A0B0C0D0E0F101112131415161718191A1B1C1D1E1F") {
    case Some(b) -> b
    case None -> panic("bad seed")
  }
}

func seedB(): slice[Byte] {
  match tryDecodeHex("1F1E1D1C1B1A191817161514131211100F0E0D0C0B0A09080706050403020100") {
    case Some(b) -> b
    case None -> panic("bad seed")
  }
}

func scratch(label: in String): String {
  val base = Environment.getVarOrDefault("TMPDIR", "/tmp")
  val dir = base + "/lyric_plugin_sign_tests_" + label
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

func manifestJson(id: in String, version: in String, publisher: in String): String {
  "{\"schema\": 1, \"id\": \"" + id + "\", \"version\": \"" + version + "\", \"publisher\": \"" + publisher +
    "\", \"points\": [], \"capabilities\": {\"required\": [], \"optional\": []}, \"payloads\": []}\n"
}

// An artifact with a manifest, a payload and a nested file.
func artifact(label: in String): String {
  val dir = scratch(label)
  write(dir + "/plugin.json", manifestJson("acme.tools", "1.2.3", "acme"))
  write(dir + "/plugin.wasm", "wasm bytes")
  val _ = createDir(dir + "/lib")
  write(dir + "/lib/helper.txt", "helper")
  dir
}

func signWith(dir: in String, seed: in slice[Byte]): Unit {
  match signArtifact(dir, seed) {
    case Ok(sig) -> {
      match writePluginSignature(dir, sig) {
        case Ok(_) -> ()
        case Err(msg) -> panic(msg)
      }
    }
    case Err(problems) -> panic("signing failed: " + joinList("; ", problems))
  }
}

func trusted(publisher: in String, seed: in slice[Byte]): List[TrustedKey] {
  val keys: List[TrustedKey] = newList()
  keys.add(TrustedKey(publisher = publisher, publicKey = ed25519PublicKey(seed)))
  keys
}

func noRevocations(): List[String] {
  val none: List[String] = newList()
  none
}

func expectProblem(r: in Result[PluginSigner, SignatureProblem], code: in String, label: in String): Unit {
  match r {
    case Ok(_) -> panic(label + ": expected " + code + " but the artifact verified")
    case Err(p) -> assertEqual(signatureProblemCode(p), code, label + " (" + signatureProblemMessage(p) + ")")
  }
}

func canLink(): Bool = not isWindows()

func zeros64(): String {
  var s = ""
  var i = 0
  while i < 64 {
    s = s + "0"
    i = i + 1
  }
  s
}

test "public and secret keys round-trip through their text forms" {
  val pk = ed25519PublicKey(seedA())
  val text = formatPublicKey(pk)
  assertTrue(text.startsWith("lyric-ed25519:"), "public key prefix")
  match parsePublicKey(text + "\n") {
    case Ok(back) -> assertEqual(encodeHex(back), encodeHex(pk), "public key round trip")
    case Err(msg) -> panic(msg)
  }
  match parseSecretKey(formatSecretKey(seedA())) {
    case Ok(back) -> assertEqual(encodeHex(back), encodeHex(seedA()), "secret key round trip")
    case Err(msg) -> panic(msg)
  }
  assertTrue(parsePublicKey(formatSecretKey(seedA())).isErr(), "a secret key is not a public key")
  assertTrue(parsePublicKey("lyric-ed25519:AAAA").isErr(), "a 3-byte key is refused")
  assertTrue(parseSecretKey("lyric-ed25519-secret:!!").isErr(), "bad base64 is refused")
  assertEqualInt(publicKeyId(pk).length, 32, "a key id is 32 hex digits")
  assertTrue(publicKeyId(pk) != publicKeyId(ed25519PublicKey(seedB())), "different keys, different ids")
}

test "listing path rules (D248 Decision 5, D263)" {
  assertTrue(listingPathProblem("lib/helper.txt").isNone(), "a nested path is fine")
  assertTrue(listingPathProblem("a\nb").isSome(), "a newline is refused")
  assertTrue(listingPathProblem("ab").isSome(), "DEL is refused")
  assertTrue(listingPathProblem("ab").isSome(), "a C1 control is refused")
  assertTrue(listingPathProblem("a//b").isSome(), "an empty segment is refused")
  assertTrue(listingPathProblem("./a").isSome(), "a '.' segment is refused")
  assertTrue(listingPathProblem("a/../b").isSome(), "a '..' segment is refused")
  assertTrue(listingPathProblem("a\\b").isSome(), "a backslash is refused")
  assertTrue(listingPathProblem("é").isSome(), "a combining mark is refused")
  assertTrue(listingPathProblem("é.txt").isSome(), "a non-ASCII letter is refused")
  assertTrue(listingPathProblem("my plugin-1.0_x+y@z~.dll").isNone(), "printable ASCII with spaces is fine")
}

test "the listing is sorted by UTF-8 bytes, skips plugin.sig and empty directories" {
  val dir = scratch("order")
  write(dir + "/b.txt", "b")
  write(dir + "/Z.txt", "z")
  write(dir + "/a.txt", "a")
  write(dir + "/_.txt", "u")
  write(dir + "/plugin.sig", "ignored")
  val _ = createDir(dir + "/empty")
  val _ = createDir(dir + "/sub")
  write(dir + "/sub/x.txt", "x")
  match listingPaths(dir) {
    case Ok(paths) -> assertEqual(joinList(",", paths), "Z.txt,_.txt,a.txt,b.txt,sub/x.txt", "listing order")
    case Err(problems) -> panic(joinList("; ", problems))
  }
  val _ = deleteDirRecursive(dir)
}

test "paths differing only in case fail the listing" {
  val dir = scratch("case")
  write(dir + "/Readme.txt", "1")
  write(dir + "/README.txt", "2")
  // On a case-insensitive file system the second write replaced the first.
  match listingPaths(dir) {
    case Ok(paths) -> assertEqualInt(paths.count, 1, "one file on a case-insensitive file system")
    case Err(problems) -> assertTrue(joinList("; ", problems).contains("only in case"), "the collision is reported")
  }
  val _ = deleteDirRecursive(dir)
}

test "a symbolic link fails the listing" {
  if canLink() {
    val dir = artifact("link")
    val args: List[String] = newList()
    args.add("-s")
    args.add(dir + "/plugin.wasm")
    args.add(dir + "/alias.wasm")
    match run("ln", args) {
      case Ok(code) -> assertEqualInt(code, 0, "ln -s")
      case Err(e) -> panic(IOError.message(e))
    }
    match listingPaths(dir) {
      case Ok(_) -> panic("a link was listed")
      case Err(problems) -> assertTrue(joinList("; ", problems).contains("symbolic link"), "the link is reported")
    }
    val _ = deleteDirRecursive(dir)
  }
}

test "a signed artifact verifies, and plugin.sig round-trips" {
  val dir = artifact("ok")
  signWith(dir, seedA())
  match verifyArtifact(dir, trusted("acme", seedA()), noRevocations()) {
    case Ok(signer) -> {
      assertEqual(signer.publisher, "acme", "publisher")
      assertEqual(signer.keyId, publicKeyId(ed25519PublicKey(seedA())), "key id")
    }
    case Err(p) -> panic(signatureProblemMessage(p))
  }
  match readPluginSignature(dir) {
    case Ok(sig) -> {
      assertEqualInt(sig.files.count, 3, "three files are listed")
      assertEqual(sig.files[0].path, "lib/helper.txt", "first path")
      match parsePluginSignature(pluginSignatureToJson(sig)) {
        case Ok(again) -> assertEqual(encodeHex(again.signature), encodeHex(sig.signature), "JSON round trip")
        case Err(msg) -> panic(msg)
      }
    }
    case Err(p) -> panic(signatureProblemMessage(p))
  }
  assertEqualInt(checkSignatureStructure(dir).count, 0, "check finds nothing")
  // Re-signing replaces plugin.sig rather than listing it.
  signWith(dir, seedA())
  assertTrue(verifyArtifact(dir, trusted("acme", seedA()), noRevocations()).isOk(), "re-signed artifact verifies")
  val _ = deleteDirRecursive(dir)
}

test "K0105: a missing or malformed plugin.sig" {
  val dir = artifact("missing")
  expectProblem(verifyArtifact(dir, trusted("acme", seedA()), noRevocations()), "K0105", "no plugin.sig")
  write(dir + "/plugin.sig", "{not json")
  expectProblem(verifyArtifact(dir, trusted("acme", seedA()), noRevocations()), "K0105", "invalid JSON")
  assertTrue(checkSignatureStructure(dir).count > 0, "check reports the malformed file")
  val _ = deleteDirRecursive(dir)
}

test "K0106 and K0110: an untrusted or revoked key" {
  val dir = artifact("keys")
  signWith(dir, seedA())
  expectProblem(verifyArtifact(dir, trusted("acme", seedB()), noRevocations()), "K0106", "another key")
  val revoked: List[String] = newList()
  revoked.add(publicKeyId(ed25519PublicKey(seedA())))
  expectProblem(verifyArtifact(dir, trusted("acme", seedA()), revoked), "K0110", "revoked key")
  val _ = deleteDirRecursive(dir)
}

test "K0107: a signature that does not verify" {
  val dir = artifact("badsig")
  signWith(dir, seedA())
  match readPluginSignature(dir) {
    case Ok(sig) -> {
      val bytes: List[Byte] = newList()
      var i = 0
      while i < 64 {
        bytes.add(if i == 0 { (sig.signature[0].toInt().xor(1)).toByte() } else { sig.signature[i] })
        i = i + 1
      }
      val forged = PluginSignature(
        schema = sig.schema,
        sigType = sig.sigType,
        keyId = sig.keyId,
        id = sig.id,
        version = sig.version,
        files = sig.files,
        signature = bytes.toArray()
      )
      match writePluginSignature(dir, forged) {
        case Ok(_) -> ()
        case Err(msg) -> panic(msg)
      }
    }
    case Err(p) -> panic(signatureProblemMessage(p))
  }
  expectProblem(verifyArtifact(dir, trusted("acme", seedA()), noRevocations()), "K0107", "flipped bit")
  val _ = deleteDirRecursive(dir)
}

test "K0108: changed, added and removed files" {
  val dir = artifact("files")
  signWith(dir, seedA())
  write(dir + "/plugin.wasm", "other bytes")
  expectProblem(verifyArtifact(dir, trusted("acme", seedA()), noRevocations()), "K0108", "a changed payload")
  write(dir + "/plugin.wasm", "wasm bytes")
  write(dir + "/extra.dll", "planted")
  expectProblem(verifyArtifact(dir, trusted("acme", seedA()), noRevocations()), "K0108", "an added file")
  assertTrue(checkSignatureStructure(dir).count > 0, "check reports the added file")
  val _ = deleteFile(dir + "/extra.dll")
  val _ = deleteFile(dir + "/lib/helper.txt")
  expectProblem(verifyArtifact(dir, trusted("acme", seedA()), noRevocations()), "K0108", "a removed file")
  val _ = deleteDirRecursive(dir)
}

test "K0109: an identity that does not match" {
  val dir = artifact("identity")
  signWith(dir, seedA())
  expectProblem(
    verifyArtifact(dir, trusted("other", seedA()), noRevocations()),
    "K0109",
    "the key is for another publisher"
  )
  // A manifest edited after signing changes its digest too; re-signing it
  // under a key trusted for another publisher is the identity case proper.
  write(dir + "/plugin.json", manifestJson("acme.tools", "1.2.3", "mallory"))
  signWith(dir, seedA())
  expectProblem(
    verifyArtifact(dir, trusted("acme", seedA()), noRevocations()),
    "K0109",
    "the manifest names another publisher"
  )
  val _ = deleteDirRecursive(dir)
}

test "parsePluginSignature refuses bad fields" {
  val good = "{\"schema\": 1, \"type\": \"ed25519\", \"keyId\": \"00112233445566778899aabbccddeeff\", " +
    "\"id\": \"a.b\", \"version\": \"1.0.0\", \"files\": [], \"signature\": \"" +
    encodeBase64(seedA().concat(seedA())) +
    "\"}"
  assertTrue(parsePluginSignature(good).isOk(), "a well-formed file parses")
  assertTrue(parsePluginSignature(good.replace("\"ed25519\"", "\"sigstore\"")).isErr(), "an unknown type")
  assertTrue(parsePluginSignature(good.replace("\"schema\": 1", "\"schema\": 2")).isErr(), "an unknown schema")
  assertTrue(parsePluginSignature(good.replace("00112233", "0011223G")).isErr(), "a bad key id")
  val unordered = good.replace(
    "\"files\": []",
    "\"files\": [{\"path\": \"b\", \"sha256\": \"" + zeros64() + "\"}, {\"path\": \"a\", \"sha256\": \"" +
      zeros64() +
      "\"}]"
  )
  assertTrue(parsePluginSignature(unordered).isErr(), "files out of order")
  val control = good.replace("\"files\": []", "\"files\": [{\"path\": \"a\\nb\", \"sha256\": \"" + zeros64() + "\"}]")
  assertTrue(parsePluginSignature(control).isErr(), "a path with a newline")
}
