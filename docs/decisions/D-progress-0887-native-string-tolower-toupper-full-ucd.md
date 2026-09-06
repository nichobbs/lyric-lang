# D-progress-887 — Native `String.toLower`/`.toUpper` widen to the full Unicode Character Database (#6779)

**Status:** shipped

**Context.** D-progress-831 (#6588) shipped native `.toLower()` as a
genuine Unicode simple case fold, but hand-scoped to five scripts (Basic
Latin, Latin-1 Supplement, Latin Extended-A, Greek, Cyrillic) — a
deliberate, disclosed scope limit (review finding #6778) rather than an
oversight, tracked here for widening. `.toUpper()` had no native
implementation at all. Embedding the complete Unicode Character
Database's `SimpleLowercaseMapping`/`SimpleUppercaseMapping` fields by
hand was never realistic — thousands of entries across dozens of
scripts — so the fix needed a generation step, not more hand-written
range checks.

**Fix.** `scripts/gen_unicode_case_tables.py` is a new, checked-in
offline generator (Python, per the issue's own suggested tooling
options) that parses Unicode 17.0.0's `UnicodeData.txt` — fetched from
unicode.org when regenerating, never at `lyric-rt` build time — and
extracts every codepoint's "simple lowercase mapping" (field 13) and
"simple uppercase mapping" (field 12). These are, by UnicodeData.txt's
own definition, always single-scalar and unconditional (unlike
`SpecialCasing.txt`'s multi-codepoint and locale-conditional entries),
matching this runtime's existing one-codepoint-in, one-codepoint-out
case-conversion model exactly — no filtering beyond what the file's own
simple-mapping columns already encode was needed. The generator emits
two sorted-by-codepoint C tables
(`lyric-rt/src/lyric_unicode_case_tables.inc`, checked into the repo:
~1488 lowercase and ~1505 uppercase entries), `#include`d directly into
`lyric_string.c`. `cp_to_lower`/`cp_to_upper` now do a binary search
against these tables instead of the old hand-written range checks
(which are deleted entirely — the generated table already reproduces
every one of their mappings, U+0130's İ->i special case included,
without needing a hand-coded carve-out: Unicode's own data already has
it right).

A real correctness fix rode along with the widening. The old five-script
table's mappings never grew a code point's UTF-8 byte length (only
U+0130 ever shrank it, 2 bytes to 1), so `lyric_string_to_lower`
allocated its output buffer at the input's exact byte length as a safe
upper bound, with a defensive panic if a future mapping ever violated
that invariant. The full UCD table breaks that invariant for real: 22
pairs GROW (e.g. U+023A Ⱥ, 2 bytes, lowercases to U+2C65 ⱥ, 3 bytes) and
38 pairs shrink more dramatically than U+0130 ever did (U+212A KELVIN
SIGN, 3 bytes, lowercases to plain ASCII "k", 1 byte). A single-pass
"allocate at input length" strategy is no longer safe in either
direction. `lyric_string_to_lower`/`lyric_string_to_upper` are
refactored into a shared `string_case_map(s, mapFn)` helper: a first
pass decodes every code point and measures its mapped UTF-8 length
without writing anything, summing the exact output size; the second
pass allocates exactly that size and writes it. No guess, no
panic-on-overflow guard needed — the old panic path is deleted along
with the table it protected.

**Verification.** New cases in `lyric-rt/test/lyric_rt_test.c`: Armenian
and Georgian round-trips (neither script existed in the old table at
all) — including the Georgian Mkhedruli-to-Mtavruli case pairing (a
Unicode 11.0+ addition, U+10D0 -> U+1C90), verified against
UnicodeData.txt directly rather than assumed, since the historical
Asomtavruli block (U+10A0) is NOT what the file's own simple-uppercase
field encodes for Mkhedruli letters; the U+023A/U+2C65 growing pair with
an upper/lower roundtrip back to the original 2-byte form; the U+212A
Kelvin-sign 3-byte-to-1-byte shrink; `.toUpper()` on ASCII, and a no-op
case on U+0130 (which has no further uppercase mapping — its own
uppercase is itself). Four new ASan-compiled end-to-end cases in
`llvm_codegen_self_test.l` mirror the same matrix through the real
`--target native` pipeline (basic `.toUpper()`, the Armenian/Georgian
widened-script roundtrip, and the U+023A growing-length case). All
existing `.toLower()` test cases (ASCII, Latin-1 café, Greek, Cyrillic,
U+0130's İstanbul shrink, punctuation no-op) pass unmodified against the
new table-driven implementation, confirming it reproduces the old
five-script behavior exactly while extending far beyond it. `make -C
lyric-rt test` and the full `native-backend-self-tests` self-test list
pass with zero regressions.

**Related:** #6779 (this fix), #6588/D-progress-831 (the fix this
widens), #6778 (the review finding that asked for a tracked plan rather
than a disclaimer), #6758 (the U+0130 table-generation-class bug this
plan's own item 2 specifically guarded against recurring — resolved for
free by using Unicode's own data instead of hand-derived range rules),
#6240/#6755/#6237 (the other three native `String` gaps from the same
audit, shipped as separate PRs), `docs/01-language-reference.md` §12.1
(updated), `scripts/gen_unicode_case_tables.py`,
`lyric-rt/src/lyric_unicode_case_tables.inc`.
