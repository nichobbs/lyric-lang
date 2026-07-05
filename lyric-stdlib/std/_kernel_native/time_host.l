//! std/_kernel_native/time_host.l — native-target time boundary.
//!
//! The `--target native` twin of `_kernel/time_host.l`, selected by the
//! native source loader by basename.  Implements the exception-free
//! clock seams AND the full calendar surface (issue #4752, D-N-027):
//!
//!   Instant        = nanoseconds since the Unix epoch (UTC), Long
//!   Duration       = a nanosecond count, Long
//!   DateTimeOffset = an Instant already reckoned at UTC offset zero
//!                    (the only offset the shared Std.Time surface
//!                    ever uses)
//!
//! The int64-nanos range covers years ~1678..2262 — the same window
//! `java.time.Duration.toNanos()` lives in.  Calendar decomposition
//! uses the standard proleptic-Gregorian civil algorithms
//! (days_from_civil / civil_from_days, Howard Hinnant's formulation,
//! correct under truncating integer division for this whole window).
//! `hostAddMonths` clamps day-of-month like `DateTime.AddMonths` /
//! `java.time.plusMonths` (Jan 31 + 1 month -> Feb 28/29).
//!
//! `hostInstantToString` emits java.time-style ISO-8601 UTC
//! ("YYYY-MM-DDTHH:MM:SSZ", sub-second fraction only when non-zero,
//! trimmed to 3/6/9 digits); `hostParseInstantOpt` accepts exactly
//! that shape (optional fraction of 1..9 digits, trailing "Z") plus
//! field range validation — the strict end of the parse contract
//! Std.Time documents (.NET's TryParse stays lenient on its own
//! target).  Dates outside the i64-nanos window (edges 1677-09-21 and
//! 2262-04-11) are rejected via an exact reconstruction check rather
//! than silently wrapping, so every constructible Instant — including
//! the boundary ones — round-trips (#5219); calendar/duration
//! arithmetic that would leave the window panics (#5213) — the native
//! analog of the managed twins' out-of-range exceptions.
//!
//! Fractional Duration constructors round to whole nanoseconds via
//! llround(3) (libm, already on the native link line), mirroring the
//! JVM twin's Math.round idiom.
//!
//! Internal: only Std.Time should import this.
@axiom("POSIX clocks, usleep(3), and llround(3) via lyric-rt/libm conform to their documented contracts; the civil-calendar helpers follow the proleptic Gregorian calendar")
package Std.TimeHost

import Std.Core

// ── Wire-level types ─────────────────────────────────────────────────
pub record Instant {
  epochNanos: Long
}

pub record Duration {
  nanos: Long
}

pub record DateTimeOffset {
  epochNanos: Long
}

// ── Externs ──────────────────────────────────────────────────────────
extern func rtEpochMillis(): Long = "lyric_epoch_millis"

extern func rtEpochNanos(): Long = "lyric_epoch_nanos"

extern func rtMonotonicNanos(): Long = "lyric_monotonic_nanos"

extern func cUsleep(us: Int): Int = "usleep"

extern func cLlround(x: Double): Long = "llround"

// ── Integer helpers (Lyric / and % truncate toward zero) ─────────────
func nanosPerDay(): Long {
  86400000000000i64
}

func floorDivLong(a: in Long, b: in Long): Long {
  val q = a / b
  if a % b != 0i64 and ((a < 0i64) != (b < 0i64)) {
    q - 1i64
  } else {
    q
  }
}

// ── Civil calendar (proleptic Gregorian) ─────────────────────────────
record CivilDate {
  year: Int
  month: Int
  day: Int
}

func isLeapYear(y: in Int): Bool {
  (y % 4 == 0 and y % 100 != 0) or y % 400 == 0
}

func daysInMonth(y: in Int, m: in Int): Int {
  if m == 2 {
    if isLeapYear(y) {
      29
    } else {
      28
    }
  } else if m == 4 or m == 6 or m == 9 or m == 11 {
    30
  } else {
    31
  }
}

// Days since 1970-01-01 for a civil date (Hinnant days_from_civil).
func daysFromCivil(yIn: in Int, m: in Int, d: in Int): Long {
  var y = yIn
  if m <= 2 {
    y = y - 1
  }
  val era = (if y >= 0 { y } else { y - 399 }) / 400
  val yoe = y - era * 400
  val mp = if m > 2 { m - 3 } else { m + 9 }
  val doy = (153 * mp + 2) / 5 + d - 1
  val doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
  era.toLong() * 146097i64 + doe.toLong() - 719468i64
}

// Civil date for a days-since-1970 count (Hinnant civil_from_days).
func civilFromDays(zIn: in Long): CivilDate {
  val z = zIn + 719468i64
  val era = (if z >= 0i64 { z } else { z - 146096i64 }) / 146097i64
  val doe = (z - era * 146097i64).toInt()
  val yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
  val doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
  val mp = (5 * doy + 2) / 153
  val d = doy - (153 * mp + 2) / 5 + 1
  val m = if mp < 10 { mp + 3 } else { mp - 9 }
  var y = yoe + era.toInt() * 400
  if m <= 2 {
    y = y + 1
  }
  CivilDate(year = y, month = m, day = d)
}

// Coarse year bounds of the i64-nanos window (edge dates 1677-09-21
// and 2262-04-11).  The filter using these must admit the edge years
// themselves (#5219); the exact reconstruction check at each call
// site catches edge-year dates past the window.  Functions rather
// than module-level `val`s — stdlib module constants are unproven.
func windowYearMin(): Int {
  1677
}

func windowYearMax(): Int {
  2262
}

// ── Construction ─────────────────────────────────────────────────────
pub func hostNow(): Instant {
  Instant(epochNanos = rtEpochNanos())
}

pub func hostZeroDuration(): Duration {
  Duration(nanos = 0i64)
}

// ── Duration constructors (fractional units -> whole nanos) ─────────
// llround(3) on a value outside the long long range (or NaN) is
// C-standard undefined behavior (#5221), so bound the scaled Double
// first.  2^63 is exactly representable in Double; anything strictly
// below it (the largest such Double is 9223372036854774784) rounds to
// an in-range i64, and -2^63 itself is i64's minimum.  NaN fails both
// comparisons and panics too.
func nanosFromScaled(x: in Double, what: in String): Long {
  if not (x < 9223372036854775808.0 and x >= 0.0 - 9223372036854775808.0) {
    panic("Std.Time: " + what + " duration overflows the native 64-bit nanosecond range (magnitude ~292 years)")
  }
  cLlround(x)
}

pub func hostMillis(n: in Double): Duration {
  Duration(nanos = nanosFromScaled(n * 1000000.0, "millis"))
}

pub func hostSeconds(n: in Double): Duration {
  Duration(nanos = nanosFromScaled(n * 1000000000.0, "seconds"))
}

pub func hostMinutes(n: in Double): Duration {
  Duration(nanos = nanosFromScaled(n * 60000000000.0, "minutes"))
}

pub func hostHours(n: in Double): Duration {
  Duration(nanos = nanosFromScaled(n * 3600000000000.0, "hours"))
}

pub func hostDays(n: in Double): Duration {
  Duration(nanos = nanosFromScaled(n * 86400000000000.0, "days"))
}

// ── Duration arithmetic on Instant ───────────────────────────────────
// Overflow-checked i64 add/sub (#5216): the same wrap-detection
// pattern hostPlus uses, shared by every arithmetic seam below.
func checkedAddNanos(a: in Long, b: in Long, what: in String): Long {
  val sum = a + b
  if b > 0i64 and sum < a {
    panic("Std.Time: " + what + " overflowed the native 64-bit nanosecond range")
  }
  if b < 0i64 and sum > a {
    panic("Std.Time: " + what + " overflowed the native 64-bit nanosecond range")
  }
  sum
}

func checkedSubNanos(a: in Long, b: in Long, what: in String): Long {
  val diff = a - b
  if b > 0i64 and diff > a {
    panic("Std.Time: " + what + " overflowed the native 64-bit nanosecond range")
  }
  if b < 0i64 and diff < a {
    panic("Std.Time: " + what + " overflowed the native 64-bit nanosecond range")
  }
  diff
}

pub func hostSince(later: in Instant, earlier: in Instant): Duration {
  Duration(nanos = checkedSubNanos(later.epochNanos, earlier.epochNanos, "since"))
}

// Each target enforces ITS OWN representable range: .NET throws at
// its year-1..9999 bounds, java.time's far larger range simply
// accepts deltas that exceed ours (#5232), and native panics at the
// i64-nanos window (#5213, #5216).  What no target may do is wrap
// silently — that would produce a valid-looking Instant from the
// wrong century.
pub func hostPlus(t: in Instant, d: in Duration): Instant {
  Instant(epochNanos = checkedAddNanos(t.epochNanos, d.nanos, "plus"))
}

// ── Inspection ───────────────────────────────────────────────────────
pub func hostTotalMillis(d: in Duration): Double {
  d.nanos.toDouble() / 1000000.0
}

pub func hostTotalSeconds(d: in Duration): Double {
  d.nanos.toDouble() / 1000000000.0
}

// ── Calendar arithmetic ──────────────────────────────────────────────
// Decompose, shift the month index, clamp day-of-month to the target
// month's length (DateTime.AddMonths / java.time.plusMonths
// semantics), recompose; the time-of-day rides along unchanged.
//
// The whole month pipeline runs in Long (#5217, #5218): an extreme
// `Int` delta would wrap the Int32 index before the range check could
// see it, and a wrapped index can land back inside the valid window
// (e.g. n = 357913941 years pre-multiplied in Int32 wraps to exactly
// -4 months — a valid-looking wrong Instant).  Both entry points
// widen to Long BEFORE any multiplication.
func addMonthsLong(t: in Instant, n: in Long): Instant {
  val days = floorDivLong(t.epochNanos, nanosPerDay())
  val nanoOfDay = t.epochNanos - days * nanosPerDay()
  val c = civilFromDays(days)
  val m0 = c.year.toLong() * 12i64 + (c.month - 1).toLong() + n
  val y64 = if m0 >= 0i64 { m0 / 12i64 } else { (m0 - 11i64) / 12i64 }
  // Native panics at its own i64-nanos window (#5213) — recomposing a
  // year outside it would silently wrap into the wrong century.  (.NET
  // throws at ITS year-1..9999 bounds; java.time's far larger range
  // accepts deltas that exceed ours, #5232 — range enforcement is
  // per-target, never silent.)  The coarse filter admits the window's
  // edge years (#5219 — a no-op addMonths on a boundary Instant must
  // succeed); the exact reconstruction check below catches edge-year
  // dates past the window.
  if y64 < windowYearMin().toLong() or y64 > windowYearMax().toLong() {
    panic("Std.Time: addMonths/addYears result falls outside the native Instant range (1677-09-21..2262-04-11)")
  }
  val y = y64.toInt()
  val m = (m0 - y64 * 12i64 + 1i64).toInt()
  var d = c.day
  val dim = daysInMonth(y, m)
  if d > dim {
    d = dim
  }
  val newDays = daysFromCivil(y, m, d)
  val total = newDays * nanosPerDay() + nanoOfDay
  if floorDivLong(total, nanosPerDay()) != newDays {
    panic("Std.Time: addMonths/addYears result falls outside the native Instant range (1677-09-21..2262-04-11)")
  }
  Instant(epochNanos = total)
}

pub func hostAddMonths(t: in Instant, n: in Int): Instant {
  addMonthsLong(t, n.toLong())
}

pub func hostAddYears(t: in Instant, n: in Int): Instant {
  // Widen before the *12: |Int32| * 12 fits Long with room to spare,
  // so the year->month conversion itself can never wrap (#5218).
  addMonthsLong(t, n.toLong() * 12i64)
}

pub func hostAddDays(t: in Instant, n: in Double): Instant {
  hostPlus(t, hostDays(n))
}

// ── Epoch conversions ────────────────────────────────────────────────
// The multiply into nanos silently wraps for inputs past the window
// (#5216) — e.g. a year-2300 millisecond timestamp — so bound the
// input against Long.MAX / scale before scaling.  The managed twins
// have far larger representable ranges; native's honest answer for a
// value it cannot hold is a panic, not a wrong-century Instant.
pub func hostDtoFromEpochMillis(n: in Long): DateTimeOffset {
  if n > 9223372036854i64 or n < 0i64 - 9223372036854i64 {
    panic("Std.Time: epoch-milliseconds value outside the native nanosecond range (years ~1678..2262)")
  }
  DateTimeOffset(epochNanos = n * 1000000i64)
}

pub func hostDtoFromEpochSeconds(n: in Long): DateTimeOffset {
  if n > 9223372036i64 or n < 0i64 - 9223372036i64 {
    panic("Std.Time: epoch-seconds value outside the native nanosecond range (years ~1678..2262)")
  }
  DateTimeOffset(epochNanos = n * 1000000000i64)
}

pub func hostDtoUtcDateTime(d: in DateTimeOffset): Instant {
  Instant(epochNanos = d.epochNanos)
}

// ── Comparison ───────────────────────────────────────────────────────
pub func hostInstantBefore(a: in Instant, b: in Instant): Bool {
  a.epochNanos < b.epochNanos
}

pub func hostInstantAfter(a: in Instant, b: in Instant): Bool {
  a.epochNanos > b.epochNanos
}

pub func hostInstantEquals(a: in Instant, b: in Instant): Bool {
  a.epochNanos == b.epochNanos
}

pub func hostDurationLess(a: in Duration, b: in Duration): Bool {
  a.nanos < b.nanos
}

pub func hostDurationGreater(a: in Duration, b: in Duration): Bool {
  a.nanos > b.nanos
}

pub func hostAddDurations(a: in Duration, b: in Duration): Duration {
  Duration(nanos = checkedAddNanos(a.nanos, b.nanos, "duration addition"))
}

pub func hostSubDurations(a: in Duration, b: in Duration): Duration {
  Duration(nanos = checkedSubNanos(a.nanos, b.nanos, "duration subtraction"))
}

// ── ISO-8601 formatting ──────────────────────────────────────────────
func pad2(n: in Int): String {
  if n < 10 {
    "0" + n.toString()
  } else {
    n.toString()
  }
}

func pad4(n: in Int): String {
  if n >= 1000 {
    n.toString()
  } else if n >= 100 {
    "0" + n.toString()
  } else if n >= 10 {
    "00" + n.toString()
  } else {
    "000" + n.toString()
  }
}

// Left-pad `n` (0 <= n < 10^width) with zeros to exactly `width` digits.
func padFrac(n: in Long, width: in Int): String {
  var s = n.toString()
  while s.length < width {
    s = "0" + s
  }
  s
}

pub func hostInstantToString(value: in Instant): String {
  val days = floorDivLong(value.epochNanos, nanosPerDay())
  val nanoOfDay = value.epochNanos - days * nanosPerDay()
  val c = civilFromDays(days)
  val secOfDay = (nanoOfDay / 1000000000i64).toInt()
  val frac = nanoOfDay % 1000000000i64
  var s = pad4(c.year) + "-" + pad2(c.month) + "-" + pad2(c.day) + "T" + pad2(secOfDay / 3600) + ":" +
    pad2(secOfDay / 60 % 60) +
    ":" +
    pad2(secOfDay % 60)
  if frac != 0i64 {
    // java.time style: the shortest of 3/6/9 digits that loses nothing.
    if frac % 1000000i64 == 0i64 {
      s = s + "." + padFrac(frac / 1000000i64, 3)
    } else if frac % 1000i64 == 0i64 {
      s = s + "." + padFrac(frac / 1000i64, 6)
    } else {
      s = s + "." + padFrac(frac, 9)
    }
  }
  s + "Z"
}

// ── ISO-8601 parsing (strict) ────────────────────────────────────────
// Digit value of a single-character string, or -1.
func digitVal(c: in String): Int {
  val digits = "0123456789"
  var i = 0
  while i < 10 {
    if digits.substring(i, 1) == c {
      return i
    }
    i = i + 1
  }
  0 - 1
}

// Parse exactly `count` digits of `s` starting at `at`, or -1.
func digitsAt(s: in String, at: in Int, count: in Int): Int {
  var acc = 0
  var i = 0
  while i < count {
    val v = digitVal(s.substring(at + i, 1))
    if v < 0 {
      return 0 - 1
    }
    acc = acc * 10 + v
    i = i + 1
  }
  acc
}

pub func hostParseInstantOpt(s: in String): Option[Instant] {
  // Minimum shape: "YYYY-MM-DDTHH:MM:SSZ" (20 chars); optional
  // ".d{1..9}" before the "Z".
  if s.length < 20 {
    return None
  }
  if s.substring(s.length - 1, 1) != "Z" {
    return None
  }
  if s.substring(4, 1) != "-" or s.substring(7, 1) != "-" or s.substring(10, 1) != "T" or s.substring(13, 1) != ":" or s.substring(16, 1) != ":" {
    return None
  }
  val year = digitsAt(s, 0, 4)
  val month = digitsAt(s, 5, 2)
  val day = digitsAt(s, 8, 2)
  val hour = digitsAt(s, 11, 2)
  val minute = digitsAt(s, 14, 2)
  val second = digitsAt(s, 17, 2)
  if year < 0 or month < 0 or day < 0 or hour < 0 or minute < 0 or second < 0 {
    return None
  }
  // Coarse year pre-filter: any constructible Instant formats to a
  // year inside the window (#5219 — every toIsoString output must
  // parse back).  Dates inside the edge years but past the exact
  // edges are caught by the reconstruction check below.
  if year < windowYearMin() or year > windowYearMax() {
    return None
  }
  if month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month) {
    return None
  }
  if hour > 23 or minute > 59 or second > 59 {
    return None
  }
  var frac = 0i64
  if s.length > 20 {
    if s.substring(19, 1) != "." {
      return None
    }
    val fracDigits = s.length - 21
    if fracDigits < 1 or fracDigits > 9 {
      return None
    }
    var i = 0
    while i < fracDigits {
      val v = digitVal(s.substring(20 + i, 1))
      if v < 0 {
        return None
      }
      frac = frac * 10i64 + v.toLong()
      i = i + 1
    }
    var scale = fracDigits
    while scale < 9 {
      frac = frac * 10i64
      scale = scale + 1
    }
  }
  val days = daysFromCivil(year, month, day)
  val secOfDay = (hour * 3600 + minute * 60 + second).toLong()
  val total = days * nanosPerDay() + secOfDay * 1000000000i64 + frac
  // Exact window check (#5219): a date past the i64-nanos edges
  // (before 1677-09-21T00:12:43.145224192Z or after
  // 2262-04-11T23:47:16.854775807Z) wraps `total`; reconstructing the
  // day index from the wrapped value lands on a different day, so the
  // comparison rejects exactly the unrepresentable dates while every
  // constructible boundary Instant round-trips.
  if floorDivLong(total, nanosPerDay()) != days {
    return None
  }
  Some(value = Instant(epochNanos = total))
}

// ── Epoch/monotonic seams and synchronous sleep ──────────────────────
pub func hostEpochMillis(): Long {
  rtEpochMillis()
}

pub func hostMonotonicNanos(): Long {
  rtMonotonicNanos()
}

pub func hostSleepMillis(ms: in Int): Unit {
  // usleep(3) rejects arguments of one second or more on some
  // platforms, so sleep in 500 ms slices.
  var remaining = ms
  while remaining > 0 {
    var chunk = remaining
    if chunk > 500 {
      chunk = 500
    }
    val _ignored = cUsleep(chunk * 1000)
    remaining = remaining - chunk
  }
}
