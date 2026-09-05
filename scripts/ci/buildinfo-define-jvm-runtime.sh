#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping BuildInfo JVM --define runtime test"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping BuildInfo JVM --define runtime test"
  exit 1
fi
work="$(mktemp -d)"
fixture="$work/bi_define_jvm_fixture.l"
cat > "$fixture" <<'LYR'
package BiDefineJvmFixture

import Std.Console
import Std.BuildInfo

func fmtOpt(o: in Option[String]): String {
  match o {
    case Some(s) -> s
    case None -> "<none>"
  }
}

func main(): Int {
  val bi = buildInfo()
  println("V=" + bi.version)
  println("P=" + bi.profile)
  println("T=" + bi.target)
  println("G=" + fmtOpt(bi.gitHash))
  0
}
LYR
out="$work/bi_define_jvm_fixture.jar"
"$lyric_bin" build --target jvm --define version=8.8.8 --define build_profile=release --define git_hash=beadfeed "$fixture" -o "$out" --force
result="$(java -jar "$out")"
echo "$result"
echo "$result" | grep -qx "V=8.8.8"   || { echo "::error::version define not injected into BuildInfo on JVM"; exit 1; }
echo "$result" | grep -qx "P=release"  || { echo "::error::build_profile define not injected into BuildInfo on JVM"; exit 1; }
echo "$result" | grep -qx "T=jvm"      || { echo "::error::BuildInfo.target is not jvm on the JVM build"; exit 1; }
echo "$result" | grep -qx "G=beadfeed" || { echo "::error::git_hash define not wrapped into BuildInfo.gitHash on JVM"; exit 1; }
echo "BuildInfo JVM --define runtime path OK (V=8.8.8 P=release T=jvm G=beadfeed)" >> "$GITHUB_STEP_SUMMARY"

