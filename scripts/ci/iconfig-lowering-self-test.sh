#!/usr/bin/env bash
set -euo pipefail
if [ ! -d .bootstrap/stage1 ] || [ ! -f .bootstrap/stage1/Lyric.Lyric.Cli.dll ]; then
  echo "::error::stage 1 bundle missing; skipping IConfig self-test"
  exit 1
fi
lyric_bin="bootstrap/src/Lyric.Cli.Aot/bin/${BUILD_CONFIG}/net10.0/lyric"
if [ ! -x "$lyric_bin" ]; then
  echo "::error::AOT binary not found at $lyric_bin; skipping IConfig self-test"
  exit 1
fi
out="$("$lyric_bin" run lyric-compiler/msil/msil_self_test_m85.l 2>&1)"
for check in "port_default=true" "debug_default=true" "name_default=true" \
             "rate_default=true" "scale_default=true" "cap_default=true" \
             "timeout_default=true" "access_no_panic=true" \
             "eport_parsed=false" "erate_parsed=false" "ecap_parsed=false" \
             "eflag_parsed=false" "ename_parsed=false"; do
  if ! grep -qx "$check" <<< "$out"; then
    echo "::error::IConfig self-test (defaults run) missing expected line '$check'; full output:"; echo "$out"; exit 1
  fi
done
out_env="$(LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_EPORT=4242 \
           LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_ERATE=2.5 \
           LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_ECAP=8589934592 \
           LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_EFLAG=true \
           LYRIC_CONFIG_MSIL_SELFTESTM85_ENVPROBE_ENAME=from-env \
           "$lyric_bin" run lyric-compiler/msil/msil_self_test_m85.l 2>&1)"
for check in "port_default=true" "rate_default=true" "cap_default=true" \
             "eport_parsed=true" "erate_parsed=true" "ecap_parsed=true" \
             "eflag_parsed=true" "ename_parsed=true"; do
  if ! grep -qx "$check" <<< "$out_env"; then
    echo "::error::IConfig self-test (env-parse run) missing expected line '$check'; full output:"; echo "$out_env"; exit 1
  fi
done
bad_src="$(mktemp -d)/config_bad_type.l"
printf 'package ConfigBadType\n\nconfig Bad {\n  c: Char\n}\n\nfunc main(): Unit {\n  println("unreachable")\n}\n' > "$bad_src"
if bad_out="$("$lyric_bin" run "$bad_src" 2>&1)"; then
  echo "::error::IConfig negative probe: unsupported Char config field compiled successfully; output:"; echo "$bad_out"; exit 1
else
  if ! grep -q "G0009" <<< "$bad_out"; then
    echo "::error::IConfig negative probe: expected G0009 in compile failure output:"; echo "$bad_out"; exit 1
  fi
fi
echo "IConfig config-block lowering: defaults, env-parse, and G0009 negative checks pass (#2983, #2993)"

