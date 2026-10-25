package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Errors
import Std.Encoding
import Std.String as Str
import Std.Uuid as Uuid
import Std.Parse as Parse
import Std.Ed25519 as Ed
import Std.PluginSign as Sign
import Std.PluginCatalogue as Cat

// ─────────────────────────────────────────────────────────────────────────────
// Plugin catalogues (docs/69 §12, D248 Decisions 8-11): `lyric plugin
// catalogue`, `lyric plugin install`, and the zip and catalogue forms of
// `lyric plugin verify`.
// ─────────────────────────────────────────────────────────────────────────────
func catalogueUsageText(): String {
  "Usage: lyric plugin catalogue <command> <dir> [args]\n" + "\n" +
    "  init       <dir> --name <name> --key <secret-key-file> [--expires-in <days>]\n" +
    "             (create and sign an empty catalogue whose catalogue key is --key's)\n" +
    "  publisher  <dir> <name> --key <public-key-file>\n" +
    "             (trust the key for publisher <name>)\n" +
    "  remove-key <dir> <key-id>        (stop trusting a publisher key)\n" +
    "  revoke-key <dir> <key-id>        (revoke a key: hosts refuse what it signed)\n" +
    "  add        <dir> <zip> [--url <url>]\n" +
    "             (verify an artifact zip and list it; without --url it is copied to <dir>/artifacts/)\n" +
    "  yank       <dir> <id> <version>  (never install that version again)\n" +
    "  sign       <dir> --key <secret-key-file> [--rotate-to <secret-key-file>] [--expires-in <days>]\n" +
    "             (increment the serial, set the expiry (default 90 days) and write catalogue.sig;\n" +
    "              --rotate-to makes that key the catalogue key, signed by both)\n" +
    "\n" +
    "Every command but init and sign leaves the catalogue unsigned until `sign` runs."
}

func cmdPluginCatalogue(argv: in slice[String]): Int {
  if argv.length < 3 or argv[2] == "--help" or argv[2] == "-h" {
    Console.println(catalogueUsageText())
    return if argv.length < 3 { 1 } else { 0 }
  }
  val sub = argv[2]
  if sub == "init" {
    return cmdCatalogueInit(argv)
  }
  if sub == "publisher" {
    return cmdCataloguePublisher(argv)
  }
  if sub == "remove-key" or sub == "revoke-key" {
    return cmdCatalogueKeyEdit(argv, sub)
  }
  if sub == "add" {
    return cmdCatalogueAdd(argv)
  }
  if sub == "yank" {
    return cmdCatalogueYank(argv)
  }
  if sub == "sign" {
    return cmdCatalogueSign(argv)
  }
  printErr("plugin catalogue: unknown command '" + sub + "'")
  printErr(catalogueUsageText())
  1
}

// Options after the positional arguments of a catalogue command.
record CatOpts {
  positional: List[String]
  values: Map[String, String]
}

func parseCatOpts(
  cmd: in String, argv: in slice[String], from: in Int, valued: in List[String]
): Result[CatOpts, String] {
  val positional: List[String] = newList()
  val values: Map[String, String] = newMap()
  var i = from
  while i < argv.length {
    val arg = argv[i]
    if Str.startsWith(arg, "-") {
      if not listContains(valued, arg) {
        return Err(error = cmd + ": unknown option '" + arg + "'")
      }
      if i + 1 >= argv.length {
        return Err(error = cmd + ": " + arg + " requires a value")
      }
      values[arg] = argv[i + 1]
      i += 2
    } else {
      positional.add(arg)
      i += 1
    }
  }
  Ok(value = CatOpts(positional = positional, values = values))
}

func optValue(o: in CatOpts, name: in String): String {
  if o.values.containsKey(name) {
    o.values[name]
  } else {
    ""
  }
}

func readCatalogueFile(cmd: in String, dir: in String): Result[Cat.Catalogue, String] {
  val path = Path.join(dir, "catalogue.json")
  val text = match File.readText(path) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = cmd + ": cannot read " + path + ": " + IOError.message(e))
  }
  match Cat.parseCatalogue(text) {
    case Ok(c) -> Ok(value = c)
    case Err(e) -> Err(error = cmd + ": " + path + ": " + e)
  }
}

// Writes an edited catalogue, unsigned until `catalogue sign` runs.
func writeUnsigned(cmd: in String, dir: in String, c: in Cat.Catalogue): Int {
  match File.writeText(Path.join(dir, "catalogue.json"), Cat.catalogueToJson(c)) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr(cmd + ": cannot write catalogue.json: " + IOError.message(e))
      return 1
    }
  }
  val sigPath = Path.join(dir, "catalogue.sig")
  if File.fileExists(sigPath) {
    val _ = File.deleteFile(sigPath)
  }
  Console.println(cmd + ": updated " + dir + "; run `lyric plugin catalogue sign` to publish it")
  0
}

func parseDays(cmd: in String, raw: in String): Result[Int, String] {
  if raw.length == 0 {
    return Ok(value = 90)
  }
  match Parse.tryParseInt(raw) {
    case Ok(n) -> if n > 0 and n <= 3650 {
      Ok(value = n)
    } else {
      Err(error = cmd + ": --expires-in must be 1 to 3650 days")
    }
    case Err(_) -> Err(error = cmd + ": --expires-in must be a number of days")
  }
}

func writeSigned(
  cmd: in String,
  dir: in String,
  c: in Cat.Catalogue,
  seed: in slice[Byte],
  rotate: in Option[slice[Byte]],
  days: in Int,
): Int {
  val pair = match Cat.signCatalogue(c, seed, rotate, days) {
    case Ok(p) -> p
    case Err(e) -> {
      printErr(cmd + ": " + e)
      return 1
    }
  }
  val (json, sig) = pair
  match File.writeText(Path.join(dir, "catalogue.json"), json) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr(cmd + ": cannot write catalogue.json: " + IOError.message(e))
      return 1
    }
  }
  match File.writeText(Path.join(dir, "catalogue.sig"), sig) {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr(cmd + ": cannot write catalogue.sig: " + IOError.message(e))
      return 1
    }
  }
  match Cat.parseCatalogue(json) {
    case Ok(next) -> Console.println(
      cmd + ": signed " + next.name + " serial " + next.serial.toString() + " (expires " + next.expires +
        ", catalogue key " +
        Sign.publicKeyId(next.catalogueKey) +
        ")"
    )
    case Err(_) -> ()
  }
  0
}

func cmdCatalogueInit(argv: in slice[String]): Int {
  val cmd = "plugin catalogue init"
  val valued: List[String] = newList()
  valued.add("--name")
  valued.add("--key")
  valued.add("--expires-in")
  val o = match parseCatOpts(cmd, argv, 3, valued) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  val name = optValue(o, "--name")
  if o.positional.count != 1 or name.length == 0 or optValue(o, "--key").length == 0 {
    printErr("usage: lyric plugin catalogue init <dir> --name <name> --key <secret-key-file> [--expires-in <days>]")
    return 1
  }
  val dir = o.positional[0]
  if File.fileExists(Path.join(dir, "catalogue.json")) {
    printErr(cmd + ": " + dir + " already holds a catalogue")
    return 1
  }
  val seed = match loadSigningSeed(cmd, optValue(o, "--key")) {
    case Ok(s) -> s
    case Err(e) -> {
      printErr(e)
      return 1
    }
  }
  val days = match parseDays(cmd, optValue(o, "--expires-in")) {
    case Ok(d) -> d
    case Err(e) -> {
      printErr(e)
      return 1
    }
  }
  if not File.dirExists(dir) {
    match File.createDir(dir) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr(cmd + ": cannot create " + dir + ": " + IOError.message(e))
        return 1
      }
    }
  }
  writeSigned(cmd, dir, Cat.newCatalogue(name, Ed.ed25519PublicKey(seed)), seed, None, days)
}

func cmdCataloguePublisher(argv: in slice[String]): Int {
  val cmd = "plugin catalogue publisher"
  val valued: List[String] = newList()
  valued.add("--key")
  val o = match parseCatOpts(cmd, argv, 3, valued) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  if o.positional.count != 2 or optValue(o, "--key").length == 0 {
    printErr("usage: lyric plugin catalogue publisher <dir> <name> --key <public-key-file>")
    return 1
  }
  val dir = o.positional[0]
  val c = match readCatalogueFile(cmd, dir) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  val key = match readPublicKeyFile(optValue(o, "--key")) {
    case Ok(k) -> k
    case Err(e) -> {
      printErr(cmd + ": " + e)
      return 1
    }
  }
  writeUnsigned(cmd, dir, Cat.withPublisherKey(c, o.positional[1], key))
}

func cmdCatalogueKeyEdit(argv: in slice[String], sub: in String): Int {
  val cmd = "plugin catalogue " + sub
  if argv.length != 5 {
    printErr("usage: lyric plugin catalogue " + sub + " <dir> <key-id>")
    return 1
  }
  val dir = argv[3]
  val keyId = argv[4]
  val c = match readCatalogueFile(cmd, dir) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  if sub == "revoke-key" {
    writeUnsigned(cmd, dir, Cat.withRevokedKey(c, keyId))
  } else {
    writeUnsigned(cmd, dir, Cat.withoutPublisherKey(c, keyId))
  }
}

func scratchDirFor(label: in String): String {
  val base = Environment.getVarOrDefault(
    "TMPDIR",
    Environment.getVarOrDefault("TEMP", Environment.getVarOrDefault("TMP", "/tmp"))
  )
  Path.join(base, "lyric-" + label + "-" + Uuid.uuidToString(Uuid.newUuid()))
}

func cmdCatalogueAdd(argv: in slice[String]): Int {
  val cmd = "plugin catalogue add"
  val valued: List[String] = newList()
  valued.add("--url")
  val o = match parseCatOpts(cmd, argv, 3, valued) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  if o.positional.count != 2 {
    printErr("usage: lyric plugin catalogue add <dir> <zip> [--url <url>]")
    return 1
  }
  val dir = o.positional[0]
  val zipPath = o.positional[1]
  val c = match readCatalogueFile(cmd, dir) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  val zipBytes = match File.readBytes(zipPath) {
    case Ok(b) -> b
    case Err(e) -> {
      printErr(cmd + ": cannot read " + zipPath + ": " + IOError.message(e))
      return 1
    }
  }
  var url = optValue(o, "--url")
  if url.length == 0 {
    url = "artifacts/" + Path.basename(zipPath)
    val artifacts = Path.join(dir, "artifacts")
    if not File.dirExists(artifacts) {
      match File.createDir(artifacts) {
        case Ok(_) -> ()
        case Err(e) -> {
          printErr(cmd + ": cannot create " + artifacts + ": " + IOError.message(e))
          return 1
        }
      }
    }
    match File.writeBytes(Path.join(dir, url), zipBytes) {
      case Ok(_) -> ()
      case Err(e) -> {
        printErr(cmd + ": cannot copy the zip: " + IOError.message(e))
        return 1
      }
    }
  }
  val entry = match Cat.catalogueEntryForZip(c, zipBytes, url, scratchDirFor("catalogue-add")) {
    case Ok(e) -> e
    case Err(e) -> {
      printErr(cmd + ": " + zipPath + ": " + Cat.catalogueErrorMessage(e))
      return 1
    }
  }
  Console.println(cmd + ": " + entry.id + " " + entry.version + " by " + entry.publisher + " at " + url)
  writeUnsigned(cmd, dir, Cat.withEntry(c, entry))
}

func cmdCatalogueYank(argv: in slice[String]): Int {
  val cmd = "plugin catalogue yank"
  if argv.length != 6 {
    printErr("usage: lyric plugin catalogue yank <dir> <id> <version>")
    return 1
  }
  val dir = argv[3]
  val c = match readCatalogueFile(cmd, dir) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  match Cat.withYanked(c, argv[4], argv[5]) {
    case Some(next) -> writeUnsigned(cmd, dir, next)
    case None -> {
      printErr(cmd + ": the catalogue does not list " + argv[4] + " " + argv[5])
      1
    }
  }
}

func cmdCatalogueSign(argv: in slice[String]): Int {
  val cmd = "plugin catalogue sign"
  val valued: List[String] = newList()
  valued.add("--key")
  valued.add("--rotate-to")
  valued.add("--expires-in")
  val o = match parseCatOpts(cmd, argv, 3, valued) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  if o.positional.count != 1 or optValue(o, "--key").length == 0 {
    printErr(
      "usage: lyric plugin catalogue sign <dir> --key <secret-key-file> [--rotate-to <secret-key-file>] [--expires-in <days>]"
    )
    return 1
  }
  val dir = o.positional[0]
  val c = match readCatalogueFile(cmd, dir) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  val seed = match loadSigningSeed(cmd, optValue(o, "--key")) {
    case Ok(s) -> s
    case Err(e) -> {
      printErr(e)
      return 1
    }
  }
  var rotate: Option[slice[Byte]] = None
  if optValue(o, "--rotate-to").length > 0 {
    match loadSigningSeed(cmd, optValue(o, "--rotate-to")) {
      case Ok(s) -> {
        rotate = Some(value = s)
      }
      case Err(e) -> {
        printErr(e)
        return 1
      }
    }
  }
  val days = match parseDays(cmd, optValue(o, "--expires-in")) {
    case Ok(d) -> d
    case Err(e) -> {
      printErr(e)
      return 1
    }
  }
  writeSigned(cmd, dir, c, seed, rotate, days)
}

// ── install ──────────────────────────────────────────────────────────────────
func cmdPluginInstall(argv: in slice[String]): Int {
  val cmd = "plugin install"
  val usage = "usage: lyric plugin install <id>[@<version>] --catalogue <dir|url> --catalogue-key <public-key-file> --into <dir> [--state <dir>]"
  val valued: List[String] = newList()
  valued.add("--catalogue")
  valued.add("--catalogue-key")
  valued.add("--into")
  valued.add("--state")
  val o = match parseCatOpts(cmd, argv, 2, valued) { case Ok(x) -> x; case Err(e) -> { printErr(e); return 1 } }
  val location = optValue(o, "--catalogue")
  val into = optValue(o, "--into")
  if o.positional.count != 1 or location.length == 0 or into.length == 0 or optValue(o, "--catalogue-key").length == 0 {
    printErr(usage)
    return 1
  }
  val spec = o.positional[0]
  val at = match Str.indexOf(spec, "@") { case Some(i) -> i; case None -> -1 }
  val id = if at >= 0 { spec.substring(0, at) } else { spec }
  val version: Option[String] = if at >= 0 { Some(value = spec.substring(at + 1)) } else { None }
  val key = match readPublicKeyFile(optValue(o, "--catalogue-key")) {
    case Ok(k) -> k
    case Err(e) -> {
      printErr(cmd + ": " + e)
      return 1
    }
  }
  val stateRoot = if optValue(o, "--state").length > 0 {
    optValue(o, "--state")
  } else {
    Path.join(into, ".lyric-catalogues")
  }
  val source = Cat.CatalogueSource(location = location, pinnedKey = key)
  val followed = match Cat.updateCatalogue(source, stateRoot) {
    case Ok(f) -> f
    case Err(e) -> {
      printErr(cmd + ": " + location + ": " + Cat.catalogueErrorMessage(e))
      return 1
    }
  }
  match Cat.installPlugin(followed, id, version, into) {
    case Ok(dir) -> {
      Console.println(
        cmd + ": installed " + dir + " from " + followed.catalogue.name + " (serial " + followed.catalogue.serial.toString() +
          ")"
      )
      0
    }
    case Err(e) -> {
      printErr(cmd + ": " + id + ": " + Cat.catalogueErrorMessage(e))
      1
    }
  }
}

// ── verify against a catalogue, and zips ─────────────────────────────────────
/// The keys and revocations of the catalogue at `location`, verified against
/// `keyFile`'s key (fetched into a scratch state directory, so nothing the
/// host keeps is touched).
func catalogueTrustFor(cmd: in String, location: in String, keyFile: in String): Result[Cat.FollowedCatalogue, String] {
  val key = match readPublicKeyFile(keyFile) { case Ok(k) -> k; case Err(e) -> return Err(error = cmd + ": " + e) }
  val state = scratchDirFor("catalogue-state")
  val result = Cat.updateCatalogue(Cat.CatalogueSource(location = location, pinnedKey = key), state)
  val _ = File.deleteDirRecursive(state)
  match result {
    case Ok(f) -> Ok(value = f)
    case Err(e) -> Err(error = cmd + ": " + location + ": " + Cat.catalogueErrorMessage(e))
  }
}

/// The artifact directory to verify: `path` itself, or a zip extracted into a
/// scratch directory (the second value, to remove afterwards).
func artifactDirFor(cmd: in String, path: in String): Result[(String, String), String] {
  if not Str.endsWith(path, ".zip") {
    return Ok(value = (path, ""))
  }
  val bytes = match File.readBytes(path) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = cmd + ": cannot read " + path + ": " + IOError.message(e))
  }
  val stem = Path.basename(path).substring(0, Path.basename(path).length - 4)
  val scratch = scratchDirFor("plugin-verify")
  match Cat.extractArtifactZip(bytes, stem, scratch) {
    case Ok(_) -> Ok(value = (scratch, scratch))
    case Err(e) -> {
      val _ = File.deleteDirRecursive(scratch)
      Err(error = cmd + ": " + path + ": " + Cat.catalogueErrorMessage(e))
    }
  }
}

/// `lyric plugin pack --zip`: the transfer zip of a packed artifact, beside it.
func writeArtifactZip(cmd: in String, artifact: in String, executables: in List[String]): Int {
  val bytes = match Cat.zipArtifactDir(artifact, executables) {
    case Ok(b) -> b
    case Err(e) -> {
      printErr(cmd + ": " + Cat.catalogueErrorMessage(e))
      return 1
    }
  }
  val zipPath = artifact + ".zip"
  match File.writeBytes(zipPath, bytes) {
    case Ok(_) -> {
      Console.println(cmd + ": wrote " + zipPath)
      0
    }
    case Err(e) -> {
      printErr(cmd + ": cannot write " + zipPath + ": " + IOError.message(e))
      1
    }
  }
}
