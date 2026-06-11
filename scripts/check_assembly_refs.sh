#!/usr/bin/env bash
# check_assembly_refs.sh — Band 5 invariant guardrail (#3067).
#
# The stage-1 CLI bundle must not carry AssemblyRef entries pointing at
# Lyric.Emitter or FSharp.Core.  These were removed as part of Band 5
# (#3062): the self-hosted compiler no longer depends on the F# bootstrap
# emitter DLL or the F# runtime at user-program compile/run time.
#
# This script scans every DLL in the stage-1 bundle directory and fails
# loudly if any DLL's AssemblyRef table (ECMA-335 table 0x23) names either
# forbidden assembly.  The table is parsed for real — heap scans are not
# enough, because "Lyric.Lyric.Emitter" (the self-hosted emitter package's
# own assembly) ends with the byte sequence "Lyric.Emitter\0" and would
# false-positive any substring or suffix match.
#
# Usage:
#   check_assembly_refs.sh [stage1-dir]
#
# Defaults to .bootstrap/stage1 if no argument is given.

set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
stage1_dir="${1:-$repo_root/.bootstrap/stage1}"

if [ ! -d "$stage1_dir" ]; then
  echo "::warning::check_assembly_refs: stage1 dir not found at $stage1_dir — skipping"
  exit 0
fi

python_bin="$(command -v python3 2>/dev/null || command -v python 2>/dev/null || true)"
if [ -z "$python_bin" ]; then
  echo "::error::check_assembly_refs: python3 is required but not found"
  exit 1
fi

"$python_bin" - "$stage1_dir" <<'PY'
# Enumerate AssemblyRef (0x23) Name entries by parsing the ECMA-335
# metadata tables stream.  References:
#   ECMA-335 §II.24 (PE structure), §II.25 (metadata root/streams),
#   §II.22 (table schemas), §II.24.2.6 (#~ stream header, index sizes).
import sys
import struct
from pathlib import Path

FORBIDDEN = ("Lyric.Emitter", "FSharp.Core")
stage1_dir = Path(sys.argv[1])
violations = []
parse_failures = []

def u16(d, o): return struct.unpack_from('<H', d, o)[0]
def u32(d, o): return struct.unpack_from('<I', d, o)[0]
def u64(d, o): return struct.unpack_from('<Q', d, o)[0]

# Coded-index groups (§II.24.2.6): member table ids; None marks an unused
# tag slot that still widens the tag-bit count.
CODED = {
    'TypeDefOrRef':        [0x02, 0x01, 0x1B],
    'HasConstant':         [0x04, 0x08, 0x17],
    'HasCustomAttribute':  [0x06, 0x04, 0x01, 0x02, 0x08, 0x09, 0x0A, 0x00,
                            0x0E, 0x17, 0x14, 0x11, 0x1A, 0x1B, 0x20, 0x23,
                            0x26, 0x27, 0x28, 0x2A, 0x2C, 0x2B],
    'HasFieldMarshal':     [0x04, 0x08],
    'HasDeclSecurity':     [0x02, 0x06, 0x20],
    'MemberRefParent':     [0x02, 0x01, 0x1A, 0x06, 0x1B],
    'HasSemantics':        [0x14, 0x17],
    'MethodDefOrRef':      [0x06, 0x0A],
    'MemberForwarded':     [0x04, 0x06],
    'Implementation':      [0x26, 0x23, 0x27],
    'CustomAttributeType': [None, None, 0x06, 0x0A, None],
    'ResolutionScope':     [0x00, 0x1A, 0x23, 0x01],
    'TypeOrMethodDef':     [0x02, 0x06],
}

# Row layouts (§II.22): 'c2'/'c4' fixed bytes, 'S' string idx, 'G' guid idx,
# 'B' blob idx, ('T', id) simple table idx, ('C', group) coded idx.  Every
# table id that can precede AssemblyRef (0x23) needs a layout so the row
# data can be skipped precisely.
LAYOUTS = {
    0x00: ['c2', 'S', 'G', 'G', 'G'],
    0x01: [('C', 'ResolutionScope'), 'S', 'S'],
    0x02: ['c4', 'S', 'S', ('C', 'TypeDefOrRef'), ('T', 0x04), ('T', 0x06)],
    0x03: [('T', 0x04)],
    0x04: ['c2', 'S', 'B'],
    0x05: [('T', 0x06)],
    0x06: ['c4', 'c2', 'c2', 'S', 'B', ('T', 0x08)],
    0x07: [('T', 0x08)],
    0x08: ['c2', 'c2', 'S'],
    0x09: [('T', 0x02), ('C', 'TypeDefOrRef')],
    0x0A: [('C', 'MemberRefParent'), 'S', 'B'],
    0x0B: ['c2', ('C', 'HasConstant'), 'B'],
    0x0C: [('C', 'HasCustomAttribute'), ('C', 'CustomAttributeType'), 'B'],
    0x0D: [('C', 'HasFieldMarshal'), 'B'],
    0x0E: ['c2', ('C', 'HasDeclSecurity'), 'B'],
    0x0F: ['c2', 'c4', ('T', 0x02)],
    0x10: ['c4', ('T', 0x04)],
    0x11: ['B'],
    0x12: [('T', 0x02), ('T', 0x14)],
    0x13: [('T', 0x14)],
    0x14: ['c2', 'S', ('C', 'TypeDefOrRef')],
    0x15: [('T', 0x02), ('T', 0x17)],
    0x16: [('T', 0x17)],
    0x17: ['c2', 'S', 'B'],
    0x18: ['c2', ('T', 0x06), ('C', 'HasSemantics')],
    0x19: [('T', 0x02), ('C', 'MethodDefOrRef'), ('C', 'MethodDefOrRef')],
    0x1A: ['S'],
    0x1B: ['B'],
    0x1C: ['c2', ('C', 'MemberForwarded'), 'S', ('T', 0x1A)],
    0x1D: ['c4', ('T', 0x04)],
    0x1E: ['c4', 'c4'],
    0x1F: ['c4'],
    0x20: ['c4', 'c2', 'c2', 'c2', 'c2', 'c4', 'B', 'S', 'S'],
    0x21: ['c4'],
    0x22: ['c4', 'c4', 'c4'],
    0x23: ['c2', 'c2', 'c2', 'c2', 'c4', 'B', 'S', 'S', 'B'],
}

def assembly_ref_names(data):
    """Yield AssemblyRef Name strings; raise ValueError on parse failure."""
    if len(data) < 0x40:
        raise ValueError('file too small for a PE header')
    e_lfanew = u32(data, 0x3c)
    if data[e_lfanew:e_lfanew + 4] != b'PE\x00\x00':
        raise ValueError('no PE signature')
    coff = e_lfanew + 4
    num_sections = u16(data, coff + 2)
    opt_size = u16(data, coff + 16)
    opt = coff + 20
    magic = u16(data, opt)
    if magic == 0x10b:
        cli_dd = opt + 208
    elif magic == 0x20b:
        cli_dd = opt + 224
    else:
        raise ValueError(f'unknown optional-header magic {magic:#x}')
    cli_rva = u32(data, cli_dd)
    if cli_rva == 0:
        raise ValueError('no CLI header (not a managed assembly)')

    sections = []
    sect_off = opt + opt_size
    for i in range(num_sections):
        so = sect_off + i * 40
        sections.append((u32(data, so + 12), u32(data, so + 8),
                         u32(data, so + 20)))

    def rva2off(rva):
        for vrva, vsize, raw in sections:
            if vrva <= rva < vrva + vsize:
                return raw + (rva - vrva)
        raise ValueError(f'RVA {rva:#x} not mapped by any section')

    cli = rva2off(cli_rva)
    meta = rva2off(u32(data, cli + 8))
    if data[meta:meta + 4] != b'BSJB':
        raise ValueError('no BSJB metadata signature')
    ver_len = (u32(data, meta + 12) + 3) & ~3
    streams_count_off = meta + 16 + ver_len
    num_streams = u16(data, streams_count_off + 2)
    sh = streams_count_off + 4

    strings_heap = None
    tables = None
    for _ in range(num_streams):
        s_off, s_size = u32(data, sh), u32(data, sh + 4)
        name_start = sh + 8
        name_end = data.index(b'\x00', name_start)
        name = data[name_start:name_end].decode('ascii', errors='replace')
        sh = name_start + (((name_end - name_start + 1) + 3) & ~3)
        if name == '#Strings':
            strings_heap = data[meta + s_off: meta + s_off + s_size]
        elif name in ('#~', '#-'):
            tables = meta + s_off
    if strings_heap is None or tables is None:
        raise ValueError('missing #Strings or #~ stream')

    heap_sizes = data[tables + 6]
    s_idx = 4 if heap_sizes & 0x01 else 2
    g_idx = 4 if heap_sizes & 0x02 else 2
    b_idx = 4 if heap_sizes & 0x04 else 2
    valid = u64(data, tables + 8)

    rows = {}
    off = tables + 24
    for tbl in range(64):
        if valid & (1 << tbl):
            rows[tbl] = u32(data, off)
            off += 4
    row_data_start = off

    def coded_size(group):
        members = CODED[group]
        tag_bits = max(1, (len(members) - 1).bit_length())
        max_rows = max((rows.get(t, 0) for t in members if t is not None),
                       default=0)
        return 4 if max_rows >= (1 << (16 - tag_bits)) else 2

    def col_size(col):
        if col == 'c2': return 2
        if col == 'c4': return 4
        if col == 'S': return s_idx
        if col == 'G': return g_idx
        if col == 'B': return b_idx
        kind, arg = col
        if kind == 'T':
            return 4 if rows.get(arg, 0) > 0xFFFF else 2
        return coded_size(arg)

    def row_size(tbl):
        if tbl not in LAYOUTS:
            raise ValueError(f'present table {tbl:#x} has no layout')
        return sum(col_size(c) for c in LAYOUTS[tbl])

    if 0x23 not in rows:
        return

    pos = row_data_start
    for tbl in sorted(rows):
        if tbl == 0x23:
            break
        pos += rows[tbl] * row_size(tbl)

    name_col = 8 + 4 + b_idx  # 4 x u16 version, u32 flags, blob PublicKeyOrToken
    aref_size = row_size(0x23)
    for i in range(rows[0x23]):
        idx_off = pos + i * aref_size + name_col
        idx = u32(data, idx_off) if s_idx == 4 else u16(data, idx_off)
        if idx >= len(strings_heap):
            raise ValueError(f'AssemblyRef name index {idx:#x} out of heap bounds')
        end = strings_heap.index(b'\x00', idx)
        yield strings_heap[idx:end].decode('utf-8', errors='replace')

for dll_path in sorted(stage1_dir.glob('*.dll')):
    try:
        for ref in assembly_ref_names(dll_path.read_bytes()):
            if ref in FORBIDDEN:
                violations.append((dll_path.name, ref))
    except ValueError as e:
        parse_failures.append((dll_path.name, str(e)))

if parse_failures:
    print("", file=sys.stderr)
    print("FAIL: check_assembly_refs could not parse metadata for:", file=sys.stderr)
    for dll_name, reason in parse_failures:
        print(f"  {dll_name}: {reason}", file=sys.stderr)
    print("Parse failures are treated as violations so the guard cannot rot silently.",
          file=sys.stderr)
    sys.exit(1)

if violations:
    print("", file=sys.stderr)
    print("FAIL: Band 5 invariant violated — forbidden AssemblyRef entries found in stage-1 DLLs:",
          file=sys.stderr)
    for dll_name, ref_name in violations:
        print(f"  {dll_name}: AssemblyRef '{ref_name}'", file=sys.stderr)
    print("", file=sys.stderr)
    print("These assemblies must not be referenced by any stage-1 DLL.", file=sys.stderr)
    print("A kernel module has likely reintroduced an @externTarget to Lyric.Emitter.*",
          file=sys.stderr)
    print("or FSharp.Core. See docs/23-fsharp-shim-elimination.md and PR #3062.",
          file=sys.stderr)
    sys.exit(1)

n = sum(1 for _ in stage1_dir.glob('*.dll'))
if n == 0:
    print("FAIL: check_assembly_refs: stage1 directory exists but contains zero DLLs — stage-1 build is broken",
          file=sys.stderr)
    sys.exit(1)
print(f"check_assembly_refs: {n} stage-1 DLL(s) scanned — no forbidden AssemblyRef entries")
sys.exit(0)
PY
