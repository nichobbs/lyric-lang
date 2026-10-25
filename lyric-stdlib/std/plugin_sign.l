//! std/plugin_sign.l - Plugin artifact signatures (docs/69 §12, D248).
//!
//! An artifact directory carries `plugin.sig`: an Ed25519 signature by the
//! publisher's key over the artifact's id and version and a SHA-256 of every
//! file in the directory, in a canonical listing. This module builds and
//! checks the listing, reads and writes `plugin.sig`, formats keys, signs an
//! artifact, and verifies one against a set of trusted keys. `Std.Plugin`
//! verifies every artifact through `verifyArtifact` before it reads the
//! manifest's points; `lyric plugin sign`, `verify` and `check` use the rest.
//!
//! The listing (D248 Decision 5, narrowed by D263) is every regular file under
//! the artifact directory except `plugin.sig`, as `/`-separated relative paths
//! of printable ASCII other than `\` with no empty, `.` or `..` segment,
//! sorted by their bytes. A symbolic link or any other entry that is neither a
//! regular file nor a directory fails the listing, as do two paths that differ
//! only in ASCII case. Empty directories are ignored.
//!
//! The signed message (D248 Decision 4) is the UTF-8 text of the lines
//! `lyric-plugin-sig-v1`, the signature type, the id, the version and the key
//! id, then `<sha256> <path>` per listed file, each line ending in `\n`.
@runtime_checked
@io
package Std.PluginSign

import Std.Core
import Std.Collections
import Std.Ed25519
import Std.Encoding
import Std.Errors
import Std.File
import Std.Hash
import Std.JsonValue
import Std.Path as Path
import Std.Sort
import Std.String

/// The signature file's name inside an artifact directory.
@experimental
pub val signatureFileName: String = "plugin.sig"

/// The only signature type this version writes and verifies.
@experimental
pub val ed25519SignatureType: String = "ed25519"

val signatureMessageHeader: String = "lyric-plugin-sig-v1"

val publicKeyPrefix: String = "lyric-ed25519:"

val secretKeyPrefix: String = "lyric-ed25519-secret:"

// Nesting deeper than this is refused rather than walked (defence against a
// link type the entry-kind probe cannot see, such as a Windows junction).
val maxListingDepth: Int = 64

/// One listed file: its relative path and the lowercase hex SHA-256 of its
/// contents.
@experimental
pub record SignedFile {
  path: String
  sha256: String
}

/// The contents of `plugin.sig`.
@experimental
pub record PluginSignature {
  schema: Int
  sigType: String
  keyId: String
  id: String
  version: String
  files: List[SignedFile]
  signature: slice[Byte]
}

/// A publisher key the host trusts: the publisher name a plugin signed by it
/// must declare, and the 32-byte Ed25519 public key.
@experimental
pub record TrustedKey {
  publisher: String
  publicKey: slice[Byte]
}

/// Who signed a verified artifact.
@experimental
pub record PluginSigner {
  publisher: String
  keyId: String
}

/// Why an artifact's signature was not accepted (load codes K0105-K0110).
@experimental
pub union SignatureProblem {
  /// The artifact has no `plugin.sig` (K0105). A host that allows unsigned
  /// plugins treats only this case as unsigned, never a damaged signature.
  case MissingSignature
  /// A `plugin.sig` that cannot be read or does not parse (K0105).
  case MalformedSignature(reason: String)
  /// The signing key is not among the trusted keys (K0106).
  case UntrustedKey(keyId: String)
  /// The signature does not verify under the key it names (K0107).
  case BadSignature(keyId: String)
  /// The files on disk do not match the signed listing, or a path breaks the
  /// listing rules (K0108).
  case ListingMismatch(details: List[String])
  /// `plugin.json`'s id, version or publisher does not match the signature or
  /// the key (K0109).
  case IdentityMismatch(reason: String)
  /// The signing key is revoked (K0110).
  case RevokedKey(keyId: String)
}

/// The docs/69 load code of a signature problem.
@experimental
pub func signatureProblemCode(p: in SignatureProblem): String {
  match p {
    case MissingSignature -> "K0105"
    case MalformedSignature(_) -> "K0105"
    case UntrustedKey(_) -> "K0106"
    case BadSignature(_) -> "K0107"
    case ListingMismatch(_) -> "K0108"
    case IdentityMismatch(_) -> "K0109"
    case RevokedKey(_) -> "K0110"
  }
}

/// A one-line description of a signature problem.
@experimental
pub func signatureProblemMessage(p: in SignatureProblem): String {
  match p {
    case MissingSignature -> "the artifact has no " + signatureFileName
    case MalformedSignature(reason) -> reason
    case UntrustedKey(keyId) -> "the signing key " + keyId + " is not trusted"
    case BadSignature(keyId) -> "the signature does not verify under key " + keyId
    case ListingMismatch(details) -> {
      var text = "the files do not match the signed listing"
      var i = 0
      while i < details.count {
        text = text + (if i == 0 { ": " } else { "; " }) + details[i]
        i = i + 1
      }
      text
    }
    case IdentityMismatch(reason) -> reason
    case RevokedKey(keyId) -> "the signing key " + keyId + " is revoked"
  }
}

// ---- Keys -------------------------------------------------------------------
func lowerHex(bytes: in slice[Byte]): String {
  encodeHex(bytes).toLower()
}

/// The text form of a public key, `lyric-ed25519:<base64 of 32 bytes>`.
@experimental
pub func formatPublicKey(publicKey: in slice[Byte]): String
  requires: publicKey.length == 32
{
  publicKeyPrefix + encodeBase64(publicKey)
}

/// Parses `lyric-ed25519:<base64>` into the 32 key bytes.
@experimental
pub func parsePublicKey(text: in String): Result[slice[Byte], String] {
  val t = text.trim()
  if not t.startsWith(publicKeyPrefix) {
    return Err(error = "a public key starts with '" + publicKeyPrefix + "'")
  }
  match tryDecodeBase64(t.substring(publicKeyPrefix.length)) {
    case Some(bytes) -> {
      if bytes.length == 32 {
        Ok(value = bytes)
      } else {
        Err(error = "a public key is 32 bytes, not " + bytes.length.toString())
      }
    }
    case None -> Err(error = "the public key is not valid base64")
  }
}

/// The text form of a secret key, `lyric-ed25519-secret:<base64 of the 32-byte seed>`.
@experimental
pub func formatSecretKey(seed: in slice[Byte]): String
  requires: seed.length == 32
{
  secretKeyPrefix + encodeBase64(seed)
}

/// Parses `lyric-ed25519-secret:<base64>` into the 32-byte seed.
@experimental
pub func parseSecretKey(text: in String): Result[slice[Byte], String] {
  val t = text.trim()
  if not t.startsWith(secretKeyPrefix) {
    return Err(error = "a secret key starts with '" + secretKeyPrefix + "'")
  }
  match tryDecodeBase64(t.substring(secretKeyPrefix.length)) {
    case Some(bytes) -> {
      if bytes.length == 32 {
        Ok(value = bytes)
      } else {
        Err(error = "a secret key is 32 bytes, not " + bytes.length.toString())
      }
    }
    case None -> Err(error = "the secret key is not valid base64")
  }
}

/// A key's id: the lowercase hex of the first 16 bytes of the SHA-256 of its
/// 32 bytes. The id is a lookup hint; keys are always compared in full.
@experimental
pub func publicKeyId(publicKey: in slice[Byte]): String
  ensures: result.length == 32
{
  lowerHex(sha256Digest(publicKey).slice(0, 16))
}

// ---- The listing ------------------------------------------------------------
func isControlCode(c: in Int): Bool = c < 32 or (c >= 127 and c < 160)

// A listing path character: printable ASCII other than the backslash.
func isListingChar(c: in Int): Bool = c >= 32 and c <= 126 and c != 92

/// Why a relative listing path breaks the listing rules (D248 Decision 5 as
/// narrowed by D263), if it does: every character must be printable ASCII
/// other than `\`, and no segment may be empty, `.` or `..`.
@experimental
pub func listingPathProblem(path: in String): Option[String] {
  if path.length == 0 {
    return Some(value = "an empty path")
  }
  var i = 0
  while i < path.length {
    if not isListingChar(codeUnitAt(path, i)) {
      return Some(value = "'" + escapePath(path) + "' contains a character other than printable ASCII (or a backslash)")
    }
    i = i + 1
  }
  for segment in split(path, "/") {
    if segment.length == 0 or segment == "." or segment == ".." {
      return Some(value = "'" + path + "' has an empty, '.' or '..' segment")
    }
  }
  None
}

// The path with every character outside printable ASCII written as \u{XXXX},
// so a report never carries a control character or a lookalike.
func escapePath(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = codeUnitAt(s, i)
    if c >= 32 and c <= 126 {
      acc = acc + s.substring(i, 1)
    } else {
      acc = acc + "\\u{" + encodeHex([c.shr(8).toByte(), c.and(255).toByte()]) + "}"
    }
    i = i + 1
  }
  acc
}

func hasString(xs: in List[String], s: in String): Bool {
  for x in xs {
    if x == s {
      return true
    }
  }
  false
}

// ASCII lowercase, for the case-collision check; other characters never reach
// it, since the path rules refuse them first.
func asciiLower(s: in String): String {
  var acc = ""
  var i = 0
  while i < s.length {
    val c = codeUnitAt(s, i)
    acc = acc + (if c >= 65 and c <= 90 { "abcdefghijklmnopqrstuvwxyz".substring(c - 65, 1) } else { s.substring(i, 1) })
    i = i + 1
  }
  acc
}

// Orders two paths by the bytes of their UTF-8 encodings.
func compareUtf8(a: in String, b: in String): Int {
  val x = encodeUtf8(a)
  val y = encodeUtf8(b)
  var i = 0
  while i < x.length and i < y.length {
    val d = x[i].toInt() - y[i].toInt()
    if d != 0 {
      return d
    }
    i = i + 1
  }
  x.length - y.length
}

func walkListing(root: in String, rel: in String, depth: in Int, acc: in List[String], problems: in List[String]): Unit {
  val dir = if rel.length == 0 { root } else { Path.join(root, rel) }
  if depth > maxListingDepth {
    problems.add("'" + rel + "' is nested more than " + maxListingDepth.toString() + " levels deep")
    return
  }
  val entries = match listEntries(dir) {
    case Ok(es) -> es
    case Err(e) -> {
      problems.add("cannot list '" + dir + "': " + ioErrorText(e))
      return
    }
  }
  for entry in entries {
    val name = Path.basename(entry)
    val path = if rel.length == 0 { name } else { rel + "/" + name }
    val kind = entryKind(Path.join(root, path))
    if kind == RegularFile {
      if path != signatureFileName {
        acc.add(path)
      }
    } else if kind == Directory {
      walkListing(root, path, depth + 1, acc, problems)
    } else if kind == SymbolicLink {
      problems.add("'" + escapePath(path) + "' is a symbolic link")
    } else if kind == Other {
      problems.add("'" + escapePath(path) + "' is not a regular file or directory")
    } else {
      problems.add("'" + escapePath(path) + "' disappeared while the directory was listed")
    }
  }
}

func ioErrorText(e: in IOError): String {
  IOError.message(e)
}

/// The sorted relative paths of an artifact directory's listed files, or
/// every reason the directory cannot be listed.
@experimental
pub func listingPaths(dir: in String): Result[List[String], List[String]] {
  val acc: List[String] = newList()
  val problems: List[String] = newList()
  if entryKind(dir) != Directory {
    problems.add("'" + dir + "' is not a directory")
    return Err(error = problems)
  }
  walkListing(dir, "", 0, acc, problems)
  for p in acc {
    match listingPathProblem(p) {
      case Some(reason) -> problems.add(reason)
      case None -> ()
    }
  }
  if problems.count > 0 {
    return Err(error = problems)
  }
  val sorted = sort(acc.toArray(), { a: String, b: String -> compareUtf8(a, b) })
  val seenLower: List[String] = newList()
  for p in sorted {
    val folded = asciiLower(p)
    if hasString(seenLower, folded) {
      problems.add("'" + p + "' differs from another path only in case")
    } else {
      seenLower.add(folded)
    }
  }
  if problems.count > 0 {
    return Err(error = problems)
  }
  val paths: List[String] = newList()
  for p in sorted {
    paths.add(p)
  }
  Ok(value = paths)
}

func fileSha256(path: in String): Result[String, String] {
  match readBytes(path) {
    case Ok(bytes) -> Ok(value = lowerHex(sha256Digest(bytes)))
    case Err(e) -> Err(error = "cannot read '" + path + "': " + ioErrorText(e))
  }
}

/// The canonical listing of an artifact directory with each file's SHA-256,
/// or every reason it cannot be built.
@experimental
pub func artifactListing(dir: in String): Result[List[SignedFile], List[String]] {
  val paths = match listingPaths(dir) { case Ok(ps) -> ps; case Err(problems) -> return Err(error = problems) }
  val files: List[SignedFile] = newList()
  val problems: List[String] = newList()
  for p in paths {
    match fileSha256(Path.join(dir, p)) {
      case Ok(digest) -> files.add(SignedFile(path = p, sha256 = digest))
      case Err(reason) -> problems.add(reason)
    }
  }
  if problems.count > 0 {
    Err(error = problems)
  } else {
    Ok(value = files)
  }
}

// ---- The signed message -----------------------------------------------------
/// The bytes a signature covers (D248 Decision 4).
@experimental
pub func signedMessage(
  sigType: in String,
  id: in String,
  version: in String,
  keyId: in String,
  files: in List[SignedFile],
): slice[Byte] {
  var text = signatureMessageHeader + "\n" + sigType + "\n" + id + "\n" + version + "\n" + keyId + "\n"
  for f in files {
    text = text + f.sha256 + " " + f.path + "\n"
  }
  encodeUtf8(text)
}

// ---- plugin.sig -------------------------------------------------------------
func field(name: in String, value: in JsonValue): JsonField = JsonField(name = name, value = value)

/// The JSON text of a signature, as `plugin.sig` holds it.
@experimental
pub func pluginSignatureToJson(sig: in PluginSignature): String {
  val files: List[JsonValue] = newList()
  for f in sig.files {
    val fs: List[JsonField] = newList()
    fs.add(field("path", JString(value = f.path)))
    fs.add(field("sha256", JString(value = f.sha256)))
    files.add(JObject(fields = fs))
  }
  val top: List[JsonField] = newList()
  top.add(field("schema", JInt(value = sig.schema.toLong())))
  top.add(field("type", JString(value = sig.sigType)))
  top.add(field("keyId", JString(value = sig.keyId)))
  top.add(field("id", JString(value = sig.id)))
  top.add(field("version", JString(value = sig.version)))
  top.add(field("files", JArray(items = files)))
  top.add(field("signature", JString(value = encodeBase64(sig.signature))))
  writeValueIndented(JObject(fields = top), 2) + "\n"
}

func isLowerHex(s: in String, length: in Int): Bool {
  if s.length != length {
    return false
  }
  var i = 0
  while i < s.length {
    val c = codeUnitAt(s, i)
    if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)) {
      return false
    }
    i = i + 1
  }
  true
}

func hasControl(s: in String): Bool {
  var i = 0
  while i < s.length {
    if isControlCode(codeUnitAt(s, i)) {
      return true
    }
    i = i + 1
  }
  false
}

func requireText(v: in JsonValue, key: in String): Result[String, String] {
  match getString(v, key) {
    case Some(s) -> {
      if s.length == 0 {
        Err(error = "plugin.sig: '" + key + "' is empty")
      } else if hasControl(s) {
        Err(error = "plugin.sig: '" + key + "' contains a control character")
      } else {
        Ok(value = s)
      }
    }
    case None -> Err(error = "plugin.sig: '" + key + "' is missing or not a string")
  }
}

/// Parses and validates the text of `plugin.sig`.
@experimental
pub func parsePluginSignature(text: in String): Result[PluginSignature, String] {
  val v = match parseValue(text) {
    case Ok(value) -> value
    case Err(e) -> return Err(error = "plugin.sig is not valid JSON: " + e.message())
  }
  val schema = match getInt(v, "schema") {
    case Some(n) -> n
    case None -> return Err(error = "plugin.sig: 'schema' is missing or not an integer")
  }
  if schema != 1i64 {
    return Err(error = "plugin.sig: schema " + schema.toString() + " is not supported (expected 1)")
  }
  val sigType = match requireText(v, "type") { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  if sigType != ed25519SignatureType {
    return Err(error = "plugin.sig: signature type '" + sigType + "' is not supported (expected 'ed25519')")
  }
  val keyId = match requireText(v, "keyId") { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  if not isLowerHex(keyId, 32) {
    return Err(error = "plugin.sig: 'keyId' is not 32 lowercase hex digits")
  }
  val id = match requireText(v, "id") { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  val version = match requireText(v, "version") { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  val items = match getArray(v, "files") {
    case Some(xs) -> xs
    case None -> return Err(error = "plugin.sig: 'files' is missing or not an array")
  }
  val files: List[SignedFile] = newList()
  var i = 0
  while i < items.count {
    val item = items[i]
    val at = "plugin.sig: files[" + i.toString() + "]"
    val path = match getString(item, "path") {
      case Some(s) -> s
      case None -> return Err(error = at + ".path is missing or not a string")
    }
    match listingPathProblem(path) {
      case Some(reason) -> return Err(error = at + ".path: " + reason)
      case None -> ()
    }
    if path == signatureFileName {
      return Err(error = at + ".path lists plugin.sig itself")
    }
    val digest = match getString(item, "sha256") {
      case Some(s) -> s
      case None -> return Err(error = at + ".sha256 is missing or not a string")
    }
    if not isLowerHex(digest, 64) {
      return Err(error = at + ".sha256 is not 64 lowercase hex digits")
    }
    if i > 0 and compareUtf8(files[i - 1].path, path) >= 0 {
      return Err(error = at + ".path is out of order or repeated")
    }
    files.add(SignedFile(path = path, sha256 = digest))
    i = i + 1
  }
  val sigText = match requireText(v, "signature") { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  val signature = match tryDecodeBase64(sigText) {
    case Some(bytes) -> bytes
    case None -> return Err(error = "plugin.sig: 'signature' is not valid base64")
  }
  if signature.length != 64 {
    return Err(error = "plugin.sig: 'signature' is " + signature.length.toString() + " bytes, not 64")
  }
  Ok(
    value = PluginSignature(
      schema = 1,
      sigType = sigType,
      keyId = keyId,
      id = id,
      version = version,
      files = files,
      signature = signature
    )
  )
}

/// Reads `plugin.sig` from an artifact directory.
@experimental
pub func readPluginSignature(dir: in String): Result[PluginSignature, SignatureProblem] {
  val path = Path.join(dir, signatureFileName)
  val kind = entryKind(path)
  if kind == Missing {
    return Err(error = MissingSignature)
  }
  if kind != RegularFile {
    return Err(error = MalformedSignature(reason = signatureFileName + " is not a regular file"))
  }
  match readText(path) {
    case Ok(text) -> {
      match parsePluginSignature(text) {
        case Ok(sig) -> Ok(value = sig)
        case Err(reason) -> Err(error = MalformedSignature(reason = reason))
      }
    }
    case Err(e) -> Err(error = MalformedSignature(reason = "cannot read " + signatureFileName + ": " + ioErrorText(e)))
  }
}

/// Writes `plugin.sig` into an artifact directory.
@experimental
pub func writePluginSignature(dir: in String, sig: in PluginSignature): Result[Unit, String] {
  match writeText(Path.join(dir, signatureFileName), pluginSignatureToJson(sig)) {
    case Ok(_) -> Ok(value = ())
    case Err(e) -> Err(error = "cannot write " + signatureFileName + ": " + ioErrorText(e))
  }
}

// ---- Signing and verifying --------------------------------------------------
/// The `id`, `version` and `publisher` strings of an artifact's `plugin.json`.
@experimental
pub record ManifestIdentity {
  id: String
  version: String
  publisher: String
}

/// Reads the identity fields of `plugin.json`.
@experimental
pub func readManifestIdentity(dir: in String): Result[ManifestIdentity, String] {
  val text = match readText(Path.join(dir, "plugin.json")) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = "cannot read plugin.json: " + ioErrorText(e))
  }
  val v = match parseValue(text) {
    case Ok(value) -> value
    case Err(e) -> return Err(error = "plugin.json is not valid JSON: " + e.message())
  }
  val id = match getString(v, "id") { case Some(s) -> s; case None -> return Err(error = "plugin.json has no 'id'") }
  val version = match getString(v, "version") {
    case Some(s) -> s
    case None -> return Err(error = "plugin.json has no 'version'")
  }
  val publisher = match getString(v, "publisher") {
    case Some(s) -> s
    case None -> return Err(error = "plugin.json has no 'publisher'")
  }
  Ok(value = ManifestIdentity(id = id, version = version, publisher = publisher))
}

/// Signs an artifact directory with a 32-byte seed: builds the listing, reads
/// the id and version from `plugin.json`, and returns the signature (the
/// caller writes it with `writePluginSignature`). An existing `plugin.sig` is
/// not part of the listing, so re-signing replaces it.
@experimental
pub func signArtifact(dir: in String, seed: in slice[Byte]): Result[PluginSignature, List[String]]
  requires: seed.length == 32
{
  val identity = match readManifestIdentity(dir) {
    case Ok(m) -> m
    case Err(reason) -> {
      val one: List[String] = newList()
      one.add(reason)
      return Err(error = one)
    }
  }
  val problems: List[String] = newList()
  if hasControl(identity.id) or hasControl(identity.version) {
    problems.add("plugin.json's id or version contains a control character")
  }
  val files = match artifactListing(dir) {
    case Ok(fs) -> fs
    case Err(ps) -> {
      for p in ps {
        problems.add(p)
      }
      newList[SignedFile]()
    }
  }
  if problems.count > 0 {
    return Err(error = problems)
  }
  val keyId = publicKeyId(ed25519PublicKey(seed))
  val message = signedMessage(ed25519SignatureType, identity.id, identity.version, keyId, files)
  Ok(
    value = PluginSignature(
      schema = 1,
      sigType = ed25519SignatureType,
      keyId = keyId,
      id = identity.id,
      version = identity.version,
      files = files,
      signature = ed25519Sign(seed, message)
    )
  )
}

// The differences between the signed listing and the files on disk.
func listingDifferences(signed: in List[SignedFile], actual: in List[SignedFile]): List[String] {
  val details: List[String] = newList()
  var i = 0
  var j = 0
  while i < signed.count or j < actual.count {
    if j >= actual.count {
      details.add("'" + signed[i].path + "' is missing")
      i = i + 1
    } else if i >= signed.count {
      details.add("'" + actual[j].path + "' is not in the signed listing")
      j = j + 1
    } else {
      val c = compareUtf8(signed[i].path, actual[j].path)
      if c == 0 {
        if signed[i].sha256 != actual[j].sha256 {
          details.add("'" + actual[j].path + "' has changed")
        }
        i = i + 1
        j = j + 1
      } else if c < 0 {
        details.add("'" + signed[i].path + "' is missing")
        i = i + 1
      } else {
        details.add("'" + actual[j].path + "' is not in the signed listing")
        j = j + 1
      }
    }
  }
  details
}

/// Verifies an artifact directory (D248 Decision 6, steps 1-5): reads
/// `plugin.sig`, finds the key it names among `keys` (refusing a key whose id
/// is in `revokedKeyIds`), verifies the signature, recomputes the listing from
/// disk and requires it to equal the signed one, and requires `plugin.json`'s
/// id and version to equal the signature's and its publisher to be the
/// publisher the key is trusted for.
@experimental
pub func verifyArtifact(
  dir: in String, keys: in List[TrustedKey], revokedKeyIds: in List[String]
): Result[PluginSigner, SignatureProblem] {
  val sig = match readPluginSignature(dir) { case Ok(s) -> s; case Err(p) -> return Err(error = p) }
  if hasString(revokedKeyIds, sig.keyId) {
    return Err(error = RevokedKey(keyId = sig.keyId))
  }
  val message = signedMessage(sig.sigType, sig.id, sig.version, sig.keyId, sig.files)
  var named = false
  var signer: Option[TrustedKey] = None
  for k in keys {
    if publicKeyId(k.publicKey) == sig.keyId {
      named = true
      if signer.isNone() and ed25519Verify(k.publicKey, message, sig.signature) {
        signer = Some(value = k)
      }
    }
  }
  if not named {
    return Err(error = UntrustedKey(keyId = sig.keyId))
  }
  val key = match signer { case Some(k) -> k; case None -> return Err(error = BadSignature(keyId = sig.keyId)) }
  val actual = match artifactListing(dir) {
    case Ok(fs) -> fs
    case Err(problems) -> return Err(error = ListingMismatch(details = problems))
  }
  val differences = listingDifferences(sig.files, actual)
  if differences.count > 0 {
    return Err(error = ListingMismatch(details = differences))
  }
  val identity = match readManifestIdentity(dir) {
    case Ok(m) -> m
    case Err(reason) -> return Err(error = IdentityMismatch(reason = reason))
  }
  if identity.id != sig.id {
    return Err(
      error = IdentityMismatch(
        reason = "plugin.json's id '" + identity.id + "' is not the signed id '" + sig.id + "'"
      )
    )
  }
  if identity.version != sig.version {
    return Err(
      error = IdentityMismatch(
        reason = "plugin.json's version '" + identity.version + "' is not the signed version '" +
          sig.version +
          "'"
      )
    )
  }
  if identity.publisher != key.publisher {
    return Err(
      error = IdentityMismatch(
        reason = "plugin.json's publisher '" + identity.publisher + "' is not '" + key.publisher +
          "', the publisher key " +
          sig.keyId +
          " is trusted for"
      )
    )
  }
  Ok(value = PluginSigner(publisher = key.publisher, keyId = sig.keyId))
}

/// Checks `plugin.sig`'s structure and the listing without a key, for
/// `lyric plugin check`: every problem with the file, every path that breaks
/// the listing rules, and every difference between the signed listing and
/// the files on disk. An artifact without `plugin.sig` has no problems here.
@experimental
pub func checkSignatureStructure(dir: in String): List[String] {
  val problems: List[String] = newList()
  if entryKind(Path.join(dir, signatureFileName)) == Missing {
    return problems
  }
  val sig = match readPluginSignature(dir) {
    case Ok(s) -> s
    case Err(p) -> {
      problems.add(signatureProblemMessage(p))
      return problems
    }
  }
  match artifactListing(dir) {
    case Ok(actual) -> {
      for d in listingDifferences(sig.files, actual) {
        problems.add(d)
      }
    }
    case Err(ps) -> {
      for p in ps {
        problems.add(p)
      }
    }
  }
  match readManifestIdentity(dir) {
    case Ok(identity) -> {
      if identity.id != sig.id or identity.version != sig.version {
        problems.add("plugin.sig is for " + sig.id + " " + sig.version + ", not " + identity.id + " " + identity.version)
      }
    }
    case Err(reason) -> problems.add(reason)
  }
  problems
}
