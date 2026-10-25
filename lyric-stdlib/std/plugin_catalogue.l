//! std/plugin_catalogue.l - Per-application plugin catalogues (docs/69 §12,
//! D248 Decisions 8-10).
//!
//! A catalogue is two static files at a base location (a directory or an
//! `http(s)` URL): `catalogue.json`, listing publishers and their keys,
//! revoked key ids and plugin entries, and `catalogue.sig`, Ed25519
//! signatures over its raw bytes. A host follows a catalogue by its location
//! and a pinned catalogue key, keeps the last verified copy in a state
//! directory, and installs plugins from it:
//!
//! - `updateCatalogue` fetches and verifies the catalogue: a signature by the
//!   current key (K0120), no serial rollback (K0122), not expired (K0121), and
//!   a key rotation only when the catalogue is signed by both keys.
//! - `loadFollowedCatalogue` returns the last verified copy without the
//!   network, with `stale` set once it has expired, so an offline host keeps
//!   loading its plugins and can say so.
//! - `catalogueTrust` turns pinned keys and followed catalogues into the
//!   `TrustPolicy` a `PluginHostConfig` takes.
//! - `installPlugin` downloads an entry's zip, checks its digest (K0123),
//!   extracts it under the rules of D248 Decision 9 into a temporary
//!   directory, verifies the artifact (K0105-K0110) and its `plugin.sig`
//!   digest and identity (K0123), and renames it into place.
//!
//! The authoring functions (`newCatalogue`, `withPublisherKey`, `withEntry`,
//! `withYanked`, `withRevokedKey`, `signCatalogue`) are what
//! `lyric plugin catalogue` uses to maintain one.
@runtime_checked
@io
package Std.PluginCatalogue

import Std.Core
import Std.Collections
import Std.Ed25519
import Std.Encoding
import Std.Errors
import Std.File
import Std.Hash
import Std.Http
import Std.JsonValue
import Std.Path as Path
import Std.Plugin
import Std.PluginSign
import Std.String
import Std.Time
import Std.Zip

val catalogueMessageHeader: String = "lyric-plugin-catalogue-v1\n"

// ---- Types ------------------------------------------------------------------
/// A publisher a catalogue vouches for, with the keys it signs with.
@experimental
pub record CataloguePublisher {
  name: String
  keys: List[slice[Byte]]
}

/// A point a catalogued plugin implements.
@experimental
pub record CataloguePoint {
  point: String
  version: String
}

/// One plugin version in a catalogue.
@experimental
pub record CatalogueEntry {
  id: String
  version: String
  publisher: String
  points: List[CataloguePoint]
  /// The zip's location, absolute (`http(s)://`) or relative to the
  /// catalogue's base location.
  url: String
  /// Lowercase hex SHA-256 of the zip.
  sha256: String
  /// Lowercase hex SHA-256 of the artifact's `plugin.sig`.
  sigSha256: String
  yanked: Bool
}

/// The contents of `catalogue.json`.
@experimental
pub record Catalogue {
  name: String
  serial: Long
  /// `YYYY-MM-DDTHH:MM:SSZ`.
  expires: String
  catalogueKey: slice[Byte]
  publishers: List[CataloguePublisher]
  revokedKeys: List[String]
  plugins: List[CatalogueEntry]
}

/// A catalogue a host follows: where it is and the catalogue key pinned in
/// the application (the starting point; a verified rotation replaces it in
/// the host's state).
@experimental
pub record CatalogueSource {
  location: String
  pinnedKey: slice[Byte]
}

/// A verified catalogue and where it came from. `stale` is set when it has
/// expired: installs and updates from it are refused, and an application
/// should tell its user that revocations may be missing.
@experimental
pub record FollowedCatalogue {
  catalogue: Catalogue
  location: String
  stale: Bool
}

/// Why a catalogue operation failed. `catalogueErrorCode` gives the docs/69
/// code, where there is one.
@experimental
pub union CatalogueError {
  /// The catalogue or an artifact could not be fetched or read.
  case FetchFailed(location: String, reason: String)
  /// No signature in `catalogue.sig` verifies under the current catalogue key
  /// (K0120).
  case SignatureRejected(reason: String)
  /// The catalogue has expired (K0121).
  case Expired(expires: String)
  /// The serial is lower than the stored one, or equal with other contents
  /// (K0122).
  case Rollback(reason: String)
  /// A downloaded artifact does not match its catalogue entry (K0123).
  case ArtifactMismatch(reason: String)
  /// The extracted artifact's signature was refused (K0105-K0110).
  case ArtifactRefused(code: String, reason: String)
  /// A signed catalogue that is not a valid catalogue, a missing or yanked
  /// entry, or an archive that breaks the extraction rules.
  case Invalid(reason: String)
}

/// The docs/69 code of a catalogue error, or `""` when it has none.
@experimental
pub func catalogueErrorCode(e: in CatalogueError): String {
  match e {
    case SignatureRejected(_) -> "K0120"
    case Expired(_) -> "K0121"
    case Rollback(_) -> "K0122"
    case ArtifactMismatch(_) -> "K0123"
    case ArtifactRefused(code, _) -> code
    case _ -> ""
  }
}

/// A one-line description of a catalogue error, prefixed with its code.
@experimental
pub func catalogueErrorMessage(e: in CatalogueError): String {
  val code = catalogueErrorCode(e)
  val text = match e {
    case FetchFailed(location, reason) -> "cannot fetch " + location + ": " + reason
    case SignatureRejected(reason) -> reason
    case Expired(expires) -> "the catalogue expired at " + expires
    case Rollback(reason) -> reason
    case ArtifactMismatch(reason) -> reason
    case ArtifactRefused(_, reason) -> reason
    case Invalid(reason) -> reason
  }
  if code.length > 0 {
    code + " " + text
  } else {
    text
  }
}

// ---- Time -------------------------------------------------------------------
func digits(s: in String, from: in Int, count: in Int): Option[Int] {
  var n = 0
  var i = 0
  while i < count {
    val c = codeUnitAt(s, from + i)
    if c < 48 or c > 57 {
      return None
    }
    n = n * 10 + (c - 48)
    i = i + 1
  }
  Some(value = n)
}

// Days since 1970-01-01 of a proleptic Gregorian date (H. Hinnant's
// days_from_civil).
func daysFromCivil(y0: in Int, m: in Int, d: in Int): Long {
  val y = if m <= 2 { y0 - 1 } else { y0 }
  val era = (if y >= 0 { y } else { y - 399 }) / 400
  val yoe = y - era * 400
  val mp = if m > 2 { m - 3 } else { m + 9 }
  val doy = (153 * mp + 2) / 5 + d - 1
  val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era.toLong() * 146097i64 + doe.toLong() - 719468i64
}

/// Seconds since the Unix epoch of a `YYYY-MM-DDTHH:MM:SSZ` timestamp.
@experimental
pub func parseCatalogueTime(s: in String): Option[Long] {
  if s.length != 20 or codeUnitAt(s, 4) != 45 or codeUnitAt(s, 7) != 45 or codeUnitAt(s, 10) != 84 or codeUnitAt(s, 13) != 58 or codeUnitAt(s, 16) != 58 or codeUnitAt(s, 19) != 90 {
    return None
  }
  val y = match digits(s, 0, 4) { case Some(n) -> n; case None -> return None }
  val mo = match digits(s, 5, 2) { case Some(n) -> n; case None -> return None }
  val d = match digits(s, 8, 2) { case Some(n) -> n; case None -> return None }
  val h = match digits(s, 11, 2) { case Some(n) -> n; case None -> return None }
  val mi = match digits(s, 14, 2) { case Some(n) -> n; case None -> return None }
  val se = match digits(s, 17, 2) { case Some(n) -> n; case None -> return None }
  if mo < 1 or mo > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or se > 59 {
    return None
  }
  Some(value = daysFromCivil(y, mo, d) * 86400i64 + h.toLong() * 3600i64 + mi.toLong() * 60i64 + se.toLong())
}

func pad2(n: in Long): String = if n < 10i64 { "0" + n.toString() } else { n.toString() }

/// The `YYYY-MM-DDTHH:MM:SSZ` form of a time in seconds since the epoch.
@experimental
pub func formatCatalogueTime(epochSeconds: in Long): String {
  val days = if epochSeconds >= 0i64 { epochSeconds / 86400i64 } else { (epochSeconds - 86399i64) / 86400i64 }
  val secs = epochSeconds - days * 86400i64
  // H. Hinnant's civil_from_days.
  val z = days + 719468i64
  val era = (if z >= 0i64 { z } else { z - 146096i64 }) / 146097i64
  val doe = z - era * 146097i64
  val yoe = (doe - doe / 1460i64 + doe / 36524i64 - doe / 146096i64) / 365i64
  val doy = doe - (365i64 * yoe + yoe / 4i64 - yoe / 100i64)
  val mp = (5i64 * doy + 2i64) / 153i64
  val d = doy - (153i64 * mp + 2i64) / 5i64 + 1i64
  val m = if mp < 10i64 { mp + 3i64 } else { mp - 9i64 }
  val y = yoe + era * 400i64 + (if m <= 2i64 { 1i64 } else { 0i64 })
  y.toString() + "-" + pad2(m) + "-" + pad2(d) + "T" + pad2(secs / 3600i64) + ":" + pad2(secs % 3600i64 / 60i64) + ":" +
    pad2(secs % 60i64) +
    "Z"
}

func nowSeconds(): Long = nowEpochMillis() / 1000i64

// ---- JSON -------------------------------------------------------------------
func field(name: in String, value: in JsonValue): JsonField = JsonField(name = name, value = value)

func strings(xs: in List[String]): JsonValue {
  val items: List[JsonValue] = newList()
  for x in xs {
    items.add(JString(value = x))
  }
  JArray(items = items)
}

/// The JSON text of a catalogue, as `catalogue.json` holds it.
@experimental
pub func catalogueToJson(c: in Catalogue): String {
  val pubs: List[JsonValue] = newList()
  for p in c.publishers {
    val keys: List[String] = newList()
    for k in p.keys {
      keys.add(formatPublicKey(k))
    }
    val fs: List[JsonField] = newList()
    fs.add(field("name", JString(value = p.name)))
    fs.add(field("keys", strings(keys)))
    pubs.add(JObject(fields = fs))
  }
  val entries: List[JsonValue] = newList()
  for e in c.plugins {
    val points: List[JsonValue] = newList()
    for pt in e.points {
      val pf: List[JsonField] = newList()
      pf.add(field("point", JString(value = pt.point)))
      pf.add(field("version", JString(value = pt.version)))
      points.add(JObject(fields = pf))
    }
    val fs: List[JsonField] = newList()
    fs.add(field("id", JString(value = e.id)))
    fs.add(field("version", JString(value = e.version)))
    fs.add(field("publisher", JString(value = e.publisher)))
    fs.add(field("points", JArray(items = points)))
    fs.add(field("url", JString(value = e.url)))
    fs.add(field("sha256", JString(value = e.sha256)))
    fs.add(field("sigSha256", JString(value = e.sigSha256)))
    fs.add(field("yanked", JBool(value = e.yanked)))
    entries.add(JObject(fields = fs))
  }
  val top: List[JsonField] = newList()
  top.add(field("schema", JInt(value = 1i64)))
  top.add(field("name", JString(value = c.name)))
  top.add(field("serial", JInt(value = c.serial)))
  top.add(field("expires", JString(value = c.expires)))
  top.add(field("catalogueKey", JString(value = formatPublicKey(c.catalogueKey))))
  top.add(field("publishers", JArray(items = pubs)))
  top.add(field("revokedKeys", strings(c.revokedKeys)))
  top.add(field("plugins", JArray(items = entries)))
  writeValueIndented(JObject(fields = top), 2) + "\n"
}

func needString(v: in JsonValue, key: in String, at: in String): Result[String, String] {
  match getString(v, key) {
    case Some(s) -> Ok(value = s)
    case None -> Err(error = at + ": '" + key + "' is missing or not a string")
  }
}

func needArray(v: in JsonValue, key: in String, at: in String): Result[List[JsonValue], String] {
  match getArray(v, key) {
    case Some(xs) -> Ok(value = xs)
    case None -> Err(error = at + ": '" + key + "' is missing or not an array")
  }
}

func isHexDigest(s: in String): Bool {
  if s.length != 64 {
    return false
  }
  var i = 0
  while i < 64 {
    val c = codeUnitAt(s, i)
    if not ((c >= 48 and c <= 57) or (c >= 97 and c <= 102)) {
      return false
    }
    i = i + 1
  }
  true
}

/// Parses and validates the text of `catalogue.json`.
@experimental
func entryIdentityProblem(
  // The id and version name the install directory `<id>-<version>`, so they
  // must be a plugin id and a plugin version (no `/`, `\` or `..` segment).
  id: in String,
  version: in String,
  publisher: in String,
): Option[String] {
  if not isPluginId(id) {
    return Some(value = "'" + id + "' is not a plugin id")
  }
  if not isPluginVersion(version) {
    return Some(value = "'" + version + "' is not a plugin version")
  }
  if publisher.length == 0 {
    return Some(value = "the publisher is empty")
  }
  None
}

pub func parseCatalogue(text: in String): Result[Catalogue, String] {
  val v = match parseValue(text) {
    case Ok(value) -> value
    case Err(e) -> return Err(error = "catalogue.json is not valid JSON: " + e.message())
  }
  match getInt(v, "schema") {
    case Some(n) -> if n != 1i64 {
      return Err(error = "catalogue.json: schema " + n.toString() + " is not supported (expected 1)")
    }
    case None -> return Err(error = "catalogue.json: 'schema' is missing")
  }
  val name = match needString(v, "name", "catalogue.json") { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
  val serial = match getInt(v, "serial") {
    case Some(n) -> n
    case None -> return Err(error = "catalogue.json: 'serial' is missing or not an integer")
  }
  if serial < 0i64 {
    return Err(error = "catalogue.json: 'serial' is negative")
  }
  val expires = match needString(v, "expires", "catalogue.json") {
    case Ok(s) -> s
    case Err(e) -> return Err(error = e)
  }
  if parseCatalogueTime(expires).isNone() {
    return Err(error = "catalogue.json: 'expires' is not a YYYY-MM-DDTHH:MM:SSZ time")
  }
  val keyText = match needString(v, "catalogueKey", "catalogue.json") {
    case Ok(s) -> s
    case Err(e) -> return Err(error = e)
  }
  val catalogueKey = match parsePublicKey(keyText) {
    case Ok(k) -> k
    case Err(e) -> return Err(error = "catalogue.json: catalogueKey: " + e)
  }
  val publishers: List[CataloguePublisher] = newList()
  val pubItems = match needArray(v, "publishers", "catalogue.json") {
    case Ok(xs) -> xs
    case Err(e) -> return Err(error = e)
  }
  var i = 0
  while i < pubItems.count {
    val at = "catalogue.json: publishers[" + i.toString() + "]"
    val pname = match needString(pubItems[i], "name", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    val keyItems = match needArray(pubItems[i], "keys", at) { case Ok(xs) -> xs; case Err(e) -> return Err(error = e) }
    val keys: List[slice[Byte]] = newList()
    for k in keyItems {
      match asString(k) {
        case Some(t) -> match parsePublicKey(t) {
          case Ok(bytes) -> keys.add(bytes)
          case Err(e) -> return Err(error = at + ": " + e)
        }
        case None -> return Err(error = at + ": a key is not a string")
      }
    }
    publishers.add(CataloguePublisher(name = pname, keys = keys))
    i = i + 1
  }
  val revoked: List[String] = newList()
  val revItems = match needArray(v, "revokedKeys", "catalogue.json") {
    case Ok(xs) -> xs
    case Err(e) -> return Err(error = e)
  }
  for r in revItems {
    match asString(r) {
      case Some(s) -> revoked.add(s)
      case None -> return Err(error = "catalogue.json: a revoked key id is not a string")
    }
  }
  val plugins: List[CatalogueEntry] = newList()
  val plugItems = match needArray(v, "plugins", "catalogue.json") {
    case Ok(xs) -> xs
    case Err(e) -> return Err(error = e)
  }
  i = 0
  while i < plugItems.count {
    val p = plugItems[i]
    val at = "catalogue.json: plugins[" + i.toString() + "]"
    val id = match needString(p, "id", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    val version = match needString(p, "version", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    val publisher = match needString(p, "publisher", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    val url = match needString(p, "url", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    val sha = match needString(p, "sha256", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    val sigSha = match needString(p, "sigSha256", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
    match entryIdentityProblem(id, version, publisher) {
      case Some(reason) -> return Err(error = at + ": " + reason)
      case None -> ()
    }
    if not isHexDigest(sha) or not isHexDigest(sigSha) {
      return Err(error = at + ": a digest is not 64 lowercase hex digits")
    }
    val yanked = match getBool(p, "yanked") { case Some(b) -> b; case None -> false }
    val points: List[CataloguePoint] = newList()
    val ptItems = match needArray(p, "points", at) { case Ok(xs) -> xs; case Err(e) -> return Err(error = e) }
    for pt in ptItems {
      val point = match needString(pt, "point", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
      val pv = match needString(pt, "version", at) { case Ok(s) -> s; case Err(e) -> return Err(error = e) }
      points.add(CataloguePoint(point = point, version = pv))
    }
    for other in plugins {
      if other.id == id and other.version == version {
        return Err(error = at + ": " + id + " " + version + " is listed twice")
      }
    }
    plugins.add(
      CatalogueEntry(
        id = id,
        version = version,
        publisher = publisher,
        points = points,
        url = url,
        sha256 = sha,
        sigSha256 = sigSha,
        yanked = yanked
      )
    )
    i = i + 1
  }
  Ok(
    value = Catalogue(
      name = name,
      serial = serial,
      expires = expires,
      catalogueKey = catalogueKey,
      publishers = publishers,
      revokedKeys = revoked,
      plugins = plugins
    )
  )
}

// ---- Signatures -------------------------------------------------------------
/// The bytes a catalogue signature covers: a header line and the raw bytes
/// of `catalogue.json`.
@experimental
pub func catalogueSignedMessage(catalogueBytes: in slice[Byte]): slice[Byte] {
  encodeUtf8(catalogueMessageHeader).concat(catalogueBytes)
}

/// The text of `catalogue.sig`: one Ed25519 signature per seed over
/// `catalogueBytes`.
@experimental
pub func signCatalogueBytes(catalogueBytes: in slice[Byte], seeds: in List[slice[Byte]]): String {
  val message = catalogueSignedMessage(catalogueBytes)
  val items: List[JsonValue] = newList()
  for seed in seeds {
    val fs: List[JsonField] = newList()
    fs.add(field("type", JString(value = "ed25519")))
    fs.add(field("keyId", JString(value = publicKeyId(ed25519PublicKey(seed)))))
    fs.add(field("signature", JString(value = encodeBase64(ed25519Sign(seed, message)))))
    items.add(JObject(fields = fs))
  }
  writeValueIndented(JArray(items = items), 2) + "\n"
}

// Whether `catalogue.sig` holds a valid signature by `key` over the bytes.
func signedBy(catalogueBytes: in slice[Byte], sigText: in String, key: in slice[Byte]): Bool {
  val items = match parseValue(sigText) {
    case Ok(v) -> match asArray(v) { case Some(xs) -> xs; case None -> return false }
    case Err(_) -> return false
  }
  val message = catalogueSignedMessage(catalogueBytes)
  val keyId = publicKeyId(key)
  for item in items {
    val sigType = unwrapOr(getString(item, "type"), "")
    val id = unwrapOr(getString(item, "keyId"), "")
    if sigType == "ed25519" and id == keyId {
      match tryDecodeBase64(unwrapOr(getString(item, "signature"), "")) {
        case Some(sig) -> if ed25519Verify(key, message, sig) { return true }
        case None -> ()
      }
    }
  }
  false
}

/// Verifies a fetched catalogue against the current catalogue key: its
/// signature (K0120), a rotation it announces (the new key must sign it too,
/// else K0120), and that it is valid. Returns the catalogue and the key to
/// treat as current from now on.
@experimental
pub func verifyCatalogueBytes(
  catalogueBytes: in slice[Byte], sigText: in String, currentKey: in slice[Byte]
): Result[(Catalogue, slice[Byte]), CatalogueError] {
  if not signedBy(catalogueBytes, sigText, currentKey) {
    return Err(
      error = SignatureRejected(
        reason = "no signature in catalogue.sig verifies under the catalogue key " +
          publicKeyId(currentKey)
      )
    )
  }
  val text = match tryDecodeUtf8(catalogueBytes) {
    case Some(t) -> t
    case None -> return Err(error = Invalid(reason = "catalogue.json is not valid UTF-8"))
  }
  val c = match parseCatalogue(text) { case Ok(cat) -> cat; case Err(e) -> return Err(error = Invalid(reason = e)) }
  if publicKeyId(c.catalogueKey) != publicKeyId(currentKey) {
    if not signedBy(catalogueBytes, sigText, c.catalogueKey) {
      return Err(
        error = SignatureRejected(
          reason = "the catalogue names the catalogue key " + publicKeyId(c.catalogueKey) +
            " but is not signed by it"
        )
      )
    }
  }
  Ok(value = (c, c.catalogueKey))
}

// ---- Fetching and state -----------------------------------------------------
func isHttpLocation(location: in String): Bool = location.startsWith("http://") or location.startsWith("https://")

// `relative` resolved against a catalogue's base location.
func resolveLocation(base: in String, relative: in String): String {
  if isHttpLocation(relative) or (not isHttpLocation(base) and Path.isAbsolute(relative)) {
    return relative
  }
  if isHttpLocation(base) {
    if base.endsWith("/") {
      base + relative
    } else {
      base + "/" + relative
    }
  } else {
    Path.join(base, relative)
  }
}

async func httpGetBytes(url: in String): Result[slice[Byte], String] {
  val r = await getWithTimeoutAsync(url, 120000)
  match r {
    case Err(e) -> Err(error = HttpError.message(e))
    case Ok(resp) -> {
      if not resp.isSuccess() {
        return Err(error = "HTTP status " + resp.statusCode().toString())
      }
      val body = await resp.bodyBytes()
      match body {
        case Ok(b) -> Ok(value = b)
        case Err(e) -> Err(error = IOError.message(e))
      }
    }
  }
}

/// The bytes at `location`: an `http(s)` URL or a file path.
@experimental
pub func fetchBytes(location: in String): Result[slice[Byte], CatalogueError] {
  if isHttpLocation(location) {
    return match await httpGetBytes(location) {
      case Ok(b) -> Ok(value = b)
      case Err(reason) -> Err(error = FetchFailed(location = location, reason = reason))
    }
  }
  match readBytes(location) {
    case Ok(b) -> Ok(value = b)
    case Err(e) -> Err(error = FetchFailed(location = location, reason = IOError.message(e)))
  }
}

func lowerHex(bytes: in slice[Byte]): String = encodeHex(bytes).toLower()

// The state directory for one followed catalogue.
func stateDirFor(stateRoot: in String, location: in String): String {
  Path.join(stateRoot, lowerHex(sha256Digest(encodeUtf8(location)).slice(0, 8)))
}

func writeState(
  dir: in String, catalogueBytes: in slice[Byte], sigText: in String, key: in slice[Byte]
): Result[Unit, CatalogueError] {
  match createDirRecursive(dir) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = FetchFailed(location = dir, reason = IOError.message(e)))
  }
  val writes = [
    writeBytes(Path.join(dir, "catalogue.json"), catalogueBytes),
    writeText(Path.join(dir, "catalogue.sig"), sigText),
    writeText(Path.join(dir, "catalogue.key"), formatPublicKey(key) + "\n")
  ]
  for w in writes {
    match w {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = FetchFailed(location = dir, reason = IOError.message(e)))
    }
  }
  Ok(value = ())
}

func createDirRecursive(dir: in String): Result[Unit, IOError] {
  if dirExists(dir) {
    return Ok(value = ())
  }
  val parent = Path.dirname(dir)
  if parent.length > 0 and parent != dir and not dirExists(parent) {
    match createDirRecursive(parent) {
      case Ok(_) -> ()
      case Err(e) -> return Err(error = e)
    }
  }
  createDir(dir)
}

// The last verified copy: its bytes, signatures and current key.
record StoredState {
  catalogueBytes: slice[Byte]
  sigText: String
  key: slice[Byte]
}

func readState(dir: in String): Option[StoredState] {
  val bytes = match readBytes(Path.join(dir, "catalogue.json")) { case Ok(b) -> b; case Err(_) -> return None }
  val sig = match readText(Path.join(dir, "catalogue.sig")) { case Ok(t) -> t; case Err(_) -> return None }
  val keyText = match readText(Path.join(dir, "catalogue.key")) { case Ok(t) -> t; case Err(_) -> return None }
  match parsePublicKey(keyText) {
    case Ok(k) -> Some(value = StoredState(catalogueBytes = bytes, sigText = sig, key = k))
    case Err(_) -> None
  }
}

func expiresBefore(c: in Catalogue, nowSecs: in Long): Bool {
  match parseCatalogueTime(c.expires) {
    case Some(t) -> t <= nowSecs
    case None -> true
  }
}

/// Fetches, verifies and stores a followed catalogue: a signature by the
/// current key (the stored one, else `source.pinnedKey`; K0120), a rotation
/// only with both signatures, a serial not below the stored one and, when
/// equal, the same bytes (K0122), and not expired (K0121). `stateRoot` is a
/// directory the host owns; each followed catalogue gets its own
/// subdirectory there.
@experimental
pub func updateCatalogue(source: in CatalogueSource, stateRoot: in String): Result[FollowedCatalogue, CatalogueError] {
  val dir = stateDirFor(stateRoot, source.location)
  val stored = readState(dir)
  val currentKey = match stored { case Some(s) -> s.key; case None -> source.pinnedKey }
  val bytes = match fetchBytes(resolveLocation(source.location, "catalogue.json")) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = e)
  }
  val sigText = match fetchBytes(resolveLocation(source.location, "catalogue.sig")) {
    case Ok(b) -> match tryDecodeUtf8(b) { case Some(t) -> t; case None -> "" }
    case Err(e) -> return Err(error = e)
  }
  val verified = match verifyCatalogueBytes(bytes, sigText, currentKey) {
    case Ok(pair) -> pair
    case Err(e) -> return Err(error = e)
  }
  val (c, nextKey) = verified
  match stored {
    case Some(s) -> {
      match verifyCatalogueBytes(s.catalogueBytes, s.sigText, s.key) {
        case Ok(prior) -> {
          val (previous, _) = prior
          if c.serial < previous.serial {
            return Err(
              error = Rollback(
                reason = "the catalogue's serial " + c.serial.toString() + " is lower than " +
                  previous.serial.toString() +
                  ", the last one verified"
              )
            )
          }
          if c.serial == previous.serial and encodeHex(bytes) != encodeHex(s.catalogueBytes) {
            return Err(
              error = Rollback(
                reason = "the catalogue's serial " + c.serial.toString() + " was already seen with other contents"
              )
            )
          }
        }
        case Err(_) -> ()
      }
    }
    case None -> ()
  }
  if expiresBefore(c, nowSeconds()) {
    return Err(error = Expired(expires = c.expires))
  }
  match writeState(dir, bytes, sigText, nextKey) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  Ok(value = FollowedCatalogue(catalogue = c, location = source.location, stale = false))
}

/// The last catalogue `updateCatalogue` verified for `source`, without the
/// network, with `stale` set once it has expired.
@experimental
pub func loadFollowedCatalogue(
  source: in CatalogueSource, stateRoot: in String
): Result[FollowedCatalogue, CatalogueError] {
  val dir = stateDirFor(stateRoot, source.location)
  val s = match readState(dir) {
    case Some(st) -> st
    case None -> return Err(error = FetchFailed(location = dir, reason = "the catalogue has not been fetched yet"))
  }
  match verifyCatalogueBytes(s.catalogueBytes, s.sigText, s.key) {
    case Ok(pair) -> {
      val (c, _) = pair
      Ok(value = FollowedCatalogue(catalogue = c, location = source.location, stale = expiresBefore(c, nowSeconds())))
    }
    case Err(e) -> Err(error = e)
  }
}

// ---- Trust ------------------------------------------------------------------
/// The keys a catalogue trusts, each for its publisher.
@experimental
pub func catalogueKeys(c: in Catalogue): List[TrustedKey] {
  val keys: List[TrustedKey] = newList()
  for p in c.publishers {
    for k in p.keys {
      keys.add(TrustedKey(publisher = p.name, publicKey = k))
    }
  }
  keys
}

/// The trust policy of `pinned` keys plus every followed catalogue's
/// publishers, refusing every key any of them revokes.
@experimental
pub func catalogueTrust(
  pinned: in List[TrustedKey], catalogues: in List[FollowedCatalogue], allowUnsigned: in Bool
): TrustPolicy {
  val keys: List[TrustedKey] = newList()
  for k in pinned {
    keys.add(k)
  }
  val revoked: List[String] = newList()
  for f in catalogues {
    for k in catalogueKeys(f.catalogue) {
      keys.add(k)
    }
    for r in f.catalogue.revokedKeys {
      revoked.add(r)
    }
  }
  TrustPolicy(keys = keys, revokedKeyIds = revoked, allowUnsigned = allowUnsigned)
}

// ---- Versions ---------------------------------------------------------------
func isNumeric(s: in String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = codeUnitAt(s, i)
    if c < 48 or c > 57 {
      return false
    }
    i = i + 1
  }
  true
}

func compareIdentifier(a: in String, b: in String): Int {
  val an = isNumeric(a)
  val bn = isNumeric(b)
  if an and bn {
    if a.length != b.length {
      return a.length - b.length
    }
  } else if an {
    return -1
  } else if bn {
    return 1
  }
  compare(a, b)
}

/// Orders two `major.minor.patch[-prerelease][+build]` versions by semantic
/// version precedence (build metadata is ignored).
@experimental
pub func comparePluginVersions(a: in String, b: in String): Int {
  val ac = split(a, "+")[0]
  val bc = split(b, "+")[0]
  val aCore = split(ac, "-")[0]
  val bCore = split(bc, "-")[0]
  val ap = split(aCore, ".")
  val bp = split(bCore, ".")
  var i = 0
  while i < 3 {
    val x = if i < ap.length { ap[i] } else { "0" }
    val y = if i < bp.length { bp[i] } else { "0" }
    val c = compareIdentifier(x, y)
    if c != 0 {
      return c
    }
    i = i + 1
  }
  val aPre = if ac.length > aCore.length { ac.substring(aCore.length + 1) } else { "" }
  val bPre = if bc.length > bCore.length { bc.substring(bCore.length + 1) } else { "" }
  if aPre.length == 0 and bPre.length == 0 {
    return 0
  }
  if aPre.length == 0 {
    return 1
  }
  if bPre.length == 0 {
    return -1
  }
  val ax = split(aPre, ".")
  val bx = split(bPre, ".")
  var j = 0
  while j < ax.length and j < bx.length {
    val c = compareIdentifier(ax[j], bx[j])
    if c != 0 {
      return c
    }
    j = j + 1
  }
  ax.length - bx.length
}

/// The entry for `id` at `version`, or with no version the highest version
/// that is not yanked.
@experimental
pub func findCatalogueEntry(c: in Catalogue, id: in String, version: in Option[String]): Option[CatalogueEntry] {
  var best: Option[CatalogueEntry] = None
  for e in c.plugins {
    if e.id == id {
      match version {
        case Some(v) -> if e.version == v { return Some(value = e) }
        case None -> if not e.yanked {
          best = match best {
            case Some(b) -> if comparePluginVersions(e.version, b.version) > 0 {
              Some(value = e)
            } else {
              Some(value = b)
            }
            case None -> Some(value = e)
          }
        }
      }
    }
  }
  best
}

// ---- Extraction and installation ---------------------------------------------
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

func hasString(xs: in List[String], s: in String): Bool {
  for x in xs {
    if x == s {
      return true
    }
  }
  false
}

/// Extracts an artifact zip into `intoDir` (which must not exist) under the
/// rules of D248 Decision 9: every entry under the single top-level directory
/// `top` (an `<id>-<version>` name), no symbolic link, every path a listing
/// path (D263), no two paths differing only in case, and the default
/// `ZipLimits`. Executable entries get mode 0755.
@experimental
pub func extractArtifactZip(zipBytes: in slice[Byte], top: in String, intoDir: in String): Result[Unit, CatalogueError] {
  val entries = match readZipDirectory(zipBytes, defaultZipLimits()) {
    case Ok(es) -> es
    case Err(e) -> return Err(error = Invalid(reason = zipErrorMessage(e)))
  }
  val prefix = top + "/"
  val seen: List[String] = newList()
  for e in entries {
    if not e.name.startsWith(prefix) and e.name != prefix {
      return Err(error = Invalid(reason = "the zip entry '" + e.name + "' is not under " + prefix))
    }
    if e.isSymlink {
      return Err(error = Invalid(reason = "the zip entry '" + e.name + "' is a symbolic link"))
    }
    val rest = e.name.substring(prefix.length)
    val path = if rest.endsWith("/") { rest.substring(0, rest.length - 1) } else { rest }
    if path.length > 0 {
      match listingPathProblem(path) {
        case Some(reason) -> return Err(error = Invalid(reason = "the zip entry '" + e.name + "': " + reason))
        case None -> ()
      }
      val folded = asciiLower(path)
      if hasString(seen, folded) {
        return Err(error = Invalid(reason = "the zip entry '" + e.name + "' differs from another only in case"))
      }
      seen.add(folded)
    }
  }
  if entryKind(intoDir) != Missing {
    return Err(error = Invalid(reason = intoDir + " already exists"))
  }
  match createDirRecursive(intoDir) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = FetchFailed(location = intoDir, reason = IOError.message(e)))
  }
  for e in entries {
    val rest = e.name.substring(prefix.length)
    if rest.length > 0 {
      val target = Path.join(intoDir, if rest.endsWith("/") { rest.substring(0, rest.length - 1) } else { rest })
      if e.isDirectory {
        match createDirRecursive(target) {
          case Ok(_) -> ()
          case Err(err) -> return Err(error = FetchFailed(location = target, reason = IOError.message(err)))
        }
      } else {
        val bytes = match readZipEntry(zipBytes, e) {
          case Ok(b) -> b
          case Err(err) -> return Err(error = Invalid(reason = zipErrorMessage(err)))
        }
        match createDirRecursive(Path.dirname(target)) {
          case Ok(_) -> ()
          case Err(err) -> return Err(error = FetchFailed(location = target, reason = IOError.message(err)))
        }
        match writeBytes(target, bytes) {
          case Ok(_) -> ()
          case Err(err) -> return Err(error = FetchFailed(location = target, reason = IOError.message(err)))
        }
        if e.isExecutable {
          match setExecutable(target) {
            case Ok(_) -> ()
            case Err(err) -> return Err(error = FetchFailed(location = target, reason = IOError.message(err)))
          }
        }
      }
    }
  }
  Ok(value = ())
}

// Removes `dir` if it exists, ignoring failures (cleanup on an error path).
func discard(dir: in String): Unit {
  if entryKind(dir) != Missing {
    val _ = deleteDirRecursive(dir)
  }
}

/// Installs a plugin from a followed catalogue into `intoDir`: the entry for
/// `id` (at `version`, or the highest version not yanked), downloaded,
/// checked against its digests and identity (K0123), extracted and verified
/// against the catalogue's keys (K0105-K0110), then renamed to
/// `intoDir/<id>-<version>`. Other installed versions of the plugin are then
/// removed. Returns the installed directory.
@experimental
pub func installPlugin(
  followed: in FollowedCatalogue, id: in String, version: in Option[String], intoDir: in String
): Result[String, CatalogueError] {
  if followed.stale {
    return Err(error = Expired(expires = followed.catalogue.expires))
  }
  val c = followed.catalogue
  val entry = match findCatalogueEntry(c, id, version) {
    case Some(e) -> e
    case None -> return Err(error = Invalid(reason = "the catalogue has no installable entry for " + id))
  }
  if entry.yanked {
    return Err(error = Invalid(reason = id + " " + entry.version + " is yanked"))
  }
  match entryIdentityProblem(entry.id, entry.version, entry.publisher) {
    case Some(reason) -> return Err(error = Invalid(reason = "the catalogue entry for " + id + ": " + reason))
    case None -> ()
  }
  val zipLocation = resolveLocation(followed.location, entry.url)
  val zipBytes = match fetchBytes(zipLocation) { case Ok(b) -> b; case Err(e) -> return Err(error = e) }
  if lowerHex(sha256Digest(zipBytes)) != entry.sha256 {
    return Err(error = ArtifactMismatch(reason = zipLocation + " does not match the catalogue's sha256"))
  }
  val top = entry.id + "-" + entry.version
  match createDirRecursive(intoDir) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = FetchFailed(location = intoDir, reason = IOError.message(e)))
  }
  val staging = Path.join(intoDir, ".lyric-install-" + top)
  discard(staging)
  match extractArtifactZip(zipBytes, top, staging) {
    case Ok(_) -> ()
    case Err(e) -> {
      discard(staging)
      return Err(error = e)
    }
  }
  match verifyArtifact(staging, catalogueKeys(c), c.revokedKeys) {
    case Ok(_) -> ()
    case Err(p) -> {
      discard(staging)
      return Err(error = ArtifactRefused(code = signatureProblemCode(p), reason = signatureProblemMessage(p)))
    }
  }
  val sigBytes = match readBytes(Path.join(staging, "plugin.sig")) {
    case Ok(b) -> b
    case Err(e) -> {
      discard(staging)
      return Err(error = FetchFailed(location = staging, reason = IOError.message(e)))
    }
  }
  if lowerHex(sha256Digest(sigBytes)) != entry.sigSha256 {
    discard(staging)
    return Err(error = ArtifactMismatch(reason = "the artifact's plugin.sig does not match the catalogue's sigSha256"))
  }
  match readManifestIdentity(staging) {
    case Ok(identity) -> {
      if identity.id != entry.id or identity.version != entry.version or identity.publisher != entry.publisher {
        discard(staging)
        return Err(
          error = ArtifactMismatch(
            reason = "the artifact is " + identity.id + " " + identity.version + " by " + identity.publisher +
              ", not the catalogue's " +
              entry.id +
              " " +
              entry.version +
              " by " +
              entry.publisher
          )
        )
      }
    }
    case Err(reason) -> {
      discard(staging)
      return Err(error = ArtifactMismatch(reason = reason))
    }
  }
  val final = Path.join(intoDir, top)
  discard(final)
  match rename(staging, final) {
    case Ok(_) -> ()
    case Err(e) -> {
      discard(staging)
      return Err(error = FetchFailed(location = final, reason = IOError.message(e)))
    }
  }
  // Other installed versions of the plugin would load as duplicates.
  match listDirs(intoDir) {
    case Ok(dirs) -> {
      for d in dirs {
        val name = Path.basename(d)
        if name != top and name.startsWith(entry.id + "-") {
          match readManifestIdentity(d) {
            case Ok(identity) -> if identity.id == entry.id { val _ = deleteDirRecursive(d) }
            case Err(_) -> ()
          }
        }
      }
    }
    case Err(_) -> ()
  }
  Ok(value = final)
}

// ---- Authoring ----------------------------------------------------------------
/// A new, empty catalogue named `name` whose catalogue key is `key`.
@experimental
pub func newCatalogue(name: in String, key: in slice[Byte]): Catalogue {
  Catalogue(
    name = name,
    serial = 0i64,
    expires = formatCatalogueTime(nowSeconds()),
    catalogueKey = key,
    publishers = newList(),
    revokedKeys = newList(),
    plugins = newList()
  )
}

func copyCatalogue(
  c: in Catalogue,
  serial: in Long,
  expires: in String,
  key: in slice[Byte],
  publishers: in List[CataloguePublisher],
  revoked: in List[String],
  plugins: in List[CatalogueEntry],
): Catalogue {
  Catalogue(
    name = c.name,
    serial = serial,
    expires = expires,
    catalogueKey = key,
    publishers = publishers,
    revokedKeys = revoked,
    plugins = plugins
  )
}

/// `c` with `key` added to publisher `name` (created when new).
@experimental
pub func withPublisherKey(c: in Catalogue, name: in String, key: in slice[Byte]): Catalogue {
  val pubs: List[CataloguePublisher] = newList()
  var found = false
  for p in c.publishers {
    if p.name == name {
      found = true
      val keys: List[slice[Byte]] = newList()
      var present = false
      for k in p.keys {
        keys.add(k)
        if publicKeyId(k) == publicKeyId(key) {
          present = true
        }
      }
      if not present {
        keys.add(key)
      }
      pubs.add(CataloguePublisher(name = name, keys = keys))
    } else {
      pubs.add(p)
    }
  }
  if not found {
    val keys: List[slice[Byte]] = newList()
    keys.add(key)
    pubs.add(CataloguePublisher(name = name, keys = keys))
  }
  copyCatalogue(c, c.serial, c.expires, c.catalogueKey, pubs, c.revokedKeys, c.plugins)
}

/// `c` without the key `keyId` in any publisher's list.
@experimental
pub func withoutPublisherKey(c: in Catalogue, keyId: in String): Catalogue {
  val pubs: List[CataloguePublisher] = newList()
  for p in c.publishers {
    val keys: List[slice[Byte]] = newList()
    for k in p.keys {
      if publicKeyId(k) != keyId {
        keys.add(k)
      }
    }
    pubs.add(CataloguePublisher(name = p.name, keys = keys))
  }
  copyCatalogue(c, c.serial, c.expires, c.catalogueKey, pubs, c.revokedKeys, c.plugins)
}

/// `c` with `keyId` revoked.
@experimental
pub func withRevokedKey(c: in Catalogue, keyId: in String): Catalogue {
  val revoked: List[String] = newList()
  for r in c.revokedKeys {
    revoked.add(r)
  }
  if not hasString(revoked, keyId) {
    revoked.add(keyId)
  }
  copyCatalogue(c, c.serial, c.expires, c.catalogueKey, c.publishers, revoked, c.plugins)
}

/// `c` with `entry` added, replacing an entry for the same id and version.
@experimental
pub func withEntry(c: in Catalogue, entry: in CatalogueEntry): Catalogue {
  val plugins: List[CatalogueEntry] = newList()
  for e in c.plugins {
    if not (e.id == entry.id and e.version == entry.version) {
      plugins.add(e)
    }
  }
  plugins.add(entry)
  copyCatalogue(c, c.serial, c.expires, c.catalogueKey, c.publishers, c.revokedKeys, plugins)
}

/// `c` with `id` at `version` yanked; `None` when there is no such entry.
@experimental
pub func withYanked(c: in Catalogue, id: in String, version: in String): Option[Catalogue] {
  val plugins: List[CatalogueEntry] = newList()
  var found = false
  for e in c.plugins {
    if e.id == id and e.version == version {
      found = true
      plugins.add(
        CatalogueEntry(
          id = e.id,
          version = e.version,
          publisher = e.publisher,
          points = e.points,
          url = e.url,
          sha256 = e.sha256,
          sigSha256 = e.sigSha256,
          yanked = true
        )
      )
    } else {
      plugins.add(e)
    }
  }
  if found {
    Some(value = copyCatalogue(c, c.serial, c.expires, c.catalogueKey, c.publishers, c.revokedKeys, plugins))
  } else {
    None
  }
}

/// The signed form of `c`: its serial incremented, its expiry `expiresInDays`
/// from now and, when `rotateTo` is given, its catalogue key replaced by that
/// key's. Returns the `catalogue.json` text and the `catalogue.sig` text,
/// signed by `currentSeed` and, when rotating, by the new key too.
@experimental
pub func signCatalogue(
  c: in Catalogue,
  currentSeed: in slice[Byte],
  rotateTo: in Option[slice[Byte]],
  expiresInDays: in Int,
): Result[(String, String), String]
  requires: currentSeed.length == 32 and expiresInDays > 0
{
  val currentKey = ed25519PublicKey(currentSeed)
  if publicKeyId(currentKey) != publicKeyId(c.catalogueKey) {
    return Err(
      error = "the key " + publicKeyId(currentKey) + " is not the catalogue key " + publicKeyId(c.catalogueKey) +
        "; sign with the current key (and --rotate-to the new one)"
    )
  }
  val seeds: List[slice[Byte]] = newList()
  seeds.add(currentSeed)
  var nextKey = c.catalogueKey
  match rotateTo {
    case Some(seed) -> {
      seeds.add(seed)
      nextKey = ed25519PublicKey(seed)
    }
    case None -> ()
  }
  val expires = formatCatalogueTime(nowSeconds() + expiresInDays.toLong() * 86400i64)
  val next = copyCatalogue(c, c.serial + 1i64, expires, nextKey, c.publishers, c.revokedKeys, c.plugins)
  val json = catalogueToJson(next)
  Ok(value = (json, signCatalogueBytes(encodeUtf8(json), seeds)))
}

/// A catalogue entry for the artifact zip `zipBytes`, to be served from
/// `url`: the zip is extracted into `scratchDir` (which must not exist) and
/// verified against the catalogue's publishers, and the entry takes its id,
/// version, publisher and points from the artifact. `scratchDir` is removed
/// afterwards.
@experimental
pub func catalogueEntryForZip(
  c: in Catalogue, zipBytes: in slice[Byte], url: in String, scratchDir: in String
): Result[CatalogueEntry, CatalogueError] {
  val entries = match readZipDirectory(zipBytes, defaultZipLimits()) {
    case Ok(es) -> es
    case Err(e) -> return Err(error = Invalid(reason = zipErrorMessage(e)))
  }
  if entries.count == 0 {
    return Err(error = Invalid(reason = "the zip is empty"))
  }
  val first = entries[0].name
  val slash = match indexOf(first, "/") {
    case Some(i) -> i
    case None -> return Err(error = Invalid(reason = "the zip has no top-level <id>-<version>/ directory"))
  }
  val top = first.substring(0, slash)
  match extractArtifactZip(zipBytes, top, scratchDir) {
    case Ok(_) -> ()
    case Err(e) -> {
      discard(scratchDir)
      return Err(error = e)
    }
  }
  val result = entryForDir(c, scratchDir, top, url, zipBytes)
  discard(scratchDir)
  result
}

func entryForDir(
  c: in Catalogue, dir: in String, top: in String, url: in String, zipBytes: in slice[Byte]
): Result[CatalogueEntry, CatalogueError] {
  val manifest = match readPluginManifest(dir) {
    case Ok(m) -> m
    case Err(issue) -> return Err(error = Invalid(reason = pluginLoadIssueMessage(issue)))
  }
  if top != manifest.id + "-" + manifest.version {
    return Err(
      error = Invalid(
        reason = "the zip's top-level directory " + top + " is not " + manifest.id + "-" + manifest.version
      )
    )
  }
  match verifyArtifact(dir, catalogueKeys(c), c.revokedKeys) {
    case Ok(_) -> ()
    case Err(p) -> return Err(error = ArtifactRefused(code = signatureProblemCode(p), reason = signatureProblemMessage(p)))
  }
  val sigBytes = match readBytes(Path.join(dir, "plugin.sig")) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = FetchFailed(location = dir, reason = IOError.message(e)))
  }
  val points: List[CataloguePoint] = newList()
  for p in manifest.points {
    points.add(CataloguePoint(point = p.point, version = p.version))
  }
  Ok(
    value = CatalogueEntry(
      id = manifest.id,
      version = manifest.version,
      publisher = manifest.publisher,
      points = points,
      url = url,
      sha256 = lowerHex(sha256Digest(zipBytes)),
      sigSha256 = lowerHex(sha256Digest(sigBytes)),
      yanked = false
    )
  )
}

/// The transfer zip of an artifact directory: every listed file and
/// `plugin.sig`, under `<id>-<version>/`, executable files marked so.
@experimental
pub func zipArtifactDir(dir: in String, executables: in List[String]): Result[slice[Byte], CatalogueError] {
  val identity = match readManifestIdentity(dir) {
    case Ok(m) -> m
    case Err(reason) -> return Err(error = Invalid(reason = reason))
  }
  val top = identity.id + "-" + identity.version
  val paths = match listingPaths(dir) {
    case Ok(ps) -> ps
    case Err(problems) -> return Err(error = Invalid(reason = joinList("; ", problems)))
  }
  val files: List[ZipFile] = newList()
  for p in paths {
    val bytes = match readBytes(Path.join(dir, p)) {
      case Ok(b) -> b
      case Err(e) -> return Err(error = FetchFailed(location = Path.join(dir, p), reason = IOError.message(e)))
    }
    files.add(ZipFile(name = top + "/" + p, data = bytes, executable = hasString(executables, p)))
  }
  val sigPath = Path.join(dir, "plugin.sig")
  if entryKind(sigPath) == RegularFile {
    match readBytes(sigPath) {
      case Ok(b) -> files.add(ZipFile(name = top + "/plugin.sig", data = b))
      case Err(e) -> return Err(error = FetchFailed(location = sigPath, reason = IOError.message(e)))
    }
  }
  Ok(value = writeZip(files))
}
