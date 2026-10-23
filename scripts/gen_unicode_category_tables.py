#!/usr/bin/env python3
"""gen_unicode_category_tables.py — generates lyric-rt's native Unicode
general-category table (issue #6858).

Reads Unicode's UnicodeData.txt and emits a C source fragment
(lyric-rt/src/lyric_unicode_category_tables.inc) holding one table of
sorted, non-overlapping {first, last, category} ranges covering every
assigned code point, with adjacent code points of the same category merged
(the file's "<..., First>" / "<..., Last>" pairs expand to their range).
A code point in no range is unassigned (Cn).  lyric_string.c looks a code
point up by binary search and builds the `Std.Char` predicates on it
(`lyric_char_is_letter` and its siblings).

Usage:
    python3 scripts/gen_unicode_category_tables.py \\
        --input /path/to/UnicodeData.txt \\
        --output lyric-rt/src/lyric_unicode_category_tables.inc

Fetches UnicodeData.txt for the pinned version from unicode.org when --input
is omitted (network access is needed only to regenerate; the generated .inc is
checked in so lyric-rt's own build never needs it).  The version is the one
lyric_unicode_case_tables.inc is generated from, so case mapping and
classification agree.

Regenerate only to pick up a newer Unicode version; re-run and diff the
output, never hand-edit the generated file.
"""
import argparse
import sys
import urllib.request

UCD_VERSION = "17.0.0"
UCD_URL = "https://www.unicode.org/Public/%s/ucd/UnicodeData.txt" % UCD_VERSION

# Index in this list is the category number the C table stores.
CATEGORIES = [
    "Lu", "Ll", "Lt", "Lm", "Lo",
    "Mn", "Mc", "Me",
    "Nd", "Nl", "No",
    "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po",
    "Sm", "Sc", "Sk", "So",
    "Zs", "Zl", "Zp",
    "Cc", "Cf", "Cs", "Co",
]


def fetch_lines(path):
    if path:
        with open(path, encoding="utf-8") as f:
            return f.read().splitlines()
    with urllib.request.urlopen(UCD_URL, timeout=60) as r:
        return r.read().decode("utf-8").splitlines()


def build_ranges(lines):
    pending_first = None
    spans = []
    for line in lines:
        if not line.strip():
            continue
        fields = line.split(";")
        cp = int(fields[0], 16)
        name = fields[1]
        cat = fields[2]
        if cat not in CATEGORIES:
            sys.exit("unknown general category %r at U+%04X" % (cat, cp))
        if name.endswith(", First>"):
            pending_first = cp
            continue
        if name.endswith(", Last>"):
            if pending_first is None:
                sys.exit("range end without a start at U+%04X" % cp)
            spans.append((pending_first, cp, cat))
            pending_first = None
            continue
        spans.append((cp, cp, cat))
    spans.sort()
    merged = []
    for first, last, cat in spans:
        if merged and merged[-1][2] == cat and merged[-1][1] + 1 == first:
            merged[-1] = (merged[-1][0], last, cat)
        else:
            merged.append((first, last, cat))
    for a, b in zip(merged, merged[1:]):
        if a[1] >= b[0]:
            sys.exit("overlapping ranges %r and %r" % (a, b))
    return merged


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--input")
    ap.add_argument("--output", required=True)
    args = ap.parse_args()
    ranges = build_ranges(fetch_lines(args.input))
    out = []
    out.append("/* lyric_unicode_category_tables.inc — GENERATED FILE, do not hand-edit.\n")
    out.append(" *\n")
    out.append(" * Produced by scripts/gen_unicode_category_tables.py from Unicode %s's\n" % UCD_VERSION)
    out.append(" * UnicodeData.txt (issue #6858): %d sorted {first, last, category} ranges\n" % len(ranges))
    out.append(" * covering every assigned code point; a code point in none is unassigned\n")
    out.append(" * (Cn).  Category numbers index this order:\n")
    out.append(" *   " + " ".join("%s=%d" % (c, i) for i, c in enumerate(CATEGORIES)) + "\n")
    out.append(" *\n")
    out.append(" * Regenerate with:\n")
    out.append(" *   python3 scripts/gen_unicode_category_tables.py \\\n")
    out.append(" *       --output lyric-rt/src/lyric_unicode_category_tables.inc\n")
    out.append(" */\n\n")
    out.append("typedef struct {\n    uint32_t first;\n    uint32_t last;\n    uint8_t category;\n} CategoryRange;\n\n")
    out.append("static const CategoryRange kCategoryTable[] = {\n")
    for first, last, cat in ranges:
        out.append("    {0x%06X, 0x%06X, %d},\n" % (first, last, CATEGORIES.index(cat)))
    out.append("};\n")
    with open(args.output, "w", encoding="utf-8") as f:
        f.write("".join(out))


if __name__ == "__main__":
    main()
