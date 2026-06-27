#!/usr/bin/env python3
"""
Patch a .NET assembly DLL to sort the InterfaceImpl metadata table (ECMA-335 §II.22.23).
The CLR throws BadImageFormatException if this table is unsorted.
"""
import struct
import sys
import math

def rva_to_file_offset(sections, rva):
    for s in sections:
        va = s['va']
        size = s['vsize']
        raw = s['raw']
        if va <= rva < va + size:
            return raw + (rva - va)
    raise ValueError(f"RVA 0x{rva:x} not found in any section")

def coded_index_size(row_counts, table_ids):
    """Return 2 or 4 for a coded index covering the given table IDs."""
    tag_bits = math.ceil(math.log2(max(len(table_ids), 2)))
    max_rows = max((row_counts.get(t, 0) for t in table_ids), default=0)
    return 4 if max_rows >= (1 << (16 - tag_bits)) else 2

def simple_index_size(row_counts, table_id):
    return 4 if row_counts.get(table_id, 0) > 65535 else 2

def patch(filename):
    with open(filename, 'rb') as f:
        data = bytearray(f.read())

    # --- Parse PE header ---
    pe_off = struct.unpack_from('<I', data, 0x3C)[0]
    opt_off = pe_off + 24
    opt_magic = struct.unpack_from('<H', data, opt_off)[0]
    opt_hdr_size = struct.unpack_from('<H', data, pe_off + 20)[0]
    num_sections = struct.unpack_from('<H', data, pe_off + 6)[0]

    if opt_magic == 0x10b:   # PE32
        data_dirs_off = opt_off + 96
    elif opt_magic == 0x20b: # PE32+
        data_dirs_off = opt_off + 112
    else:
        raise ValueError(f"Unknown PE magic: 0x{opt_magic:x}")

    sections_off = opt_off + opt_hdr_size
    sections = []
    for i in range(num_sections):
        s = sections_off + i * 40
        sections.append({
            'vsize': struct.unpack_from('<I', data, s + 8)[0],
            'va':    struct.unpack_from('<I', data, s + 12)[0],
            'raw':   struct.unpack_from('<I', data, s + 20)[0],
        })

    # CLI header (data directory index 14)
    cli_rva  = struct.unpack_from('<I', data, data_dirs_off + 14 * 8)[0]
    cli_file = rva_to_file_offset(sections, cli_rva)

    # Metadata root RVA is at offset 8 in the CLI header
    meta_rva  = struct.unpack_from('<I', data, cli_file + 8)[0]
    meta_file = rva_to_file_offset(sections, meta_rva)

    # Verify metadata signature
    if data[meta_file:meta_file+4] != b'BSJB':
        raise ValueError("Expected BSJB metadata signature")

    # Version string length (padded to 4-byte multiple)
    ver_raw_len = struct.unpack_from('<I', data, meta_file + 12)[0]
    ver_padded  = (ver_raw_len + 3) & ~3

    # Flags(2) + NumStreams(2) start right after the version string
    hdr2_off = meta_file + 16 + ver_padded
    num_streams = struct.unpack_from('<H', data, hdr2_off + 2)[0]

    # Walk stream headers to find #~
    shdr_off = hdr2_off + 4
    tilde_file = None
    for _ in range(num_streams):
        s_rva  = struct.unpack_from('<I', data, shdr_off)[0]
        s_size = struct.unpack_from('<I', data, shdr_off + 4)[0]
        # Null-terminated name, padded to 4 bytes
        name_start = shdr_off + 8
        name_end = name_start
        while data[name_end]:
            name_end += 1
        name = data[name_start:name_end].decode('ascii')
        name_field = name_end - name_start + 1
        name_field = (name_field + 3) & ~3
        if name == '#~':
            tilde_file = meta_file + s_rva
        shdr_off += 8 + name_field

    if tilde_file is None:
        raise ValueError("Could not find #~ stream")

    # --- Parse #~ header ---
    heap_sizes    = data[tilde_file + 6]
    valid_tables  = struct.unpack_from('<Q', data, tilde_file +  8)[0]
    sorted_tables = struct.unpack_from('<Q', data, tilde_file + 16)[0]

    str_size  = 4 if (heap_sizes & 0x01) else 2
    guid_size = 4 if (heap_sizes & 0x02) else 2
    blob_size = 4 if (heap_sizes & 0x04) else 2

    # Read row counts
    rc_off = tilde_file + 24
    row_counts = {}
    for i in range(64):
        if valid_tables & (1 << i):
            row_counts[i] = struct.unpack_from('<I', data, rc_off)[0]
            rc_off += 4

    print(f"Tables present: {sorted(row_counts.keys())}")
    print(f"InterfaceImpl (0x09) rows: {row_counts.get(0x09, 0)}")

    # Table data starts right after the row count array
    tables_data = rc_off

    # --- Compute row sizes for tables 0x00..0x08 to skip to 0x09 ---
    # TypeDefOrRef coded index (2-bit tag): tables TypeDef=0x02, TypeRef=0x01, TypeSpec=0x1B
    typedef_or_ref_size = coded_index_size(row_counts, [0x02, 0x01, 0x1B])
    # ResolutionScope coded (2-bit tag): Module=0x00, ModuleRef=0x1A, AssemblyRef=0x23, TypeRef=0x01
    res_scope_size      = coded_index_size(row_counts, [0x00, 0x1A, 0x23, 0x01])
    # Simple table index sizes
    si_field  = simple_index_size(row_counts, 0x04)
    si_method = simple_index_size(row_counts, 0x06)
    si_param  = simple_index_size(row_counts, 0x08)
    si_event  = simple_index_size(row_counts, 0x14)
    si_prop   = simple_index_size(row_counts, 0x17)

    row_sizes = {
        0x00: 2 + str_size + guid_size + guid_size + guid_size,                    # Module
        0x01: res_scope_size + str_size + str_size,                                 # TypeRef
        0x02: 4 + str_size + str_size + typedef_or_ref_size + si_field + si_method, # TypeDef
        0x03: si_field,                                                              # FieldPtr
        0x04: 2 + str_size + blob_size,                                             # FieldDef
        0x05: si_method,                                                             # MethodPtr
        0x06: 4 + 2 + 2 + str_size + blob_size + si_param,                         # MethodDef
        0x07: si_param,                                                              # ParamPtr
        0x08: 2 + 2 + str_size,                                                     # Param
    }

    # Skip to table 0x09
    current = tables_data
    for t in range(0x09):
        if t in row_counts:
            rs = row_sizes.get(t)
            if rs is None:
                raise ValueError(f"Unknown row size for table 0x{t:02x} (present)")
            current += row_counts[t] * rs

    # InterfaceImpl columns: Class (TypeDef index), Interface (TypeDefOrRef coded)
    class_sz = simple_index_size(row_counts, 0x02)
    iface_sz = typedef_or_ref_size
    ii_row   = class_sz + iface_sz
    ii_count = row_counts.get(0x09, 0)

    print(f"InterfaceImpl table @ file offset 0x{current:x}, row size {ii_row} (class={class_sz}, iface={iface_sz})")

    if ii_count == 0:
        print("No InterfaceImpl rows — nothing to sort.")
        return

    # Read rows
    rows = []
    for i in range(ii_count):
        off = current + i * ii_row
        cls  = struct.unpack_from('<H' if class_sz == 2 else '<I', data, off)[0]
        ifc  = struct.unpack_from('<H' if iface_sz == 2 else '<I', data, off + class_sz)[0]
        rows.append((cls, ifc))

    sorted_rows = sorted(rows, key=lambda r: (r[0], r[1]))
    already_sorted = (sorted_rows == rows)

    print(f"First 10 rows before sort: {rows[:10]}")
    print(f"Already sorted: {already_sorted}")

    if already_sorted and (sorted_tables & (1 << 0x09)):
        print("Table already sorted and sorted bit set — no patch needed.")
        return

    # Write sorted rows back
    for i, (cls, ifc) in enumerate(sorted_rows):
        off = current + i * ii_row
        if class_sz == 2:
            struct.pack_into('<H', data, off, cls)
        else:
            struct.pack_into('<I', data, off, cls)
        if iface_sz == 2:
            struct.pack_into('<H', data, off + class_sz, ifc)
        else:
            struct.pack_into('<I', data, off + class_sz, ifc)

    # Set the sorted bit for table 0x09
    sorted_tables |= (1 << 0x09)
    struct.pack_into('<Q', data, tilde_file + 16, sorted_tables)

    with open(filename, 'wb') as f:
        f.write(data)

    print(f"Patched: sorted {ii_count} InterfaceImpl rows in {filename}")

if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: patch_interface_impl.py <file.dll> [<file2.dll> ...]")
        sys.exit(1)
    for p in sys.argv[1:]:
        print(f"\n=== {p} ===")
        patch(p)
