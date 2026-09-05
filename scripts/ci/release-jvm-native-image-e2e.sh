#!/usr/bin/env bash
set -euo pipefail
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
bin_abs="$(pwd)/$lyric_bin"
work="$(mktemp -d)"
cat > "$work/hello.l" <<'LYR'
package HelloJvm
import Std.Core
import Std.Console as Console
import Std.Collections
pub func main(): Int {
  val xs: List[Int] = newList()
  xs.add(40); xs.add(2)
  Console.println("jvm release: " + toString(xs[0] + xs[1]))
  0
}
LYR
"$bin_abs" build --release --aot --target jvm "$work/hello.l"
test -x "$work/hello" || { echo "expected native binary $work/hello"; exit 1; }
# Prove it is not a fallback image (a launcher that still needs a
# JVM).  `env -i PATH=/usr/bin:/bin` would NOT prove this: the runner
# image ships /usr/bin/java, so a fallback launcher would find a JVM
# and the assertion would pass vacuously.  Run with a completely
# empty environment instead — no PATH, no JAVA_HOME, nothing for a
# launcher to locate a JVM with.
command -v java >/dev/null && echo "note: a JVM IS installed on this runner (that is what makes the empty-env run meaningful)"
out="$(env -i "$work/hello")"
echo "binary output: $out"
[ "$out" = "jvm release: 42" ] || { echo "unexpected output: $out"; exit 1; }
file "$work/hello" | grep -q ELF || { echo "expected a native ELF binary"; exit 1; }
# A fallback image links against libjvm; a real AOT image does not.
if ldd "$work/hello" | grep -qi 'libjvm\|libjli'; then
  echo "binary links a JVM library — this is a fallback image, not a standalone AOT binary"
  ldd "$work/hello"; exit 1
fi
echo "Release JVM native-image e2e passed"

# Project mode (multi-package, entry package auto-detected).
proj="$(mktemp -d)"
mkdir -p "$proj/src/app" "$proj/src/util"
cat > "$proj/lyric.toml" <<'TOML'
[package]
name = "NiProj"
version = "0.1.0"
[project]
name = "NiProj"
[project.packages]
"Util" = "src/util/util.l"
"App"  = "src/app/app.l"
TOML
printf 'package Util\nimport Std.Core\npub func double(x: in Int): Int { x * 2 }\n' > "$proj/src/util/util.l"
printf 'package App\nimport Std.Core\nimport Std.Console as Console\nimport Util\nfunc main(): Int { Console.println("project release: " + toString(double(21))); 0 }\n' > "$proj/src/app/app.l"
( cd "$proj" && "$bin_abs" build --release --aot --target jvm )
test -x "$proj/NiProj" || { echo "expected native binary $proj/NiProj"; exit 1; }
pout="$(env -i "$proj/NiProj")"
echo "project binary output: $pout"
[ "$pout" = "project release: 42" ] || { echo "unexpected output: $pout"; exit 1; }
echo "Release JVM native-image project-mode e2e passed"

