#!/usr/bin/env python3
"""Compare every `extern func` in lyric-stdlib/std/_kernel_native against the
C definition it binds, on the wasm32 ABI (docs/35 W2).

wasm-ld rejects a call whose signature differs from the callee's definition,
where x86-64 and AArch64 silently tolerate an i64 passed for a pointer or an
i32 for an i64.  The runtime's wasm32 LLVM IR (`make -C lyric-rt
wasm32-wasi-ir`) carries each definition's real parameter classes; this
script maps each extern's Lyric types to the class the native backend lowers
them to and reports every disagreement.  Symbols the runtime does not define
(libc, wasi-libc) are skipped.

Usage: audit_native_extern_abi.py <kernel-dir> <ir-dir>
"""
import glob
import os
import re
import sys

SCALARS = {"i1", "i8", "i16", "i32", "i64", "float", "double", "ptr", "void"}
LYRIC = {"Int": "i32", "Char": "i32", "Long": "i64", "Double": "double",
         "Float": "float", "Bool": "i1", "Byte": "i8", "Unit": "void"}


def split_top(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur.strip())
            cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur.strip())
    return out


def lyric_class(ty):
    ty = ty.strip()
    return LYRIC.get(ty, "ptr")


def parse_ir(ir_dir):
    defs = {}
    for path in sorted(glob.glob(os.path.join(ir_dir, "*.ll"))):
        for line in open(path, encoding="utf-8"):
            if not line.startswith("define "):
                continue
            m = re.match(r"define\s+(.*?)@([\w.$]+)\((.*)\)[^)]*\{\s*$", line)
            if not m:
                continue
            head, name, params = m.groups()
            ret = next((t for t in head.split() if t in SCALARS), None)
            plist = []
            for p in split_top(params):
                tok = p.split()[0]
                if "sret" in p:
                    ret = "ptr"
                    continue
                plist.append(tok)
            if ret is None or any(t not in SCALARS for t in plist):
                continue
            defs[name] = (plist, ret)
    return defs


def parse_externs(kernel_dir):
    pat = re.compile(r'^\s*(?:pub\s+)?extern func (\w+)\((.*)\)\s*(?::\s*(.*?))?\s*=\s*"(\w+)"\s*$')
    for path in sorted(glob.glob(os.path.join(kernel_dir, "*.l"))):
        for no, line in enumerate(open(path, encoding="utf-8"), 1):
            m = pat.match(line)
            if not m:
                continue
            name, params, ret, sym = m.groups()
            plist = []
            for p in split_top(params):
                ty = p.split(":", 1)[1] if ":" in p else p
                plist.append(lyric_class(ty))
            yield path, no, name, sym, plist, lyric_class(ret or "Unit")


def main():
    kernel_dir, ir_dir = sys.argv[1], sys.argv[2]
    defs = parse_ir(ir_dir)
    if not defs:
        print("audit-native-extern-abi: no definitions parsed from " + ir_dir, file=sys.stderr)
        return 2
    bad = checked = 0
    for path, no, name, sym, plist, ret in parse_externs(kernel_dir):
        if sym not in defs:
            continue
        checked += 1
        cp, cr = defs[sym]
        if plist != cp or ret != cr:
            bad += 1
            print("%s:%d: extern %s binds %s: Lyric lowers (%s) -> %s, C defines (%s) -> %s" % (
                os.path.relpath(path), no, name, sym, ", ".join(plist), ret, ", ".join(cp), cr))
    print("audit-native-extern-abi: %d extern(s) checked against %d runtime definition(s), %d mismatch(es)"
          % (checked, len(defs), bad))
    return 1 if bad else 0


sys.exit(main())
