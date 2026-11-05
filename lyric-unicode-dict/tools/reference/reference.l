//! reference.l - Unicode.Dictionary.Reference: writes `tests/conformance/DictionaryBreakTest.txt`, the
//! conformance suite of `Unicode.Dictionary`, from ICU 74.2's own line and word break iterators
//! (#8497, D414).
//!
//!   lyric build --target native --manifest lyric-unicode-dict/tools/reference/lyric.toml -o reference
//!   ./reference              rewrite the suite
//!   ./reference --check      fail when it differs from what ICU gives now
//!
//! Run it from the repository root or from `lyric-unicode-dict/`, on a machine with ICU 74.2's
//! libicuuc (pkg-config `icu-uc`; Ubuntu 24.04's `libicu-dev`).  It refuses any other ICU version,
//! since another release's engines or dictionaries give other answers.  CI does not run it: the suite
//! is checked in, and pinned by SHA-256 in the conformance runner, like Unicode's own suites.
//!
//! The text is made from the library's own word lists (`Unicode.Dictionary.Data`, which the generator
//! checks against ICU's dictionary files) by a fixed pseudo-random sequence, so the same suite comes
//! out every time: for each of Thai, Lao, Khmer and Myanmar, lines of dictionary words with words cut
//! short, unknown syllables, the script's own marks of repetition, elision and punctuation, digits,
//! spaces, Latin words and words of the other three scripts between them.
@io
package Unicode.Dictionary.Reference

import Std.Core
import Std.Collections
import Std.String
import Std.File
import Std.Path
import Std.Ffi as Ffi
import Std.Encoding.{codepointToString}
import Std.Console as Console
import Std.Environment as Environment
import Std.Errors.{IOError}
import Unicode.Dictionary.Data as Words

@library("icuuc")
@unsafe_ffi
extern func ubrk_open_74(kind: Int, locale: NativePtr[Byte], text: NativePtr[Byte], length: Int, status: NativePtr[Byte]): NativePtr[Byte] = "ubrk_open_74"

@library("icuuc")
@unsafe_ffi
extern func ubrk_first_74(bi: NativePtr[Byte]): Int = "ubrk_first_74"

@library("icuuc")
@unsafe_ffi
extern func ubrk_next_74(bi: NativePtr[Byte]): Int = "ubrk_next_74"

@library("icuuc")
@unsafe_ffi
extern func ubrk_close_74(bi: NativePtr[Byte]): Unit = "ubrk_close_74"

@library("icuuc")
@unsafe_ffi
extern func u_getVersion_74(version: NativePtr[Byte]): Unit = "u_getVersion_74"

val wordIterator: Int = 1

val lineIterator: Int = 2

/// The ICU release whose answers the suite records.
pub val icuRelease: String = "74.2"

val linesPerScript: Int = 1000

// ICU's version, as "major.minor".
@unsafe_ffi
func icuVersion(): String {
  val v = Ffi.allocate(4i64)
  u_getVersion_74(v)
  val r = nativeLoadByte(v, 0i64).toInt().toString() + "." + nativeLoadByte(v, 1i64).toInt().toString()
  Ffi.release(v)
  r
}

// The positions ICU's iterator of `kind` stops at in `cps`, which are all in the Basic Multilingual
// Plane (so UTF-16 offsets are code point offsets).
@unsafe_ffi
func icuBreaks(cps: slice[Int], kind: Int): Result[List[Int], String] {
  val n = cps.length
  val text = Ffi.allocate((2 * n + 2).toLong())
  var i = 0
  while i < n {
    nativeStoreByte(text, (2 * i).toLong(), cps[i].and(255).toByte())
    nativeStoreByte(text, (2 * i + 1).toLong(), cps[i].shr(8).toByte())
    i = i + 1
  }
  nativeStoreByte(text, (2 * n).toLong(), 0u8)
  nativeStoreByte(text, (2 * n + 1).toLong(), 0u8)
  val status = Ffi.allocate(4i64)
  var k = 0
  while k < 4 {
    nativeStoreByte(status, k.toLong(), 0u8)
    k = k + 1
  }
  val locale = Ffi.toCString("en")
  val bi = ubrk_open_74(kind, locale, text, n, status)
  val code = nativeLoadByte(status, 0i64).toInt()
  val result: List[Int] = newList()
  if code > 0 and code < 128 {
    Ffi.release(text)
    Ffi.release(status)
    Ffi.release(locale)
    return Err(error = "ubrk_open failed with UErrorCode " + code.toString())
  }
  var b = ubrk_first_74(bi)
  while b >= 0 {
    result.add(b)
    b = ubrk_next_74(bi)
  }
  ubrk_close_74(bi)
  Ffi.release(text)
  Ffi.release(status)
  Ffi.release(locale)
  Ok(value = result)
}

// A fixed pseudo-random sequence (a 31-bit linear congruential generator).
pub ref record Rng {
  var state: Long
}

func nextInt(r: Rng, bound: Int): Int {
  r.state = (r.state * 1103515245i64 + 12345i64) % 2147483648i64;
  ((r.state / 65536i64) % bound.toLong()).toInt()
}

func hexAt(s: String, at: Int): Int {
  var v = 0
  var i = 0
  while i < 4 {
    val c = codeUnitAt(s, at + i)
    v = v * 16 + (if c >= 65 { c - 55 } else { c - 48 })
    i = i + 1
  }
  v
}

func rankOf(c: Int): Int {
  var r = c - 33
  if c > 34 {
    r = r - 1
  }
  if c > 92 {
    r = r - 1
  }
  r
}

// The words of a list of `Unicode.Dictionary.Data`, as code points.
func decodedWords(alphabet: String, chunks: slice[String]): List[slice[Int]] {
  val words: List[slice[Int]] = newList()
  for chunk in chunks {
    var start = 0
    var i = 0
    while i < chunk.length {
      if codeUnitAt(chunk, i) == 32 {
        var w = ""
        var k = start
        while k < i {
          w = w + codepointToString(hexAt(alphabet, rankOf(codeUnitAt(chunk, k)) * 4))
          k = k + 1
        }
        words.add(codePoints(w))
        start = i + 1
      }
      i = i + 1
    }
  }
  words
}

func alphabetCps(alphabet: String): List[Int] {
  val cps: List[Int] = newList()
  var i = 0
  while i < alphabet.length {
    cps.add(hexAt(alphabet, i))
    i = i + 4
  }
  cps
}

// One script's material: its words, letters, and the characters it writes between words.
pub record Script {
  name: String
  words: List[slice[Int]]
  letters: List[Int]
  extras: List[Int]
}

func scripts(): List[Script] {
  [
    Script(
      name = "Thai",
      words = decodedWords(Words.thaiAlphabet, Words.thaiWords),
      letters = alphabetCps(Words.thaiAlphabet),
      extras = [0x0E46, 0x0E2F, 0x0E50, 0x0E51, 0x0E5A]
    ),
    Script(
      name = "Lao",
      words = decodedWords(Words.laoAlphabet, Words.laoWords),
      letters = alphabetCps(Words.laoAlphabet),
      extras = [0x0EC6, 0x0EAF, 0x0ED0, 0x0ED1]
    ),
    Script(
      name = "Khmer",
      words = decodedWords(Words.khmerAlphabet, Words.khmerWords),
      letters = alphabetCps(Words.khmerAlphabet),
      extras = [0x17D4, 0x17D5, 0x17D7, 0x17E0, 0x17E1]
    ),
    Script(
      name = "Myanmar",
      words = decodedWords(Words.myanmarAlphabet, Words.myanmarWords),
      letters = alphabetCps(Words.myanmarAlphabet),
      extras = [0x104A, 0x104B, 0x1040, 0x1041]
    )
  ]
}

val latinWords: List[String] = ["the", "word", "ICU", "Lyric", "text"]

// One line of text in script `own`, the others mixed in now and then.
func lineOf(r: Rng, all: List[Script], own: Int): List[Int] {
  val s = all[own]
  val cps: List[Int] = newList()
  val tokens = 3 + nextInt(r, 12)
  var t = 0
  while t < tokens {
    val pick = nextInt(r, 100)
    if pick < 66 {
      for c in s.words[nextInt(r, s.words.count)] {
        cps.add(c)
      }
    } else if pick < 74 {
      // A word cut short or with a letter dropped: text the dictionary does not know.
      val w = s.words[nextInt(r, s.words.count)]
      val drop = nextInt(r, w.length)
      var i = 0
      while i < w.length {
        if i != drop {
          cps.add(w[i])
        }
        i = i + 1
      }
    } else if pick < 80 {
      // An unknown syllable of random letters.
      var n = 2 + nextInt(r, 4)
      while n > 0 {
        cps.add(s.letters[nextInt(r, s.letters.count)])
        n = n - 1
      }
    } else if pick < 87 {
      cps.add(s.extras[nextInt(r, s.extras.count)])
    } else if pick < 93 {
      cps.add(32)
    } else if pick < 95 {
      for c in codePoints((nextInt(r, 2000)).toString()) {
        cps.add(c)
      }
    } else if pick < 97 {
      cps.add(32)
      for c in codePoints(latinWords[nextInt(r, latinWords.count)]) {
        cps.add(c)
      }
      cps.add(32)
    } else {
      val other = all[nextInt(r, all.count)]
      for c in other.words[nextInt(r, other.words.count)] {
        cps.add(c)
      }
    }
    t = t + 1
  }
  cps
}

func joined(xs: List[Int]): String {
  var r = ""
  var i = 0
  while i < xs.count {
    r = r + (if i > 0 { " " } else { "" }) + xs[i].toString()
    i = i + 1
  }
  r
}

val header: List[String] = ["# DictionaryBreakTest.txt - the conformance suite of Unicode.Dictionary (lyric-unicode-dict, D414).", "# Written by lyric-unicode-dict/tools/reference from ICU 74.2's line and word break iterators (locale", "# \"en\"), over text made from the word lists of Unicode.Dictionary.Data; never edit it by hand.", "#", "# Each line: the text; a tab; the positions ICU's line break iterator stops at; a tab; the positions", "# its word break iterator stops at.  Positions count code points and include 0 and the end of the text.", "#"]

/// The whole text of the suite.
@unsafe_ffi
pub func suite(): Result[String, String] {
  val all = scripts()
  val r = Rng(state = 20261105i64)
  val lines: List[String] = newList()
  for h in header {
    lines.add(h)
  }
  var own = 0
  while own < all.count {
    lines.add("# " + all[own].name)
    var n = 0
    while n < linesPerScript {
      var text = ""
      for c in lineOf(r, all, own) {
        if c > 0xFFFF or c == 9 or c == 10 {
          return Err(error = "the corpus holds U+" + c.toString() + ", which it must not")
        }
        text = text + codepointToString(c)
      }
      val cps = codePoints(text)
      val lb = match icuBreaks(cps, lineIterator) { case Ok(b) -> b; case Err(e) -> return Err(error = e) }
      val wb = match icuBreaks(cps, wordIterator) { case Ok(b) -> b; case Err(e) -> return Err(error = e) }
      lines.add(text + "\t" + joined(lb) + "\t" + joined(wb))
      n = n + 1
    }
    own = own + 1
  }
  Ok(value = joinList("\n", lines) + "\n")
}

/// The directory holding `tests/conformance/` of the library: the current directory, or
/// `lyric-unicode-dict` below it.
pub func libraryRoot(): Result[String, String] {
  val here = Environment.currentDirectory()
  for candidate in [here, Path.join(here, "lyric-unicode-dict")] {
    if fileExists(Path.join(candidate, "src/dictionary.l")) {
      return Ok(value = candidate)
    }
  }
  Err(error = "run from the repository root or from lyric-unicode-dict/ (no src/dictionary.l under " + here + ")")
}

@unsafe_ffi
func main(): Int {
  val args = Environment.args()
  var check = false
  var i = 1
  while i < args.length {
    if args[i] == "--check" {
      check = true
    } else {
      Console.println("usage: reference [--check] (unknown argument `" + args[i] + "`)")
      return 2
    }
    i = i + 1
  }
  val version = icuVersion()
  if version != icuRelease {
    Console.println("error: this is ICU " + version + "; the suite records ICU " + icuRelease + "'s answers")
    return 1
  }
  val root = match libraryRoot() { case Ok(r) -> r; case Err(e) -> { Console.println("error: " + e); return 1 } }
  val text = match suite() { case Ok(t) -> t; case Err(e) -> { Console.println("error: " + e); return 1 } }
  val target = Path.join(root, "tests/conformance/DictionaryBreakTest.txt")
  if check {
    val existing = match readText(target) {
      case Ok(s) -> s
      case Err(e) -> {
        Console.println("error: cannot read " + target + ": " + IOError.message(e))
        return 1
      }
    }
    if existing != text {
      Console.println("error: " + target + " differs from ICU " + icuRelease + "'s answers")
      return 1
    }
    Console.println("ok: " + target + " holds ICU " + icuRelease + "'s answers")
    return 0
  }
  match writeText(target, text) {
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
