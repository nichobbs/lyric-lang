package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Console as Console
import Std.File as File
import Std.Path as Path
import Std.Environment as Environment
import Std.Errors
import Std.Process as Process
import Std.SecureRandom as SecureRandom
import Std.String as Str
import Std.Ed25519 as Ed
import Std.PluginSign as Sign
import Std.PluginCatalogue as Cat
import Lyric.PluginManifest as Pm

// ─────────────────────────────────────────────────────────────────────────────
// Plugin signing (docs/69 §12, D248 Decisions 3, 4 and 11): `lyric plugin
// keygen`, `sign` and `verify`, and the signing step of `lyric plugin pack
// --sign-key`.
// ─────────────────────────────────────────────────────────────────────────────
/// The environment variable that holds a secret key's text, for signing in CI
/// from a secret store without writing the key to disk.
val signingKeyEnv: String = "LYRIC_PLUGIN_SIGNING_KEY"

func restrictToOwner(path: in String): Result[Unit, String] {
  if Environment.isWindows() {
    return Ok(value = ())
  }
  val args: List[String] = newList()
  args.add("600")
  args.add(path)
  match Process.run("chmod", args) {
    case Ok(code) -> if code == 0 {
      Ok(value = ())
    } else {
      Err(error = "chmod 600 " + path + " exited " + code.toString())
    }
    case Err(e) -> Err(error = "cannot run chmod: " + IOError.message(e))
  }
}

// ── keygen ───────────────────────────────────────────────────────────────────
func cmdPluginKeygen(argv: in slice[String]): Int {
  if argv.length != 4 or argv[2] != "-o" {
    printErr("usage: lyric plugin keygen -o <base>")
    return 1
  }
  val base = argv[3]
  val keyPath = base + ".key"
  val pubPath = base + ".pub"
  if File.fileExists(keyPath) or File.fileExists(pubPath) {
    printErr("plugin keygen: " + keyPath + " or " + pubPath + " already exists; refusing to overwrite a key")
    return 1
  }
  val seed = SecureRandom.secureGetBytes(32)
  val publicKey = Ed.ed25519PublicKey(seed)
  // The secret key is written to an empty file that is restricted first, so
  // its text never sits in a file other users can read.
  match File.writeText(keyPath, "") {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("plugin keygen: cannot write " + keyPath + ": " + IOError.message(e))
      return 1
    }
  }
  match restrictToOwner(keyPath) {
    case Ok(_) -> ()
    case Err(msg) -> {
      val _ = File.deleteFile(keyPath)
      printErr("plugin keygen: " + msg)
      return 1
    }
  }
  match File.writeText(keyPath, Sign.formatSecretKey(seed) + "\n") {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("plugin keygen: cannot write " + keyPath + ": " + IOError.message(e))
      return 1
    }
  }
  match File.writeText(pubPath, Sign.formatPublicKey(publicKey) + "\n") {
    case Ok(_) -> ()
    case Err(e) -> {
      printErr("plugin keygen: cannot write " + pubPath + ": " + IOError.message(e))
      return 1
    }
  }
  Console.println(
    "plugin keygen: wrote " + keyPath + " (secret) and " + pubPath + " (key id " + Sign.publicKeyId(publicKey) + ")"
  )
  0
}

// ── sign ─────────────────────────────────────────────────────────────────────
/// The signing seed from `--key <file>`, else from `LYRIC_PLUGIN_SIGNING_KEY`.
func loadSigningSeed(cmd: in String, keyFile: in String, keyFlag: in String = "--key"): Result[slice[Byte], String] {
  if keyFile.length > 0 {
    val text = match File.readText(keyFile) {
      case Ok(t) -> t
      case Err(e) -> return Err(error = cmd + ": cannot read " + keyFile + ": " + IOError.message(e))
    }
    return match Sign.parseSecretKey(text) {
      case Ok(seed) -> Ok(value = seed)
      case Err(msg) -> Err(error = cmd + ": " + keyFile + ": " + msg)
    }
  }
  val fromEnv = Environment.getVarOrDefault(signingKeyEnv, "")
  if fromEnv.length == 0 {
    return Err(error = cmd + ": no signing key: pass " + keyFlag + " <file> or set " + signingKeyEnv)
  }
  match Sign.parseSecretKey(fromEnv) {
    case Ok(seed) -> Ok(value = seed)
    case Err(msg) -> Err(error = cmd + ": " + signingKeyEnv + ": " + msg)
  }
}

/// Checks an artifact directory and writes its `plugin.sig`. Returns the
/// process exit code; `cmd` prefixes every message.
func signArtifactDir(cmd: in String, dir: in String, seed: in slice[Byte]): Int {
  val manifestProblems = Pm.checkArtifactDir(dir)
  if manifestProblems.count > 0 {
    for p in manifestProblems {
      printErr(cmd + ": " + Path.join(dir, "plugin.json") + ": " + Pm.problemText(p))
    }
    return 1
  }
  val sig = match Sign.signArtifact(dir, seed) {
    case Ok(s) -> s
    case Err(problems) -> {
      for p in problems {
        printErr(cmd + ": " + dir + ": " + p)
      }
      return 1
    }
  }
  match Sign.writePluginSignature(dir, sig) {
    case Ok(_) -> ()
    case Err(msg) -> {
      printErr(cmd + ": " + dir + ": " + msg)
      return 1
    }
  }
  Console.println(
    cmd + ": signed " + sig.id + " " + sig.version + " with key " + sig.keyId + " (" + sig.files.count.toString() +
      " files)"
  )
  0
}

func cmdPluginSign(argv: in slice[String]): Int {
  var dir = ""
  var keyFile = ""
  var i = 2
  while i < argv.length {
    val arg = argv[i]
    if arg == "--key" {
      if i + 1 >= argv.length {
        printErr("plugin sign: --key requires a value")
        return 1
      }
      keyFile = argv[i + 1]
      i += 2
    } else if Str.startsWith(arg, "-") or dir.length > 0 {
      printErr("usage: lyric plugin sign <dir> [--key <secret-key-file>]")
      return 1
    } else {
      dir = arg
      i += 1
    }
  }
  if dir.length == 0 {
    printErr("usage: lyric plugin sign <dir> [--key <secret-key-file>]")
    return 1
  }
  val seed = match loadSigningSeed("plugin sign", keyFile) {
    case Ok(s) -> s
    case Err(msg) -> {
      printErr(msg)
      return 1
    }
  }
  signArtifactDir("plugin sign", dir, seed)
}

// ── verify ───────────────────────────────────────────────────────────────────
func readPublicKeyFile(path: in String): Result[slice[Byte], String] {
  val text = match File.readText(path) {
    case Ok(t) -> t
    case Err(e) -> return Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
  match Sign.parsePublicKey(text) {
    case Ok(k) -> Ok(value = k)
    case Err(msg) -> Err(error = path + ": " + msg)
  }
}

func cmdPluginVerify(argv: in slice[String]): Int {
  val usage = "usage: lyric plugin verify <dir|zip> (--key <public-key-file>... [--publisher <name>] | " +
    "--catalogue <dir|url> --catalogue-key <public-key-file>)"
  var target = ""
  var publisher = ""
  var catalogue = ""
  var catalogueKey = ""
  val keyFiles: List[String] = newList()
  var i = 2
  while i < argv.length {
    val arg = argv[i]
    if arg == "--key" or arg == "--publisher" or arg == "--catalogue" or arg == "--catalogue-key" {
      if i + 1 >= argv.length {
        printErr("plugin verify: " + arg + " requires a value")
        return 1
      }
      if arg == "--key" {
        keyFiles.add(argv[i + 1])
      } else if arg == "--publisher" {
        publisher = argv[i + 1]
      } else if arg == "--catalogue" {
        catalogue = argv[i + 1]
      } else {
        catalogueKey = argv[i + 1]
      }
      i += 2
    } else if Str.startsWith(arg, "-") or target.length > 0 {
      printErr(usage)
      return 1
    } else {
      target = arg
      i += 1
    }
  }
  val byCatalogue = catalogue.length > 0 or catalogueKey.length > 0
  if target.length == 0 or (byCatalogue and (catalogue.length == 0 or catalogueKey.length == 0)) or (not byCatalogue and keyFiles.count == 0) or (byCatalogue and (keyFiles.count > 0 or publisher.length > 0)) {
    printErr(usage)
    return 1
  }
  val (dir, scratch) = match artifactDirFor("plugin verify", target) {
    case Ok(pair) -> pair
    case Err(msg) -> {
      printErr(msg)
      return 1
    }
  }
  val rc = verifyDir(dir, target, keyFiles, publisher, catalogue, catalogueKey)
  if scratch.length > 0 {
    val _ = File.deleteDirRecursive(scratch)
  }
  rc
}

func verifyDir(
  dir: in String,
  label: in String,
  keyFiles: in List[String],
  publisher: in String,
  catalogue: in String,
  catalogueKey: in String,
): Int {
  val keys: List[Sign.TrustedKey] = newList()
  val revoked: List[String] = newList()
  if catalogue.length > 0 {
    // The catalogue's publishers, each with its keys, and its revocations.
    val followed = match catalogueTrustFor("plugin verify", catalogue, catalogueKey) {
      case Ok(f) -> f
      case Err(msg) -> {
        printErr(msg)
        return 1
      }
    }
    for k in Cat.catalogueKeys(followed.catalogue) {
      keys.add(k)
    }
    for r in followed.catalogue.revokedKeys {
      revoked.add(r)
    }
  } else {
    // Without --publisher, the keys are trusted for the publisher the manifest
    // names, so verify checks the signature and the files; with it, the
    // manifest must also name that publisher.
    val trustedFor = if publisher.length > 0 {
      publisher
    } else {
      match Sign.readManifestIdentity(dir) {
        case Ok(m) -> m.publisher
        case Err(msg) -> {
          printErr("plugin verify: " + label + ": " + msg)
          return 1
        }
      }
    }
    for f in keyFiles {
      match readPublicKeyFile(f) {
        case Ok(k) -> keys.add(Sign.TrustedKey(publisher = trustedFor, publicKey = k))
        case Err(msg) -> {
          printErr("plugin verify: " + msg)
          return 1
        }
      }
    }
  }
  match Sign.verifyArtifact(dir, keys, revoked) {
    case Ok(signer) -> {
      match Sign.readManifestIdentity(dir) {
        case Ok(m) -> Console.println(
          "plugin verify: " + m.id + " " + m.version + " is signed by " + signer.publisher + " (key " +
            signer.keyId +
            ")"
        )
        case Err(_) -> Console.println("plugin verify: " + label + " is signed by " + signer.publisher)
      }
      0
    }
    case Err(p) -> {
      printErr("plugin verify: " + label + ": " + Sign.signatureProblemCode(p) + ": " + Sign.signatureProblemMessage(p))
      1
    }
  }
}
