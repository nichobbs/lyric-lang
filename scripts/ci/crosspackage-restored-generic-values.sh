#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# crosspackage-restored-generic-values.sh — values crossing a package boundary
# keep their real runtime representation (#7755).  Run on both targets.
#
# 1. A restored generic body containing a block expression.  A library ships
#    each generic function's body in its contract metadata as source text
#    (`Lyric.ContractMeta.funcBodyText`), rendered from the post-`Lyric.Mono`
#    AST.  #7716's desugar of a call through a function value (here
#    `valueOf(spec.name)`, `valueOf` a parameter) is a block expression,
#    `{ val __lyric_fv_0: (String) -> String = valueOf; __lyric_fv_0(spec.name) }`,
#    printed as an arrow-less brace block.  The consumer re-parsed it as
#    ordinary source, where that is a zero-parameter lambda, so the
#    specialised `renderAll` passed a `Func<object>` thunk to `render`'s
#    `value: String` parameter (`examples/ui-customers`' `Ui.Forms.formFields`
#    hit the same shape).  The synthesised source is now marked
#    `@contract_source`, under which the parser decodes the braces as a block.
# 2. An erased list in a library's result.  `buildSpecs` builds its list with
#    an unannotated `newList()`, so the runtime value is `List<object>` although
#    the checker types it `List[Spec]`.  Its `Ok(value = specs)` must not cast
#    it to `List<Spec>` — CLR generics are invariant, so the cast throws — and
#    the consumer passes it back to `countSpecs(specs: in List[Spec])`
#    (`lyric-proto`'s `decodeMessage` / `collectFixed32`).
#
# Usage: BUILD_CONFIG=Release scripts/ci/crosspackage-restored-generic-values.sh
# ---------------------------------------------------------------------------
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
lyric_bin="$REPO_ROOT/bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG:-Debug}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin"
  exit 1
fi
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/lib/src" "$work/app/src" "$work/app/tests"
cat > "$work/lib/lyric.toml" <<'EOF'
[package]
name = "R9.Lib"
version = "0.1.0"

[project]
name = "R9.Lib"
output = "single"
output_assembly = "R9Lib.dll"

[project.packages]
"R9Lib" = "src/lib.l"
EOF
cat > "$work/lib/src/lib.l" <<'EOF'
package R9Lib

import Std.Core
import Std.Collections

pub record Spec {
  name: String
}

pub func render[M](spec: in Spec, value: in String, tag: in M): String {
  return spec.name + "=" + value
}

pub func buildSpecs(): Result[List[Spec], String] {
  val specs = newList()
  specs.add(Spec(name = "b"))
  Ok(value = specs)
}

pub func countSpecs(specs: in List[Spec]): Int {
  val arr = specs.toArray()
  arr.length
}

pub func renderAll[M](specs: in List[Spec], valueOf: in (String) -> String, tag: in M): List[String] {
  val acc: List[String] = newList()
  for spec in specs {
    acc.add(render(spec, valueOf(spec.name), tag))
  }
  return acc
}
EOF
cat > "$work/app/lyric.toml" <<'EOF'
[package]
name = "R9.App"
version = "0.1.0"

[project]
name = "R9.App"
output = "single"
output_assembly = "R9App.dll"

[project.packages]
"R9App" = "src/app.l"

[project.tests]
"R9App.Tests" = "tests/app_tests.l"

[dependencies]
"R9.Lib" = { path = "../lib" }
EOF
cat > "$work/app/src/app.l" <<'EOF'
package R9App

import Std.Core
import Std.Collections
import R9Lib

pub func run(): List[String] {
  val specs: List[Spec] = newList()
  specs.add(Spec(name = "a"))
  return R9Lib.renderAll(specs, { n: String -> n + "!" }, 1)
}
EOF
cat > "$work/app/tests/app_tests.l" <<'EOF'
@test_module
package R9App.Tests

import Std.Core
import Std.Testing
import R9App
import R9Lib

test "cross-package generic passes a function-param call result as String" {
  val res = R9App.run()
  assertEqual(res[0], "a=a!", "rendered")
}

test "an erased library list passed back to a List[Spec] parameter" {
  match R9Lib.buildSpecs() {
    case Ok(specs) -> assertEqualInt(R9Lib.countSpecs(specs), 1, "counted")
    case Err(e) -> assertTrue(false, e)
  }
}
EOF
"$lyric_bin" build --manifest "$work/lib/lyric.toml"
for target in dotnet jvm; do
  echo "=== --target $target"
  "$lyric_bin" test --target "$target" --manifest "$work/app/lyric.toml"
done
echo "restored generic bodies and erased values cross the package boundary intact on both targets"
