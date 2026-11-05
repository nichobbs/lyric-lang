//! generate.l - Unicode.Generate: writes the property tables of `Unicode.Data` (`src/unicode_data.l`)
//! from the Unicode Character Database files vendored in `lyric-unicode/ucd/` (#8497).
//!
//!   lyric run --manifest lyric-unicode/tools/generate/lyric.toml            rewrite the tables
//!   lyric run --manifest lyric-unicode/tools/generate/lyric.toml -- --check  fail when they differ
//!
//! Run it from the repository root or from `lyric-unicode/`.  It reads the UCD files only after
//! checking each against the SHA-256 pinned below, so the tables always come from one known
//! Unicode version; updating Unicode means replacing the files in `ucd/`, the version and the
//! checksums here, and running it.  It rewrites the four `val ...: slice[String]` lines of
//! `unicode_data.l` and nothing else, in the record layout that file's module comment describes:
//!
//!   bidiRuns       Bidi_Class (DerivedBidiClass.txt, with its @missing defaults), numbered as
//!                  `Unicode.Bidi` numbers the classes
//!   lineBreakRuns  Line_Break (LineBreak.txt) numbered as `Unicode.LineBreak` numbers the classes,
//!                  plus East_Asian_Width F, W or H (EastAsianWidth.txt), Extended_Pictographic and
//!                  unassigned (emoji-data.txt, DerivedGeneralCategory.txt), and the general
//!                  categories Pi, Pf, and Mn or Mc
//!   mirrorPairs    Bidi_Mirroring_Glyph (BidiMirroring.txt)
//!   bracketPairs   Bidi_Paired_Bracket and Bidi_Paired_Bracket_Type (BidiBrackets.txt)
package Unicode.Generate

import Std.Core
import Std.Collections
import Std.String
import Std.File
import Std.Path
import Std.Hash
import Std.Buffer as Buf
import Std.Console as Console
import Std.Environment as Environment
import Std.Errors.{IOError}

/// The Unicode version of the vendored files.
pub val unicodeVersion: String = "16.0.0"

val codeSpace: Int = 1114112

val recordsPerChunk: Int = 64

/// The UCD files the tables are made from, with the SHA-256 of each.
pub func pinnedFiles(): List[String] {
  [
    "DerivedBidiClass.txt 71ED943A49C58568D8D92E80ECC2BA2F06E62AEE9C8EBB0E6E8BD2C3ED8B180E",
    "LineBreak.txt E97E4259D0D20FAB150B9C7B4B28ABFAE5CD78CA97E7F4AC6ED20D685D5F4A7C",
    "EastAsianWidth.txt 43ADC76C0686A42CB370764EB8CFE2B2A45B10B855E5572A2DB4A0EECCE15D5B",
    "DerivedGeneralCategory.txt 7676AB755A41EF82108460238569E60AD65C191DDAFE61B36C6765EC1353F293",
    "emoji-data.txt F1365A5173EEE18E1F98B240CDC492E84A25F1CE7E0C9D1094EB29C41A22696A",
    "BidiMirroring.txt D7AFDADD1BBD66F5A663AC0E8F7958F18FD9491FC0BC59EC5877CB82DB71DB7D",
    "BidiBrackets.txt B8F32554C6F658821FB0EE742D21C5B1F2086B9BF13071FED04894B022F93D67"
  ]
}

// Bidi_Class values, short and long names, in the order `Unicode.Bidi` numbers them.
val bidiShortNames: List[String] = ["L", "R", "EN", "ES", "ET", "AN", "CS", "B", "S", "WS", "ON", "LRE", "LRO", "AL", "RLE", "RLO", "PDF", "NSM", "BN", "FSI", "LRI", "RLI", "PDI"]

val bidiLongNames: List[String] = ["Left_To_Right", "Right_To_Left", "European_Number", "European_Separator", "European_Terminator", "Arabic_Number", "Common_Separator", "Paragraph_Separator", "Segment_Separator", "White_Space", "Other_Neutral", "Left_To_Right_Embedding", "Left_To_Right_Override", "Arabic_Letter", "Right_To_Left_Embedding", "Right_To_Left_Override", "Pop_Directional_Format", "Nonspacing_Mark", "Boundary_Neutral", "First_Strong_Isolate", "Left_To_Right_Isolate", "Right_To_Left_Isolate", "Pop_Directional_Isolate"]

// Line_Break values in the order `Unicode.LineBreak` numbers them.
val lineBreakNames: List[String] = ["XX", "AI", "AL", "B2", "BA", "BB", "BK", "CB", "CL", "CM", "CR", "EX", "GL", "HY", "ID", "IN", "IS", "LF", "NS", "NU", "OP", "PO", "PR", "QU", "SA", "SG", "SP", "SY", "ZW", "NL", "WJ", "H2", "H3", "JL", "JT", "JV", "CP", "CJ", "HL", "RI", "EB", "EM", "ZWJ", "AK", "AP", "AS", "VF", "VI"]

val flagWide: Int = 64

val flagPictographicUnassigned: Int = 128

val flagInitialQuote: Int = 256

val flagFinalQuote: Int = 512

val flagMark: Int = 1024

// General categories the tables need, as the generator numbers them.
val gcOther: Int = 0

val gcPi: Int = 1

val gcPf: Int = 2

val gcMark: Int = 3

val gcUnassigned: Int = 4

/// The directory holding `src/unicode_data.l` and `ucd/`: the current directory, or `lyric-unicode`
/// below it.
pub func libraryRoot(): Result[String, String] {
  val here = Environment.currentDirectory()
  for candidate in [here, Path.join(here, "lyric-unicode")] {
    if fileExists(Path.join(candidate, "src/unicode_data.l")) and fileExists(Path.join(candidate, "ucd/LineBreak.txt")) {
      return Ok(value = candidate)
    }
  }
  Err(error = "run from the repository root or from lyric-unicode/ (no src/unicode_data.l and ucd/ under " + here + ")")
}

/// The text of `ucd/<name>`, after checking its SHA-256.
pub func readPinned(root: in String, name: in String): Result[String, String] {
  var expected = ""
  for entry in pinnedFiles() {
    val parts = split(entry, " ")
    if parts[0] == name {
      expected = parts[1]
    }
  }
  if expected.length == 0 {
    return Err(error = name + " is not one of the pinned UCD files")
  }
  val path = Path.join(root, Path.join("ucd", name))
  val bytes = match readBytes(path) {
    case Ok(b) -> b
    case Err(e) -> return Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
  val actual = sha256OfBytes(bytes)
  if actual != expected {
    return Err(
      error = path + " has SHA-256 " + actual + ", not that of Unicode " + unicodeVersion + "'s file (" + expected +
        "); replace the file or update the pinned checksum and version together"
    )
  }
  match readText(path) {
    case Ok(t) -> Ok(value = t)
    case Err(e) -> Err(error = "cannot read " + path + ": " + IOError.message(e))
  }
}

func hexValue(s: String): Int {
  var v = 0
  var i = 0
  while i < s.length {
    val c = codeUnitAt(s, i)
    v = v * 16 + (if c >= 97 { c - 87 } else if c >= 65 { c - 55 } else { c - 48 })
    i = i + 1
  }
  v
}

func isHex(s: String): Bool {
  if s.length == 0 {
    return false
  }
  var i = 0
  while i < s.length {
    val c = codeUnitAt(s, i)
    if not ((c >= 48 and c <= 57) or (c >= 65 and c <= 70) or (c >= 97 and c <= 102)) {
      return false
    }
    i = i + 1
  }
  true
}

/// One line of a UCD file: the code points `first ..= last` and the value of its second field.
pub record UcdEntry {
  first: Int
  last: Int
  value: String
}

/// The entries of a UCD property file: its `# @missing:` lines (the defaults, in file order) when
/// `missing` is set, else its data lines.  `Err` names the first line that is not well formed.
pub func entriesOf(name: in String, text: in String, missing: in Bool): Result[List[UcdEntry], String] {
  val acc: List[UcdEntry] = newList()
  var lineNo = 0
  for raw in split(text, "\n") {
    lineNo = lineNo + 1
    var body = ""
    if missing {
      val t = trim(raw)
      if startsWith(t, "# @missing:") {
        body = trim(substring(t, 11))
      }
    } else {
      val hash = indexOfRaw(raw, "#")
      body = trim(if hash >= 0 { substring(raw, 0, hash) } else { raw })
    }
    if body.length > 0 {
      val fields = split(body, ";")
      if fields.length < 2 {
        return Err(error = name + ":" + fromInt(lineNo) + ": expected `code points; value`")
      }
      val range = trim(fields[0])
      val dots = indexOfRaw(range, "..")
      val firstText = if dots >= 0 { substring(range, 0, dots) } else { range }
      val lastText = if dots >= 0 { substring(range, dots + 2) } else { range }
      if not isHex(firstText) or not isHex(lastText) {
        return Err(error = name + ":" + fromInt(lineNo) + ": `" + range + "` is not a code point or range")
      }
      val first = hexValue(firstText)
      val last = hexValue(lastText)
      if first > last or last >= codeSpace {
        return Err(error = name + ":" + fromInt(lineNo) + ": `" + range + "` is not a range of code points")
      }
      acc.add(UcdEntry(first = first, last = last, value = trim(fields[1])))
    }
  }
  Ok(value = acc)
}

// The index of `name` in `names`, or -1.
func indexIn(names: List[String], name: String): Int {
  var i = 0
  while i < names.count {
    if names[i] == name {
      return i
    }
    i = i + 1
  }
  -1
}

// Fills `values` from a property file: its defaults first, then its data, each value mapped by
// `number` (which returns -1 for a value it does not know).
func fill(name: String, text: String, values: inout buffer[Int], number: (String) -> Int): Result[Unit, String] {
  for missing in [true, false] {
    val entries = match entriesOf(name, text, missing) { case Ok(e) -> e; case Err(e) -> return Err(error = e) }
    for e in entries {
      val v = number(e.value)
      if v < 0 {
        return Err(error = name + ": unknown value `" + e.value + "`")
      }
      var c = e.first
      while c <= e.last {
        values[c] = v
        c = c + 1
      }
    }
  }
  Ok(value = ())
}

func bidiNumber(value: String): Int {
  val short = indexIn(bidiShortNames, value)
  if short >= 0 {
    short
  } else {
    indexIn(bidiLongNames, value)
  }
}

func lineBreakNumber(value: String): Int {
  indexIn(lineBreakNames, value)
}

// 1 for East_Asian_Width F, W or H, else 0; every value the file uses is known.
func wideNumber(value: String): Int {
  if value == "F" or value == "W" or value == "H" {
    1
  } else if value == "N" or value == "Na" or value == "A" {
    0
  } else {
    -1
  }
}

func generalCategoryNumber(value: String): Int {
  if value == "Pi" {
    gcPi
  } else if value == "Pf" {
    gcPf
  } else if value == "Mn" or value == "Mc" {
    gcMark
  } else if value == "Cn" {
    gcUnassigned
  } else if value.length == 2 {
    gcOther
  } else {
    -1
  }
}

func hexDigits(v: Int, width: Int): String {
  val digits = "0123456789ABCDEF"
  var r = ""
  var n = v
  var i = 0
  while i < width {
    r = substring(digits, n % 16, 1) + r
    n = n / 16
    i = i + 1
  }
  r
}

// A table as the source line `val <name>: slice[String] = [...]`: its records cut into strings of
// `recordsPerChunk`.
func tableLine(name: String, records: List[String]): String {
  val sb = StringBuilder.new()
  sb.append("val " + name + ": slice[String] = [\"")
  var i = 0
  while i < records.count {
    if i > 0 and i % recordsPerChunk == 0 {
      sb.append("\", \"")
    }
    sb.append(records[i])
    i = i + 1
  }
  sb.append("\"]")
  sb.toString()
}

// A record at every code point where the value changes: 6 hex digits of code point, 3 of value.
func runRecords(values: buffer[Int]): List[String] {
  val acc: List[String] = newList()
  var prev = -1
  var c = 0
  while c < codeSpace {
    if values[c] != prev {
      acc.add(hexDigits(c, 6) + hexDigits(values[c], 3))
      prev = values[c]
    }
    c = c + 1
  }
  acc
}

/// The four table lines, keyed by table name, made from the UCD files under `root`.
pub func generateTables(root: in String): Result[Map[String, String], String] {
  val tables: Map[String, String] = newMap()
  // Bidi_Class.
  val bidiText = match readPinned(root, "DerivedBidiClass.txt") {
    case Ok(t) -> t
    case Err(e) -> return Err(error = e)
  }
  var bidi = Buf.filled(codeSpace, 0)
  match fill("DerivedBidiClass.txt", bidiText, bidi, bidiNumber) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  tables.add("bidiRuns", tableLine("bidiRuns", runRecords(bidi)))
  // Line_Break and the flags line breaking reads.
  val lbText = match readPinned(root, "LineBreak.txt") { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  var lb = Buf.filled(codeSpace, 0)
  match fill("LineBreak.txt", lbText, lb, lineBreakNumber) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  val eawText = match readPinned(root, "EastAsianWidth.txt") { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  var wide = Buf.filled(codeSpace, 0)
  match fill("EastAsianWidth.txt", eawText, wide, wideNumber) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  val gcText = match readPinned(root, "DerivedGeneralCategory.txt") {
    case Ok(t) -> t
    case Err(e) -> return Err(error = e)
  }
  var gc = Buf.filled(codeSpace, gcUnassigned)
  match fill("DerivedGeneralCategory.txt", gcText, gc, generalCategoryNumber) {
    case Ok(_) -> ()
    case Err(e) -> return Err(error = e)
  }
  val emojiText = match readPinned(root, "emoji-data.txt") { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  var pictographic = Buf.filled(codeSpace, 0)
  val emojiEntries = match entriesOf("emoji-data.txt", emojiText, false) {
    case Ok(e) -> e
    case Err(e) -> return Err(error = e)
  }
  for e in emojiEntries {
    if e.value == "Extended_Pictographic" {
      var c = e.first
      while c <= e.last {
        pictographic[c] = 1
        c = c + 1
      }
    }
  }
  var c = 0
  while c < codeSpace {
    var v = lb[c]
    if wide[c] == 1 {
      v = v + flagWide
    }
    if pictographic[c] == 1 and gc[c] == gcUnassigned {
      v = v + flagPictographicUnassigned
    }
    if gc[c] == gcPi {
      v = v + flagInitialQuote
    } else if gc[c] == gcPf {
      v = v + flagFinalQuote
    } else if gc[c] == gcMark {
      v = v + flagMark
    }
    lb[c] = v
    c = c + 1
  }
  tables.add("lineBreakRuns", tableLine("lineBreakRuns", runRecords(lb)))
  // Bidi_Mirroring_Glyph.
  val mirrorText = match readPinned(root, "BidiMirroring.txt") { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  val mirrors = match entriesOf("BidiMirroring.txt", mirrorText, false) {
    case Ok(e) -> e
    case Err(e) -> return Err(error = e)
  }
  val mirrorRecords: List[String] = newList()
  for e in mirrors {
    if e.first != e.last or not isHex(e.value) {
      return Err(error = "BidiMirroring.txt: `" + hexDigits(e.first, 4) + "` is not one code point and its mirror")
    }
    mirrorRecords.add(hexDigits(e.first, 6) + hexDigits(hexValue(e.value), 6))
  }
  tables.add("mirrorPairs", tableLine("mirrorPairs", sortedRecords(mirrorRecords)))
  // Bidi_Paired_Bracket and its type; the third field is o (opening) or c (closing).
  val bracketText = match readPinned(root, "BidiBrackets.txt") { case Ok(t) -> t; case Err(e) -> return Err(error = e) }
  val bracketRecords: List[String] = newList()
  var lineNo = 0
  for raw in split(bracketText, "\n") {
    lineNo = lineNo + 1
    val hash = indexOfRaw(raw, "#")
    val body = trim(if hash >= 0 { substring(raw, 0, hash) } else { raw })
    if body.length > 0 {
      val f = split(body, ";")
      val kind = if f.length == 3 { trim(f[2]) } else { "" }
      if f.length != 3 or not isHex(trim(f[0])) or not isHex(trim(f[1])) or (kind != "o" and kind != "c") {
        return Err(error = "BidiBrackets.txt:" + fromInt(lineNo) + ": expected `code point; pair; o or c`")
      }
      bracketRecords.add(
        hexDigits(hexValue(trim(f[0])), 6) + hexDigits(hexValue(trim(f[1])), 6) + (if kind == "o" { "1" } else { "2" })
      )
    }
  }
  tables.add("bracketPairs", tableLine("bracketPairs", sortedRecords(bracketRecords)))
  Ok(value = tables)
}

// Fixed-width upper-case hex records sort by code point as strings do.
func sortedRecords(records: List[String]): List[String] {
  val sorted: List[String] = newList()
  for r in records {
    var at = sorted.count
    while at > 0 and compare(sorted[at - 1], r) > 0 {
      at = at - 1
    }
    sorted.add(at, r)
  }
  sorted
}

/// `source` (the text of `unicode_data.l`) with its four table lines replaced by `tables`.
pub func withTables(source: in String, tables: in Map[String, String]): Result[String, String] {
  val lines = split(source, "\n")
  val result: List[String] = newList()
  var replaced = 0
  for line in lines {
    var next = line
    for name in ["bidiRuns", "lineBreakRuns", "mirrorPairs", "bracketPairs"] {
      if startsWith(line, "val " + name + ": slice[String] = ") {
        next = match mapGet(tables, name) { case Some(t) -> t; case None -> return Err(error = "no table " + name) }
        replaced = replaced + 1
      }
    }
    result.add(next)
  }
  if replaced != 4 {
    return Err(error = "src/unicode_data.l has " + fromInt(replaced) + " of its 4 table lines; expected each once")
  }
  Ok(value = joinList("\n", result))
}

func main(): Int {
  // The first argument is the program itself, on every target.
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
  val tables = match generateTables(root) {
    case Ok(t) -> t
    case Err(e) -> {
      Console.println("error: " + e)
      return 1
    }
  }
  val target = Path.join(root, "src/unicode_data.l")
  val source = match readText(target) {
    case Ok(s) -> s
    case Err(e) -> {
      Console.println("error: cannot read " + target + ": " + IOError.message(e))
      return 1
    }
  }
  val updated = match withTables(source, tables) {
    case Ok(u) -> u
    case Err(e) -> {
      Console.println("error: " + e)
      return 1
    }
  }
  if check {
    if updated != source {
      Console.println(
        "error: " + target + " differs from the tables generated from Unicode " + unicodeVersion +
          "; run `lyric run --manifest lyric-unicode/tools/generate/lyric.toml` and commit the result"
      )
      return 1
    }
    Console.println("ok: " + target + " holds the tables of Unicode " + unicodeVersion)
    return 0
  }
  if updated == source {
    Console.println("unchanged: " + target + " (Unicode " + unicodeVersion + ")")
    return 0
  }
  match writeText(target, updated) {
    case Ok(_) -> ()
    case Err(e) -> {
      Console.println("error: cannot write " + target + ": " + IOError.message(e))
      return 1
    }
  }
  Console.println("wrote " + target + " (Unicode " + unicodeVersion + ")")
  0
}
