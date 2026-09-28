//! stdlib/tests/console_stdout_bytes_tests.l — Std.Console's raw stdout
//! byte writer (`writeStdoutBytes`, #7510).
//!
//! Writes one payload containing non-ASCII bytes (café, an emoji, CJK
//! characters) straight to stdout via `writeStdoutBytes` and nothing else —
//! deliberately no `println` alongside it, so a driving script
//! (`scripts/ci/console-stdout-bytes-test.sh`) can diff the process's raw
//! stdout against the expected UTF-8 bytes with no risk of a buffered
//! `TextWriter`'s output interleaving with the raw byte writer's, the same
//! reason `Lyric.Lsp`'s framing never mixes the two on one stdout.
package Std.Console.StdoutBytesTests

import Std.Core
import Std.Console
import Std.Encoding

func main(): Int {
  writeStdoutBytes(encodeUtf8("café 😀 中文\n"))
  0
}
