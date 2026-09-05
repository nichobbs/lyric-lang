#!/usr/bin/env python3
"""gen_unicode_case_tables.py — generates lyric-rt's native Unicode simple
case-folding tables (issue #6779, fast-follow to #6588/D-progress-831's
five-script `cp_to_lower`).

Reads Unicode's UnicodeData.txt (https://www.unicode.org/Public/UCD/latest/
ucd/UnicodeData.txt) and emits a C source fragment
(lyric-rt/src/lyric_unicode_case_tables.inc) with two sorted-by-codepoint
tables — one for `.toLower()`, one for `.toUpper()` — built from the file's
"simple lowercase mapping" (field 13) and "simple uppercase mapping"
(field 12) columns.

This is a SIMPLE case fold only: it deliberately does NOT read
SpecialCasing.txt, so no context-sensitive or locale-conditional rule is
ever applied (no Turkish/Azeri dotless-I folding of plain ASCII "I", no
German ß -> "SS" expansion, no final-sigma positional form) — every
mapping is unconditional and every output codepoint is a single scalar
value, matching this runtime's byte-in-place case-conversion model
(`lyric_string_to_lower`/`lyric_string_to_upper` allocate for a mapped
codepoint whose UTF-8 length may differ from the input's, but never split
one input codepoint into several output codepoints or vice versa).

Usage:
    python3 scripts/gen_unicode_case_tables.py \\
        --input /path/to/UnicodeData.txt \\
        --output lyric-rt/src/lyric_unicode_case_tables.inc

Fetches UnicodeData.txt from unicode.org automatically when --input is
omitted (network access required only when regenerating; the generated
.inc file is checked into the repo so lyric-rt's own build never needs
network access or this script).

Regenerate only when picking up a newer Unicode Character Database
version; re-run and diff the output, don't hand-edit the generated file.
"""
import argparse
import sys
import urllib.request

UCD_URL = "https://www.unicode.org/Public/UCD/latest/ucd/UnicodeData.txt"

GENERATED_HEADER = """/* lyric_unicode_case_tables.inc — GENERATED FILE, do not hand-edit.
 *
 * Produced by scripts/gen_unicode_case_tables.py from Unicode {version}'s
 * UnicodeData.txt (issue #6779). Two sorted-by-codepoint tables of
 * {{codepoint, mapped}} pairs, each covering every character with a
 * non-empty *simple* (SpecialCasing.txt-free, single-scalar) case mapping
 * in that direction — {lower_count} lowercase mappings, {upper_count} uppercase
 * mappings. Looked up via binary search in lyric_string.c's
 * cp_to_lower/cp_to_upper.
 *
 * Regenerate with:
 *   python3 scripts/gen_unicode_case_tables.py \\
 *       --output lyric-rt/src/lyric_unicode_case_tables.inc
 */
"""


def fetch_ucd_lines(input_path):
    if input_path:
        with open(input_path, "r", encoding="utf-8") as f:
            return f.readlines()
    with urllib.request.urlopen(UCD_URL, timeout=30) as resp:
        return resp.read().decode("utf-8").splitlines(keepends=True)


def build_case_tables(lines):
    lower_map = {}
    upper_map = {}
    for line in lines:
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split(";")
        if len(fields) < 14:
            continue
        cp = int(fields[0], 16)
        simple_upper = fields[12].strip()
        simple_lower = fields[13].strip()
        # Simple mappings are always exactly one codepoint (unlike the
        # decomposition field, which can be a space-separated sequence) —
        # a defensive check, not expected to ever fire against real UCD data.
        if simple_upper and " " not in simple_upper:
            upper_map[cp] = int(simple_upper, 16)
        if simple_lower and " " not in simple_lower:
            lower_map[cp] = int(simple_lower, 16)
    return lower_map, upper_map


def emit_table(name, mapping):
    lines = [f"static const CaseFoldEntry {name}[] = {{"]
    for cp in sorted(mapping):
        lines.append(f"    {{0x{cp:06X}, 0x{mapping[cp]:06X}}},")
    lines.append("};")
    lines.append(f"static const size_t {name}_count = sizeof({name}) / sizeof({name}[0]);")
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", help="path to a local UnicodeData.txt (fetches from unicode.org if omitted)")
    ap.add_argument("--output", required=True, help="path to write the generated .inc file")
    ap.add_argument("--unicode-version", default="17.0.0", help="Unicode version string for the header comment")
    args = ap.parse_args()

    lines = fetch_ucd_lines(args.input)
    lower_map, upper_map = build_case_tables(lines)

    if not lower_map or not upper_map:
        print("error: parsed zero case mappings — check the input file", file=sys.stderr)
        return 1

    out = [
        GENERATED_HEADER.format(
            version=args.unicode_version,
            lower_count=len(lower_map),
            upper_count=len(upper_map),
        ),
        "",
        "typedef struct {",
        "    uint32_t cp;",
        "    uint32_t mapped;",
        "} CaseFoldEntry;",
        "",
        emit_table("kLowerTable", lower_map),
        "",
        emit_table("kUpperTable", upper_map),
        "",
    ]
    with open(args.output, "w", encoding="utf-8") as f:
        f.write("\n".join(out))
    print(f"wrote {args.output}: {len(lower_map)} lowercase, {len(upper_map)} uppercase mappings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
