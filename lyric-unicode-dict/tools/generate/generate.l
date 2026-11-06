//! generate.l - Unicode.Dictionary.Generate: writes the word lists of `Unicode.Dictionary.Data`
//! (`src/dictionary_data.l`) from ICU's Thai, Lao, Khmer and Burmese dictionaries vendored in
//! `lyric-unicode-dict/dict/` (#8497).
//!
//!   lyric run --manifest lyric-unicode-dict/tools/generate/lyric.toml            rewrite the file
//!   lyric run --manifest lyric-unicode-dict/tools/generate/lyric.toml -- --check  fail when it differs
//!
//! Run it from the repository root or from `lyric-unicode-dict/`.  It reads each dictionary only
//! after checking it against the SHA-256 pinned below, so the lists always come from one known ICU
//! release; updating them means replacing the files in `dict/`, the release and the checksums here,
//! and running it.  It writes the whole of `dictionary_data.l`, in the layout that file's module
//! comment describes: for each dictionary, the code points its words use (its alphabet) and its words
//! sorted by code point, each code point written as the one ASCII character of its rank in the
//! alphabet, so the lists are plain ASCII and read the same on every target.
package Unicode.Dictionary.Generate

import Std.Core
import Std.Collections
import Std.String
import Std.File
import Std.Path
import Std.Hash
import Std.Buffer as Buf
import Std.Encoding.{codepointToString}
import Std.Console as Console
import Std.Environment as Environment
import Std.Errors.{IOError}

/// The ICU release the vendored dictionaries come from.
pub val icuRelease: String = "74.2"

// The longest string literal the lists are cut into, in characters: well inside the JVM's 65535-byte
// limit on a constant, and well under the 2^20 characters Unicode.Dictionary's word positions
// (`chunkStride`) allow for one chunk.
val maxChunk: Int = 16000

/// The vendored dictionaries with the SHA-256 of each, and the name of their tables in
/// `dictionary_data.l`.
pub func pinnedFiles(): List[String] {
  [
    "thaidict.txt 3166ABDE40C0F44AB91C28F5CE96D7D1472CB7882E1C0BDA0A72F8F69DBA4274 thai",
    "laodict.txt 3C876934A3FA81031D2333525EAFACA6A7C9F842E3B98F18C38880420AFB5D36 lao",
    "khmerdict.txt 87BEE2D17CD5148AA36957EB05409EEFC124DE8AD519B81B789298EF3E60B5D9 khmer",
    "burmesedict.txt 61D8ABC3D9102B2F9BF0C9F44DB0D7AB89B18172D8CD26832E4C83174BD8673B myanmar"
  ]
}

/// The ASCII character standing for the code point of rank `rank` in an alphabet: the printable
/// characters from `!` on, without `"` and `\`, so a list needs no escapes in a string literal.  The
/// mapping keeps the order of the ranks, so words sort the same in either form.
pub func alphabetChar(rank: in Int): Int {
  var c = 33 + rank
  if c >= 34 {
    c = c + 1
  }
  if c >= 92 {
    c = c + 1
  }
  c
}

/// The number of code points an alphabet may have.
pub val alphabetLimit: Int = 92

/// The directory holding `src/dictionary_data.l` and `dict/`: the current directory, or
/// `lyric-unicode-dict` below it.
pub func libraryRoot(): Result[String, String] {
  val here = Environment.currentDirectory()
  for candidate in [here, Path.join(here, "lyric-unicode-dict")] {
    if fileExists(Path.join(candidate, "src/dictionary.l")) and fileExists(Path.join(candidate, "dict/thaidict.txt")) {
      return Ok(value = candidate)
    }
  }
  Err(
    error = "run from the repository root or from lyric-unicode-dict/ (no src/dictionary.l and dict/ under " + here +
      ")"
  )
}

/// The text of `dict/<name>`, after checking its SHA-256.
pub func readPinned(root: in String, name: in String, expected: in String): Result[String, String] {
  val path = Path.join(root, Path.join("dict", name))
  val bytes = match readBytes(path) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
  val actual = sha256OfBytes(bytes)
  if toUpper(actual) != toUpper(expected) {
    return Err(
      error = path + " has SHA-256 " + actual + ", not that of ICU " + icuRelease + "'s file (" + expected +
        "); replace the file or update the pinned checksum and release together"
    )
  }
  match readText(path) {
    case Ok(t) -> Ok(value = t)
    case Err(e) -> Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
}

/// The words of an ICU dictionary source file: one per line, with `#` comment lines, blank lines and
/// a leading byte order mark skipped.  `Err` names the first line holding something other than a
/// word (a tab-separated value, or a space inside a word).
pub func wordsOf(name: in String, text: in String): Result[List[String], String] {
  val acc: List[String] = newList()
  var lineNo = 0
  for raw in split(text, "\n") {
    lineNo = lineNo + 1
    val cps = codePoints(raw)
    var first = 0
    var last = cps.length
    while first < last and (cps[first] == 0xFEFF or cps[first] == 32 or cps[first] == 9 or cps[first] == 13) {
      first = first + 1
    }
    while last > first and (cps[last - 1] == 32 or cps[last - 1] == 9 or cps[last - 1] == 13) {
      last = last - 1
    }
    if last > first and cps[first] != 35 {
      var word = ""
      var i = first
      while i < last {
        if cps[i] <= 32 {
          return Err(error = name + ":" + lineNo.toString() + ": expected one word on the line")
        }
        word = word + codepointToString(cps[i])
        i = i + 1
      }
      acc.add(word)
    }
  }
  Ok(value = acc)
}

func compareCodeUnits(a: String, b: String): Int {
  val n = if a.length < b.length { a.length } else { b.length }
  var i = 0
  while i < n {
    val d = codeUnitAt(a, i) - codeUnitAt(b, i)
    if d != 0 {
      return d
    }
    i = i + 1
  }
  a.length - b.length
}

// `xs` sorted by `compareCodeUnits`: a bottom-up merge sort.
func sortedByCodeUnits(xs: List[String]): List[String] {
  var from: List[String] = newList()
  for x in xs {
    from.add(x)
  }
  var width = 1
  while width < from.count {
    val into: List[String] = newList()
    var lo = 0
    while lo < from.count {
      val mid = if lo + width < from.count { lo + width } else { from.count }
      val hi = if lo + 2 * width < from.count { lo + 2 * width } else { from.count }
      var a = lo
      var b = mid
      while a < mid or b < hi {
        if b >= hi or (a < mid and compareCodeUnits(from[a], from[b]) <= 0) {
          into.add(from[a])
          a = a + 1
        } else {
          into.add(from[b])
          b = b + 1
        }
      }
      lo = hi
    }
    from = into
    width = width * 2
  }
  from
}

func hex4(v: Int): String {
  val digits = "0123456789ABCDEF"
  var r = ""
  var shift = 12
  while shift >= 0 {
    val d = (v / pow16(shift)) % 16
    r = r + substring(digits, d, 1)
    shift = shift - 4
  }
  r
}

func pow16(shift: Int): Int {
  var p = 1
  var s = 0
  while s < shift {
    p = p * 2
    s = s + 1
  }
  p
}

/// The table lines of one dictionary: its alphabet (each code point as 4 hex digits, in order), the
/// length of its longest word, and its sorted words, each followed by a space, cut into literals of
/// at most `maxChunk` characters at word ends.
pub func tablesOf(name: in String, table: in String, words: in List[String]): Result[List[String], String] {
  var rank = Buf.filled(65536, 0)
  for w in words {
    for cp in codePoints(w) {
      if cp > 0xFFFF {
        return Err(error = name + ": U+" + hex4(cp) + " is outside the Basic Multilingual Plane")
      }
      rank[cp] = 1
    }
  }
  val alphabet: List[Int] = newList()
  var cp = 0
  while cp < 65536 {
    if rank[cp] != 0 {
      alphabet.add(cp)
      rank[cp] = alphabet.count
    }
    cp = cp + 1
  }
  if alphabet.count > alphabetLimit {
    return Err(
      error = name + " uses " + alphabet.count.toString() + " code points; the encoding holds " +
        alphabetLimit.toString()
    )
  }
  val encoded: List[String] = newList()
  for w in words {
    var s = ""
    for c in codePoints(w) {
      s = s + codepointToString(alphabetChar(rank[c] - 1))
    }
    encoded.add(s)
  }
  val sorted = sortedByCodeUnits(encoded)
  val chunks: List[String] = newList()
  var current = ""
  var previous = ""
  var count = 0
  var longest = 0
  for w in sorted {
    if count == 0 or w != previous {
      if w.length > longest {
        longest = w.length
      }
      if current.length + w.length + 1 > maxChunk {
        chunks.add(current)
        current = ""
      }
      current = current + w + " "
      previous = w
      count = count + 1
    }
  }
  if count == 0 {
    // Unicode.Dictionary's search reads the first chunk of every list.
    return Err(error = name + " has no words")
  }
  chunks.add(current)
  var alphabetHex = ""
  for cp in alphabet {
    alphabetHex = alphabetHex + hex4(cp)
  }
  var listLine = "pub val " + table + "Words: slice[String] = ["
  var i = 0
  while i < chunks.count {
    listLine = listLine + (if i > 0 { ", " } else { "" }) + "\"" + chunks[i] + "\""
    i = i + 1
  }
  listLine = listLine + "]"
  val lines: List[String] = newList()
  lines.add("/// The " + alphabet.count.toString() + " code points of " + name + "'s " + count.toString() + " words.")
  lines.add("pub val " + table + "Alphabet: String = \"" + alphabetHex + "\"")
  lines.add("")
  lines.add("/// The code points in " + name + "'s longest word.")
  lines.add("pub val " + table + "LongestWord: Int = " + longest.toString())
  lines.add("")
  lines.add("/// The words of " + name + ", sorted.")
  lines.add(listLine)
  Ok(value = lines)
}

val header: List[String] = ["//! dictionary_data.l - Unicode.Dictionary.Data: the word lists of ICU's Thai, Lao, Khmer and Burmese", "//! dictionaries, vendored in `dict/` (#8497).  Written by `tools/generate`; never edit it by hand.", "//!", "//! Each dictionary has two tables.  `<script>Alphabet` holds the code points its words use, in order,", "//! as 4 hex digits each.  `<script>Words` holds its words sorted by code point, each followed by a", "//! space, cut into strings at word ends; a word's code points are written as the ASCII character of", "//! their rank in the alphabet (`!` for the first, then on up the printable characters, leaving out", "//! `\"` and `\\`), so the lists sort and compare the same in either form and read the same on every", "//! target.  CI runs the generator with `--check`, so the tables always match the pinned files.", "@pure", "package Unicode.Dictionary.Data", ""]

/// The whole text of `src/dictionary_data.l`.
pub func generate(root: in String): Result[String, String] {
  val lines: List[String] = newList()
  for line in header {
    lines.add(line)
  }
  for entry in pinnedFiles() {
    val parts = split(entry, " ")
    val text = match readPinned(root, parts[0], parts[1]) { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
    val words = match wordsOf(parts[0], text) { case Ok(w) -> w; case Err(e) -> return Err(error = e) }
    val tables = match tablesOf(parts[0], parts[2], words) { case Ok(l) -> l; case Err(e) -> return Err(error = e) }
    for l in tables {
      lines.add(l)
    }
    lines.add("")
  }
  Ok(value = joinList("\n", lines))
}

func main(): Int {
  val args = Environment.args()
  var check = false
  var i = 1
  while i < args.length {
    if args[i] == "--check" {
      check = true
    } else {
      Console.println("usage: generate [--check] (unknown argument `" + args[i] + "`)")
      return 2
    }
    i = i + 1
  }
  val root = match libraryRoot() { case Ok(r) -> r; case Err(e) -> { Console.println("error: " + e); return 1 } }
  val generated = match generate(root) { case Ok(t) -> t; case Err(e) -> { Console.println("error: " + e); return 1 } }
  val target = Path.join(root, "src/dictionary_data.l")
  if check {
    val existing = match readText(target) {
      case Ok(s) -> s
      case Err(e) -> {
        Console.println("error: cannot read " + target + ": " + IOError.message(e))
        return 1
      }
    }
    if existing != generated {
      Console.println(
        "error: " + target + " differs from the lists generated from ICU " + icuRelease +
          "'s dictionaries; run `lyric run --manifest lyric-unicode-dict/tools/generate/lyric.toml` and commit the result"
      )
      return 1
    }
    Console.println("ok: " + target + " holds the word lists of ICU " + icuRelease)
    return 0
  }
  match writeText(target, generated) {
    case Ok(_) -> {
      Console.println("wrote " + target)
      0
    }
    case Err(e) -> {
      Console.println("error: cannot write " + target + ": " + IOError.message(e))
      1
    }
  }
}
