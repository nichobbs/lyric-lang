// lyric/gitdep/gitdep.l — git-source dependency resolver (Phase 5 §M5.3).
//
// Resolves `{ git = "...", tag/rev/branch, subdir }` dependencies by
// cloning into a local cache under `~/.lyric/git-cache/`.
//
// Each remote URL maps to a deterministic directory name via `urlToHash`.
// Within that directory each ref variant lives in its own subdirectory so
// multiple refs from the same repo coexist without conflict:
//   tag-<name>         — shallow clone pinned at a tag
//   rev-<first-12>     — full clone checked out at a specific commit SHA
//   branch-<name>      — shallow clone tracking a branch (refreshed on use)
//
// Branch refs are always re-fetched (git pull) because they are mutable.
// Tag and Rev refs are cached permanently once cloned.

package Lyric.GitDep

import Std.Core
import Std.Collections
import Std.Console
import Std.String as Str      // before Path so Path.join/2 wins over Str.join/2
import Std.Char as Char
import Std.File as File
import Std.Path as Path
import Std.Directory as Dir
import Std.Environment as Env
import Std.Process as Process
import Std.ProcessCapture as PC
import Std.Errors

// ─────────────────────────────────────────────────────────────────────────────
// §1. Public types
// ─────────────────────────────────────────────────────────────────────────────

/// A reference that pins a git dependency to a specific point in history.
pub union GitRef {
  /// A git tag (e.g. `v1.2.3`).  Resolved with a shallow clone so the
  /// network transfer is minimal.
  case Tag(name: String)
  /// An exact commit SHA.  The full history is cloned so the SHA is
  /// guaranteed to be reachable.
  case Rev(sha: String)
  /// A branch name (e.g. `main`).  Always refreshed with `git pull` so
  /// the working copy reflects the latest remote state.
  case Branch(name: String)
}

/// The result of a successful `resolve` call.
pub record GitDepResult {
  /// Absolute path to the resolved directory.  This is either the clone
  /// root or the `subdir` within it when the dependency specifies one.
  localDir:    String
  /// Resolved git commit SHA.  For `Rev` refs this is the SHA from the manifest;
  /// for `Tag` and `Branch` refs it is the result of `git rev-parse HEAD`
  /// after the clone/pull completes.
  resolvedRev: String
}

// ─────────────────────────────────────────────────────────────────────────────
// §2. Cache directory helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Return the root of the git dependency cache.
///
/// Defaults to `~/.lyric/git-cache`; `~` is resolved via the `HOME`
/// environment variable with a fallback of `/root` for container builds.
pub func cacheDir(): String {
  val homeDir = Env.getVarOrDefault("HOME", "/root")
  Path.join(homeDir, ".lyric/git-cache")
}

/// Derive a filesystem-safe directory name from a git URL.
///
/// Strips `https://` and `http://` schemes, then replaces `/`, `:`, and
/// `.` with `-`.  Appends a DJB2 hash of the full original URL (decimal)
/// so that two URLs that collapse to the same sanitised prefix still map
/// to distinct directories.  Leading/trailing hyphens are stripped
/// character-by-character so they never appear at the boundaries.
///
/// Examples:
///   "https://github.com/example/repo" → "github-com-example-repo-<hash>"
///   "http://localhost:3000/my.git"     → "localhost-3000-my-git-<hash>"
pub func urlToHash(url: in String): String {
  // Sanitise the URL into a human-readable prefix.
  val prefix = url
    .replace("https://", "")
    .replace("http://", "")
    .replace("/", "-")
    .replace(":", "-")
    .replace(".", "-")

  // Strip leading hyphens from prefix.
  var trimmed = prefix
  while trimmed.length > 0 and trimmed[0] == '-' {
    trimmed = Str.substring(trimmed, 1, trimmed.length - 1)
  }
  // Strip trailing hyphens.
  while trimmed.length > 0 and trimmed[trimmed.length - 1] == '-' {
    trimmed = Str.substring(trimmed, 0, trimmed.length - 1)
  }

  // DJB2-style hash over the original URL for collision avoidance.
  // Bounds: (h % 65000000) * 33 ≤ 64999999*33 = 2144999967,
  // which leaves room for ASCII charCode (max 127) within Int.MAX.
  var h = 5381
  var ui = 0
  while ui < url.length {
    h = (h % 65000000) * 33 + Char.toInt(url[ui])
    ui += 1
  }
  trimmed + "-" + Str.fromInt(h)
}

// ─────────────────────────────────────────────────────────────────────────────
// §3. Internal helpers
// ─────────────────────────────────────────────────────────────────────────────

// Derive the subdirectory name for a given ref variant.
func refDirName(ref: in GitRef): String {
  match ref {
    case Tag(name)    -> "tag-" + name
    case Rev(sha)     ->
      // Use only the first 12 characters of the SHA for readability.
      if sha.length >= 12 { "rev-" + Str.substring(sha, 0, 12) }
      else                { "rev-" + sha }
    case Branch(name) -> "branch-" + name
  }
}

// True when `dir` looks like an already-initialised git clone.
func isGitClone(dir: in String): Bool {
  val dotGit = Path.join(dir, ".git")
  Dir.exists(dotGit)
}

// Run `git` with the given argument list.
// Returns Ok(0) on success, Ok(code) for non-zero exits, Err on spawn failure.
func runGit(args: in List[String]): Result[Int, IOError] {
  Process.run("git", args)
}

// Build an Err string from a git command result.
func gitErrMsg(op: in String, code: in Int): String {
  "git " + op + " failed (exit " + Str.fromInt(code) + ")"
}

// ─────────────────────────────────────────────────────────────────────────────
// §4. Clone / fetch strategies
// ─────────────────────────────────────────────────────────────────────────────

// Clone a tag: shallow clone with `--branch <tag> --depth 1`.
func cloneTag(url: in String, tagName: in String, targetDir: in String): Result[Unit, String] {
  val args: List[String] = newList()
  args.add("clone")
  args.add("--branch")
  args.add(tagName)
  args.add("--depth")
  args.add("1")
  args.add(url)
  args.add(targetDir)
  match runGit(args) {
    case Err(e)    -> Err(error = "git clone failed: " + IOError.message(e))
    case Ok(code)  ->
      if code != 0 { Err(error = gitErrMsg("clone", code)) }
      else         { Ok(value = ()) }
  }
}

// Clone a specific revision: full clone then checkout.
func cloneRev(url: in String, sha: in String, targetDir: in String): Result[Unit, String] {
  // Full clone — required so the SHA is reachable.
  val cloneArgs: List[String] = newList()
  cloneArgs.add("clone")
  cloneArgs.add(url)
  cloneArgs.add(targetDir)
  match runGit(cloneArgs) {
    case Err(e)   -> return Err(error = "git clone failed: " + IOError.message(e))
    case Ok(code) ->
      if code != 0 { return Err(error = gitErrMsg("clone", code)) }
  }
  // Checkout the exact commit.
  val coArgs: List[String] = newList()
  coArgs.add("-C")
  coArgs.add(targetDir)
  coArgs.add("checkout")
  coArgs.add(sha)
  match runGit(coArgs) {
    case Err(e)   -> Err(error = "git checkout failed: " + IOError.message(e))
    case Ok(code) ->
      if code != 0 { Err(error = gitErrMsg("checkout", code)) }
      else         { Ok(value = ()) }
  }
}

// Clone a branch: shallow clone with `--branch <name> --depth 1`.
func cloneBranch(url: in String, branchName: in String, targetDir: in String): Result[Unit, String] {
  val args: List[String] = newList()
  args.add("clone")
  args.add("--branch")
  args.add(branchName)
  args.add("--depth")
  args.add("1")
  args.add(url)
  args.add(targetDir)
  match runGit(args) {
    case Err(e)   -> Err(error = "git clone failed: " + IOError.message(e))
    case Ok(code) ->
      if code != 0 { Err(error = gitErrMsg("clone", code)) }
      else         { Ok(value = ()) }
  }
}

// Run `git -C <dir> rev-parse HEAD` and return the trimmed SHA.
// Returns an empty string if the command fails (e.g. shallow clone edge cases).
func revParseHead(dir: in String): String {
  val args: List[String] = newList()
  args.add("-C")
  args.add(dir)
  args.add("rev-parse")
  args.add("HEAD")
  val sha = Str.trim(PC.runCapture("git", args, ""))
  if sha.length == 0 {
    Console.error("warning: git rev-parse HEAD returned empty in " + dir + "; lock file will record an empty SHA")
  }
  sha
}

// Pull the latest changes in an already-cloned branch directory.
func pullBranch(targetDir: in String): Result[Unit, String] {
  val args: List[String] = newList()
  args.add("-C")
  args.add(targetDir)
  args.add("pull")
  match runGit(args) {
    case Err(e)   -> Err(error = "git pull failed: " + IOError.message(e))
    case Ok(code) ->
      if code != 0 { Err(error = gitErrMsg("pull", code)) }
      else         { Ok(value = ()) }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// §5. Public API
// ─────────────────────────────────────────────────────────────────────────────

/// Return a human-readable label for a `GitRef` value.
///
/// Used in diagnostic messages and lock-file annotations.
pub func gitRefLabel(ref: in GitRef): String {
  match ref {
    case Tag(name)    -> "tag:" + name
    case Rev(sha)     -> "rev:" + sha
    case Branch(name) -> "branch:" + name
  }
}

/// Resolve a git dependency by cloning (or updating) into the local cache.
///
/// Steps:
///   1. Compute the per-URL cache root and the per-ref target directory.
///   2. Ensure the cache root exists.
///   3. Clone if the target directory does not yet contain a `.git` marker,
///      or pull if the ref is a `Branch` (mutable) and it is already cached.
///   4. Optionally descend into `subdir` and verify it exists.
///   5. Return `Ok(GitDepResult)` or `Err(message)`.
pub func resolve(url: in String, ref: in GitRef, subdir: in Option[String]): Result[GitDepResult, String] {
  // Derive cache paths.
  val cacheRoot  = Path.join(cacheDir(), urlToHash(url))
  val targetDir  = Path.join(cacheRoot, refDirName(ref))

  // Ensure the cache root directory exists.
  match Dir.createRecursive(cacheRoot) {
    case Ok(_)  -> ()
    case Err(e) ->
      return Err(error = "cannot create cache directory '" + cacheRoot + "': " + IOError.message(e))
  }

  // Clone or refresh depending on ref type and whether the clone exists.
  val alreadyCloned = isGitClone(targetDir)
  var resolvedRev = ""

  match ref {
    case Tag(name) -> {
      if not alreadyCloned {
        match cloneTag(url, name, targetDir) {
          case Err(msg) -> return Err(error = msg)
          case Ok(_)    -> ()
        }
      }
      // Tag refs are immutable: once cloned, no refresh needed.
      // Capture the pinned SHA for the lock file.
      resolvedRev = revParseHead(targetDir)
    }
    case Rev(sha) -> {
      if not alreadyCloned {
        match cloneRev(url, sha, targetDir) {
          case Err(msg) -> return Err(error = msg)
          case Ok(_)    -> ()
        }
      }
      // Rev refs are immutable: the SHA is already known from the manifest.
      resolvedRev = sha
    }
    case Branch(name) -> {
      if not alreadyCloned {
        match cloneBranch(url, name, targetDir) {
          case Err(msg) -> return Err(error = msg)
          case Ok(_)    -> ()
        }
      } else {
        // Branch refs are mutable: pull to get the latest commit.
        match pullBranch(targetDir) {
          case Err(msg) -> return Err(error = msg)
          case Ok(_)    -> ()
        }
      }
      // Capture the current HEAD SHA so the lock file records a specific commit.
      resolvedRev = revParseHead(targetDir)
    }
  }

  // Verify the clone root exists after the operation.
  if not Dir.exists(targetDir) {
    return Err(error = "clone directory not found after git operation: " + targetDir)
  }

  // Optionally descend into a subdirectory.
  val resolvedDir = match subdir {
    case None    -> targetDir
    case Some(s) -> Path.join(targetDir, s)
  }

  if not Dir.exists(resolvedDir) {
    return Err(error = "subdir '" + resolvedDir + "' does not exist in cloned repository")
  }

  Ok(value = GitDepResult(localDir = resolvedDir, resolvedRev = resolvedRev))
}
