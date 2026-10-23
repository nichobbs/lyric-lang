#!/usr/bin/env python3
"""Checks a plugin artifact written by `lyric plugin pack` (D207 Decision 5).

Runs every payload the way a host would start it, from the artifact
directory, with `--lyric-plugin-manifest`, and checks each prints the
manifest that plugin.json carries (without its payloads), that the payload
list names exactly the expected targets, and that the plugin's number text
survived packing exactly.

Usage: check_artifact.py <artifact dir> <comma-separated targets> [<wasmtime>]
"""
import json
import os
import subprocess
import sys


def fail(msg):
    print("FAIL: " + msg, file=sys.stderr)
    sys.exit(1)


def main():
    if len(sys.argv) < 3:
        print(__doc__, file=sys.stderr)
        return 2
    artifact, targets = sys.argv[1], sys.argv[2].split(",")
    wasmtime = sys.argv[3] if len(sys.argv) > 3 else "wasmtime"
    with open(os.path.join(artifact, "plugin.json"), encoding="utf-8") as f:
        text = f.read()
    if "9007199254740993" not in text:
        fail("plugin.json lost the exact text of 9007199254740993")
    doc = json.loads(text)
    payloads = doc.pop("payloads")
    kinds = []
    for p in payloads:
        if p["mode"] == "wasm":
            kinds.append("wasm")
        elif "runtime" in p:
            kinds.append(p["runtime"])
        else:
            kinds.append("native")
    if kinds != targets:
        fail("payload kinds " + str(kinds) + ", expected " + str(targets))
    for p, kind in zip(payloads, kinds):
        if kind == "wasm":
            command = [wasmtime, "run", p["module"]]
        else:
            command = list(p["command"])
        run = subprocess.run(
            command + ["--lyric-plugin-manifest"], cwd=artifact, capture_output=True, text=True, timeout=120, stdin=subprocess.DEVNULL
        )
        if run.returncode != 0:
            fail(kind + " payload " + str(command) + " exited " + str(run.returncode) + ": " + run.stderr)
        probed = json.loads(run.stdout)
        if probed != doc:
            fail(kind + " payload printed a different manifest:\n" + run.stdout + "\nplugin.json without payloads:\n" + json.dumps(doc))
    print("ok: " + doc["id"] + "-" + doc["version"] + " payloads " + ",".join(kinds) + " run from the artifact and print its manifest")
    return 0


if __name__ == "__main__":
    sys.exit(main())
