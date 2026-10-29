package Lyric.Cli

import Std.Core
import Std.Collections
import Std.Environment as Environment
import Std.Errors
import Std.File as File
import Std.Path as Path
import Std.String as Str
import Std.PluginSign as Sign
import Lyric.Manifest as Mf
import Lyric.Lockfile as LF

// ─────────────────────────────────────────────────────────────────────────────
// Restored source generators (D266, D248 Decision 7)
// ─────────────────────────────────────────────────────────────────────────────
// A source generator restored from the registry or from git is not built from
// source: its package carries a signed plugin artifact, laid out as
//
//   lyric-plugin/<id>-<version>/   the artifact `lyric plugin pack` writes,
//                                  with its plugin.sig
//   lyric-plugin/signer.pub        the public key it is signed with
//
// at the root of the restored package (the extracted .nupkg, or the git
// checkout or its `subdir`).  A dependency that pins `key = "..."` is verified
// against that key instead of signer.pub.  `lyric restore` records the key id
// in lyric.lock and refuses a different one until `--update <name>`.
/// The directory of a generator package that holds its artifact and key.
val generatorPluginDirName: String = "lyric-plugin"

/// The public key file a generator package ships beside its artifact.
val generatorSignerKeyFile: String = "signer.pub"

/// A restored generator package whose artifact verified: the directory holding
/// the artifact (what `Std.Plugin.discoverPlugins` scans), the artifact itself,
/// the key it is trusted under and that key's id.
pub record RestoredGeneratorPackage {
  pluginDir: String
  artifactDir: String
  trusted: Sign.TrustedKey
  keyId: String
}

/// The NuGet global packages folder: `$NUGET_PACKAGES`, else
/// `~/.nuget/packages`.  `None` when neither can be found.
pub func nugetPackagesRoot(): Option[String] {
  val fromEnv = Environment.getVarOrDefault("NUGET_PACKAGES", "")
  if fromEnv.length > 0 {
    return Some(value = fromEnv)
  }
  val home = Environment.getVarOrDefault("HOME", Environment.getVarOrDefault("USERPROFILE", ""))
  if home.length == 0 {
    return None
  }
  Some(value = Path.join(home, ".nuget/packages"))
}

/// Where `dotnet restore` extracts package `name` at `version`.
pub func nugetPackageDir(name: in String, version: in String): Option[String] {
  if name.length == 0 or version.length == 0 {
    return None
  }
  match nugetPackagesRoot() {
    case Some(root) -> Some(value = Path.join(Path.join(root, name.toLower()), version.toLower()))
    case None -> None
  }
}

/// The restored directory of a registry or git dependency: its NuGet package
/// folder, or the checkout `lyric.lock` records.  `None` for a path or
/// workspace dependency, or one not restored yet.
pub func restoredDepDir(dep: in Mf.DependencyEntry, lf: in LF.LockFile): Option[String] {
  val dir = match dep.source {
    case Mf.DepSource.Registry(version) -> nugetPackageDir(dep.name, version)
    case Mf.DepSource.Git(_, _, _, _) -> match LF.findPackage(lf, dep.name) {
      case Some(p) -> p.path
      case None -> None
    }
    case _ -> None
  }
  match dir {
    case Some(d) -> if File.dirExists(d) { Some(value = d) } else { None }
    case None -> None
  }
}

/// True when the restored package in `pkgDir` is a source generator package.
pub func isGeneratorPackage(pkgDir: in String): Bool {
  File.dirExists(Path.join(pkgDir, generatorPluginDirName))
}

/// Finds the artifact of the generator package in `pkgDir` and the key it is
/// to be trusted under, without verifying it: `lyric-plugin/` must hold
/// exactly one artifact directory, and the key is the one `pinnedKey` names
/// or, without one, the one in `lyric-plugin/signer.pub`.  The key's
/// publisher is the artifact's own, so the pin is on the key alone.
pub func locateGeneratorPackage(
  pkgDir: in String, pinnedKey: in Option[String]
): Result[RestoredGeneratorPackage, String] {
  val pluginDir = Path.join(pkgDir, generatorPluginDirName)
  val subdirs = match File.listDirs(pluginDir) {
    case Ok(ds) -> ds
    case Err(e) -> return Err(error = "cannot list " + pluginDir + ": " + IOError.message(e))
  }
  val artifacts: List[String] = newList()
  for d in subdirs {
    if File.fileExists(Path.join(d, "plugin.json")) {
      artifacts.add(d)
    }
  }
  if artifacts.count != 1 {
    return Err(
      error = pluginDir + " must hold exactly one plugin artifact directory (one with a plugin.json), not " +
        artifacts.count.toString()
    )
  }
  val artifactDir = artifacts[0]
  val keyText = match pinnedKey {
    case Some(k) -> k
    case None -> {
      val keyPath = Path.join(pluginDir, generatorSignerKeyFile)
      match File.readText(keyPath) {
        case Ok(t) -> t
        case Err(_) -> return Err(
          error = "the package has no " + generatorPluginDirName + "/" + generatorSignerKeyFile +
            " and lyric.toml pins no key for it; a generator package ships the public key it is signed with"
        )
      }
    }
  }
  val publicKey = match Sign.parsePublicKey(keyText) {
    case Ok(k) -> k
    case Err(msg) -> return Err(error = keyOrigin(pinnedKey) + ": " + msg)
  }
  val identity = match Sign.readManifestIdentity(artifactDir) {
    case Ok(i) -> i
    case Err(msg) -> return Err(error = artifactDir + ": " + msg)
  }
  Ok(
    value = RestoredGeneratorPackage(
      pluginDir = pluginDir,
      artifactDir = artifactDir,
      trusted = Sign.TrustedKey(publisher = identity.publisher, publicKey = publicKey),
      keyId = Sign.publicKeyId(publicKey)
    )
  )
}

func keyOrigin(pinnedKey: in Option[String]): String {
  match pinnedKey {
    case Some(_) -> "the key lyric.toml pins"
    case None -> generatorPluginDirName + "/" + generatorSignerKeyFile
  }
}

/// `locateGeneratorPackage`, then a full check of the artifact's signature
/// and files under that key (D248 Decision 6 steps 1-5).  The reason it is
/// refused otherwise, with the load code (K0105-K0110) of a signature
/// problem.
pub func verifyGeneratorPackage(
  pkgDir: in String, pinnedKey: in Option[String]
): Result[RestoredGeneratorPackage, String] {
  val gen = match locateGeneratorPackage(pkgDir, pinnedKey) { case Ok(g) -> g; case Err(e) -> return Err(error = e) }
  val keys: List[Sign.TrustedKey] = newList()
  keys.add(gen.trusted)
  val noRevocations: List[String] = newList()
  match Sign.verifyArtifact(gen.artifactDir, keys, noRevocations) {
    case Ok(_) -> Ok(value = gen)
    case Err(p) -> Err(
      error = Sign.signatureProblemCode(p) + ": " + gen.artifactDir + " is not signed by " +
        keyOrigin(pinnedKey) +
        ": " +
        Sign.signatureProblemMessage(p)
    )
  }
}

/// The message for a generator whose signing key differs from the one
/// `lyric.lock` pinned.
pub func generatorKeyChangedMessage(depName: in String, lockedKeyId: in String, keyId: in String): String {
  "source generator '" + depName + "' is signed by key " + keyId + ", but lyric.lock pins key " + lockedKeyId +
    "; if the publisher rotated its key, accept the new one with `lyric restore --update " +
    depName +
    "`"
}
