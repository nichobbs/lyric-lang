#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stdlib-xml-yaml-bundled.sh — Std.Xml and Std.Yaml are bundled (#2592 slice 4).
#
# Std.Xml / Std.Yaml staging check (#2592 slice 4 — curated-package
# exclusions retired, D-progress-480).  `Xml` and `Yaml` are now in
# CURATED_PACKAGES in `scripts/stage-selfhosted-stdlib.sh`.
# A runtime smoke test via `lyric run` is deliberately omitted:
# the F# bootstrap emitter stack-overflows (exit 134) for ANY external
# code that transitively uses `XmlNode` or `XmlDoc` as a type parameter
# (including `List[XmlNode]` returned by `elementChildren`), because
# the emitter recursively resolves all field types of external types and
# `XmlNode` contains a self-referential `List[XmlNode]` field.  The
# existing `xml_tests.l` passes because it is compiled against Xml source
# (in-flight, not DLL-restored), which avoids DLL-based recursive lookup.
# DLL presence is the authoritative check for slice 4; correctness of the
# Xml and Yaml APIs is covered by the stdlib emitter test suite.
# ---------------------------------------------------------------------------
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
# Post-collapse (D111): Std.Xml and Std.Yaml ship inside the single
# Lyric.Stdlib.dll bundle, not per-package DLLs.  Assert the bundle is
# staged and actually defines the Xml/Yaml types.
bundle="$(dirname "$lyric_bin")/Lyric.Stdlib.dll"
if [ ! -f "$bundle" ]; then
  echo "::error::Lyric.Stdlib.dll bundle not staged alongside the AOT binary"
  exit 1
fi
# strings(1) over the raw PE bytes is a heuristic, not a structural
# metadata check. A TypeDef's namespace and name are separate
# string-heap entries, not a single concatenated "Namespace.Name"
# string, so grepping a fully-qualified name (e.g. "Std.Xml.XmlDoc")
# never matches anything -- confirmed broken in CI (issue #4643).
# Requiring both the namespace string AND the public type's own
# name string to be present is strictly more specific than the bare
# namespace check alone, without inventing a heap string that
# doesn't exist and without adding a new ildasm/metadata-reader
# tool dependency here.
dump="$(strings "$bundle")"
if ! grep -q "Std.Xml" <<<"$dump" || ! grep -q "XmlDoc" <<<"$dump"; then
  echo "::error::Std.Xml not present in the Lyric.Stdlib.dll bundle"
  exit 1
fi
if ! grep -q "Std.Yaml" <<<"$dump" || ! grep -q "YamlValue" <<<"$dump"; then
  echo "::error::Std.Yaml not present in the Lyric.Stdlib.dll bundle"
  exit 1
fi
echo "Std.Xml and Std.Yaml are bundled in Lyric.Stdlib.dll"
