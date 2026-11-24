#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# http-server-benchmark.sh - the docs/73 section 4.4 HTTP server benchmark (scenarios B1-B6).
#
# Not run by ci.yml (it has no size headroom, scripts/ci/check-workflow-size.sh); run it by hand or from a
# nightly job:
#
#   scripts/ci/http-server-benchmark.sh <target> [scenario...]
#
#   target    dotnet | jvm | native | undertow
#               dotnet     benchmarks/http_server/server.l on --target dotnet  (pure-Lyric Std.HttpEngine kernel)
#               jvm        benchmarks/http_server/server.l on --target jvm     (the shared driver over Std.TcpHost; the JDK
#                          com.sun.net.httpserver kernel it replaced in D789 is gone)
#               native     benchmarks/http_server/server.l on --target native  (h1 only)
#               undertow   benchmarks/http_server/server_web.l through lyric-web on --target jvm (Undertow,
#                          restores lyric-web's Maven dependencies, so it needs Maven Central)
#   scenario  b1 b2 b3 b4 b5 b6 (default: b1 b2 b3 b4 b5), and the same load driven by wrk and h2load when
#             they are on PATH: b1w b2w b3w (wrk) and b4h (h2load). The Lyric generator needs no tools
#             but is slower than wrk; the wrk/h2load rows show whether it was the limit.
#               b1 hello, h1 keep-alive            b2 hello, h1 connection per request
#               b3 echo 64 KiB body, h1            b4 hello, h2 over TLS (curl --http2 --parallel)
#               b5 idle keep-alive connections     b6 soak at 50% of the b1 rate with connect churn
#
# Environment (defaults in brackets):
#   LYRIC [./bin/lyric; any lyric release at or after v0.7.15 works]   BENCH_OUT [mktemp]   BENCH_PORT [8180]
#   BENCH_SECONDS [20] measured seconds per rate scenario    BENCH_WARMUP [5]
#   BENCH_CONNS [64]   BENCH_H2_REQUESTS [20000]   BENCH_IDLE [10000]   BENCH_SOAK_SECONDS [1800]
#
# Output: one `target.scenario.key=value` line per figure on stdout and in $BENCH_OUT/results.txt, plus the
# server's sampled max RSS (kB), max threads and max open fds per scenario. The load generator is
# benchmarks/http_server/loadgen.l (run on --target dotnet); B4 is driven by curl. See
# benchmarks/http_server/README.md for what each figure means and what the harness cannot measure.
# ---------------------------------------------------------------------------
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

target="${1:?usage: http-server-benchmark.sh <dotnet|jvm|native|undertow> [b1 b2 b3 b4 b5 b6]}"
shift || true
scenarios=("$@")
[ "${#scenarios[@]}" -gt 0 ] || scenarios=(b1 b2 b3 b4 b5)

LYRIC="${LYRIC:-$REPO_ROOT/bin/lyric}"
OUT="${BENCH_OUT:-$(mktemp -d)}"
PORT="${BENCH_PORT:-8180}"
SECONDS_RUN="${BENCH_SECONDS:-20}"
WARMUP="${BENCH_WARMUP:-5}"
CONNS="${BENCH_CONNS:-64}"
H2_REQUESTS="${BENCH_H2_REQUESTS:-20000}"
IDLE="${BENCH_IDLE:-10000}"
SOAK_SECONDS="${BENCH_SOAK_SECONDS:-1800}"
mkdir -p "$OUT"
RESULTS="$OUT/results.txt"
: > "$RESULTS"

[ -x "$LYRIC" ] || { echo "lyric binary not found at $LYRIC (set LYRIC)" >&2; exit 1; }
ulimit -n "$(ulimit -Hn)" 2>/dev/null || true

record() { echo "$target.$1" | tee -a "$RESULTS"; }

# ---- build ----------------------------------------------------------------
build_loadgen() {
  "$LYRIC" build --target dotnet benchmarks/http_server/loadgen.l -o "$OUT/loadgen.dll" >"$OUT/build-loadgen.log" 2>&1 \
    || { cat "$OUT/build-loadgen.log" >&2; exit 1; }
  # One blocking task per connection: without a raised minimum the .NET threadpool injects a thread about
  # every 500 ms and the first seconds of a 64-connection run measure the ramp, not the server.
  python3 -I - "$OUT/loadgen.runtimeconfig.json" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["runtimeOptions"].setdefault("configProperties", {})["System.Threading.ThreadPool.MinThreads"] = 1100
json.dump(d, open(p, "w"), indent=2)
PY
}

server_cmd=()
build_server() {
  case "$target" in
    dotnet)
      "$LYRIC" build --target dotnet benchmarks/http_server/server.l -o "$OUT/server.dll" >"$OUT/build-server.log" 2>&1 \
        || { cat "$OUT/build-server.log" >&2; exit 1; }
      server_cmd=(dotnet "$OUT/server.dll") ;;
    jvm)
      "$LYRIC" build --target jvm benchmarks/http_server/server.l -o "$OUT/server.jar" >"$OUT/build-server.log" 2>&1 \
        || { cat "$OUT/build-server.log" >&2; exit 1; }
      server_cmd=(java -jar "$OUT/server.jar") ;;
    native)
      "$LYRIC" build --target native benchmarks/http_server/server.l -o "$OUT/server-native" >"$OUT/build-server.log" 2>&1 \
        || { cat "$OUT/build-server.log" >&2; exit 1; }
      server_cmd=("$OUT/server-native") ;;
    undertow)
      if [ -z "${LYRIC_MAVEN_RESOLVER:-}" ] && [ -f "$(dirname "$LYRIC")/lyric-resolver.jar" ]; then
        export LYRIC_MAVEN_RESOLVER="$(dirname "$LYRIC")/lyric-resolver.jar"
      fi
      "$LYRIC" restore --manifest "$REPO_ROOT/lyric-web/lyric.toml" >"$OUT/restore-web.log" 2>&1 \
        || { cat "$OUT/restore-web.log" >&2; exit 1; }
      # The file must sit inside the manifest's directory to resolve lyric-web's dependencies (a path outside it
      # fails with T0211), so it is copied in for the build and removed again.
      trap 'rm -f lyric-web/tests/zz_bench_server_web.l' EXIT
      cp benchmarks/http_server/server_web.l lyric-web/tests/zz_bench_server_web.l
      (cd lyric-web && "$LYRIC" build --target jvm tests/zz_bench_server_web.l -o "$OUT/server-web.jar") \
        >"$OUT/build-server.log" 2>&1; rc=$?
      rm -f lyric-web/tests/zz_bench_server_web.l
      [ "$rc" = 0 ] || { cat "$OUT/build-server.log" >&2; exit 1; }
      server_cmd=(java -jar "$OUT/server-web.jar") ;;
    *) echo "unknown target $target" >&2; exit 1 ;;
  esac
}

# ---- server lifecycle and resource sampling ---------------------------------
server_pid=""
sampler_pid=""
stop_server() {
  [ -n "$sampler_pid" ] && kill "$sampler_pid" 2>/dev/null || true
  [ -n "$server_pid" ] && { kill "$server_pid" 2>/dev/null || true; wait "$server_pid" 2>/dev/null || true; }
  server_pid=""; sampler_pid=""
}
trap 'stop_server; rm -f lyric-web/tests/zz_bench_server_web.l' EXIT

start_server() { # [env assignments...]
  stop_server
  env BENCH_PORT="$PORT" "$@" "${server_cmd[@]}" >"$OUT/server.log" 2>&1 &
  server_pid=$!
  local scheme=http flags=()
  case " $* " in *BENCH_CERT=*) scheme=https; flags=(-k) ;; esac
  for _ in $(seq 1 100); do
    if curl -s "${flags[@]}" --max-time 1 -o /dev/null "$scheme://127.0.0.1:$PORT/hello" 2>/dev/null; then return 0; fi
    kill -0 "$server_pid" 2>/dev/null || break
    sleep 0.3
  done
  echo "server did not come up; log:" >&2; tail -30 "$OUT/server.log" >&2; exit 1
}

# Samples the server process once a second: "rss_kb threads fds".
start_sampler() { # outfile
  local f="$1" pid="$server_pid"
  : > "$f"
  ( while kill -0 "$pid" 2>/dev/null; do
      rss=$(awk '/VmRSS/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
      thr=$(awk '/Threads/ {print $2}' "/proc/$pid/status" 2>/dev/null || echo 0)
      fds=$(ls "/proc/$pid/fd" 2>/dev/null | wc -l)
      echo "$rss $thr $fds" >> "$f"
      sleep 1
    done ) &
  sampler_pid=$!
}
summarise_samples() { # scenario outfile
  [ -n "$sampler_pid" ] && { kill "$sampler_pid" 2>/dev/null || true; sampler_pid=""; }
  awk -v p="$target.$1" '
    { if ($1>r) r=$1; if ($2>t) t=$2; if ($3>f) f=$3; lr=$1; lt=$2; lf=$3 }
    END { printf "%s.server_rss_max_kb=%d\n%s.server_threads_max=%d\n%s.server_fds_max=%d\n%s.server_rss_last_kb=%d\n%s.server_fds_last=%d\n", p,r,p,t,p,f,p,lr,p,lf }' "$2" \
    | tee -a "$RESULTS"
}

loadgen() { # env assignments...; prints loadgen output with the scenario prefix applied by caller
  env LG_PORT="$PORT" "$@" dotnet "$OUT/loadgen.dll"
}

run_rate_scenario() { # name, env...
  local name="$1"; shift
  start_server
  start_sampler "$OUT/$name.samples"
  loadgen LG_CONNS="$CONNS" LG_SECONDS="$SECONDS_RUN" LG_WARMUP="$WARMUP" "$@" | sed "s/^/$target.$name./" | tee -a "$RESULTS"
  summarise_samples "$name" "$OUT/$name.samples"
  stop_server
}


# wrk output -> target.<name>.{rps,p50_ms,p99_ms,errors}
wrk_report() { # name, wrk output file
  python3 -I - "$1" "$2" "$target" <<'PY' | tee -a "$RESULTS"
import re, sys
name, f, target = sys.argv[1], sys.argv[2], sys.argv[3]
t = open(f).read()
def ms(v, u):
    return float(v) * {"us": 0.001, "ms": 1.0, "s": 1000.0}[u]
def pct(p):
    m = re.search(r"^\s*%d%%\s+([\d.]+)(us|ms|s)" % p, t, re.M)
    return ms(*m.groups()) if m else float("nan")
rps = re.search(r"Requests/sec:\s+([\d.]+)", t)
bad = re.search(r"Non-2xx or 3xx responses:\s+(\d+)", t)
sock = re.search(r"Socket errors: connect (\d+), read (\d+), write (\d+), timeout (\d+)", t)
errs = (int(bad.group(1)) if bad else 0) + (sum(int(x) for x in sock.groups()) if sock else 0)
print("%s.%s.rps=%s" % (target, name, rps.group(1) if rps else "nan"))
print("%s.%s.p50_ms=%.3f" % (target, name, pct(50)))
print("%s.%s.p99_ms=%.3f" % (target, name, pct(99)))
print("%s.%s.errors=%d" % (target, name, errs))
PY
}

run_wrk_scenario() { # name, extra wrk args...
  local name="$1"; shift
  command -v wrk >/dev/null || { record "$name.skipped=wrk is not on PATH"; return 0; }
  start_server "${SERVER_ENV[@]}"
  start_sampler "$OUT/$name.samples"
  wrk -t4 -c"$CONNS" -d"${WARMUP}s" "$@" >/dev/null 2>&1 || true
  wrk -t4 -c"$CONNS" -d"${SECONDS_RUN}s" --latency "$@" >"$OUT/$name.wrk" 2>&1 || true
  wrk_report "$name" "$OUT/$name.wrk"
  summarise_samples "$name" "$OUT/$name.samples"
  stop_server
}

# ---- scenarios ---------------------------------------------------------------
build_server
build_loadgen

for s in "${scenarios[@]}"; do
  case "$s" in
    b1) run_rate_scenario b1 LG_MODE=keepalive ;;
    b2) run_rate_scenario b2 LG_MODE=connclose ;;
    b3) run_rate_scenario b3 LG_MODE=echo LG_BODY=65536 ;;
    b4)
      if [ "$target" = native ]; then record "b4.unsupported=native serves h1 only (docs/73 section 0 item 2)"; continue; fi
      openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 2 \
        -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
      start_server BENCH_CERT="$OUT/cert.pem" BENCH_KEY="$OUT/key.pem"
      # What does the server negotiate? The JDK-HttpServer kernel and Undertow-less configurations may stay on h1.
      ver="$(curl -sk --http2 -o /dev/null -w '%{http_version}' "https://127.0.0.1:$PORT/hello")"
      record "b4.negotiated_http_version=$ver"
      if [ "$ver" != 2 ]; then record "b4.skipped=server negotiated HTTP/$ver, not h2"; stop_server; continue; fi
      start_sampler "$OUT/b4.samples"
      t0=$(date +%s.%N)
      curl -sk --http2 --parallel --parallel-max 32 -o /dev/null -w '%{time_total} %{http_code}\n' \
        "https://127.0.0.1:$PORT/hello?[1-$H2_REQUESTS]" > "$OUT/b4.curl"
      t1=$(date +%s.%N)
      python3 -I - "$OUT/b4.curl" "$t0" "$t1" "$target" <<'PY' | tee -a "$RESULTS"
import sys
f, t0, t1, target = sys.argv[1], float(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
lat, bad = [], 0
for line in open(f):
    p = line.split()
    if len(p) != 2 or p[1] != "200":
        bad += 1
    else:
        lat.append(float(p[0]))
lat.sort()
def q(x):
    return lat[min(len(lat) - 1, int(x * len(lat)))] * 1000 if lat else 0.0
print("%s.b4.requests=%d" % (target, len(lat)))
print("%s.b4.errors=%d" % (target, bad))
print("%s.b4.rps=%.1f" % (target, len(lat) / (t1 - t0)))
print("%s.b4.p50_ms=%.3f" % (target, q(0.5)))
print("%s.b4.p99_ms=%.3f" % (target, q(0.99)))
PY
      summarise_samples b4 "$OUT/b4.samples"
      stop_server ;;
    b1w) SERVER_ENV=(); run_wrk_scenario b1w "http://127.0.0.1:$PORT/hello" ;;
    b2w) SERVER_ENV=(); run_wrk_scenario b2w -H "Connection: close" "http://127.0.0.1:$PORT/hello" ;;
    b3w)
      printf 'wrk.method = "POST"\nwrk.body = string.rep("a", 65536)\nwrk.headers["Content-Type"] = "application/octet-stream"\n' > "$OUT/echo.lua"
      SERVER_ENV=(); run_wrk_scenario b3w -s "$OUT/echo.lua" "http://127.0.0.1:$PORT/echo" ;;
    b4h)
      command -v h2load >/dev/null || { record "b4h.skipped=h2load is not on PATH"; continue; }
      if [ "$target" = native ]; then record "b4h.unsupported=native serves h1 only (docs/73 section 0 item 2)"; continue; fi
      openssl req -x509 -newkey rsa:2048 -nodes -keyout "$OUT/key.pem" -out "$OUT/cert.pem" -days 2 \
        -subj "/CN=localhost" -addext "subjectAltName=IP:127.0.0.1" 2>/dev/null
      start_server BENCH_CERT="$OUT/cert.pem" BENCH_KEY="$OUT/key.pem"
      ver="$(curl -sk --http2 -o /dev/null -w '%{http_version}' "https://127.0.0.1:$PORT/hello")"
      record "b4h.negotiated_http_version=$ver"
      if [ "$ver" != 2 ]; then record "b4h.skipped=server negotiated HTTP/$ver, not h2"; stop_server; continue; fi
      start_sampler "$OUT/b4h.samples"
      h2load -n "${BENCH_H2LOAD_REQUESTS:-200000}" -c32 -m10 -t2 "https://127.0.0.1:$PORT/hello" > "$OUT/b4h.h2load" 2>&1 || true
      python3 -I - "$OUT/b4h.h2load" "$target" <<'PY' | tee -a "$RESULTS"
import re, sys
f, target = sys.argv[1], sys.argv[2]
t = open(f).read()
def val(v, u):
    return float(v) * {"us": 0.001, "ms": 1.0, "s": 1000.0}[u]
rps = re.search(r"finished in [\d.]+\w+, ([\d.]+) req/s", t)
req = re.search(r"requests: (\d+) total, \d+ started, \d+ done, (\d+) succeeded, (\d+) failed, (\d+) errored", t)
lat = re.search(r"time for request:\s+([\d.]+)(us|ms|s)\s+([\d.]+)(us|ms|s)\s+([\d.]+)(us|ms|s)\s+([\d.]+)(us|ms|s)", t)
print("%s.b4h.rps=%s" % (target, rps.group(1) if rps else "nan"))
if req:
    print("%s.b4h.succeeded=%s" % (target, req.group(2)))
    print("%s.b4h.failed=%d" % (target, int(req.group(3)) + int(req.group(4))))
if lat:
    g = lat.groups()
    print("%s.b4h.min_ms=%.3f" % (target, val(g[0], g[1])))
    print("%s.b4h.max_ms=%.3f" % (target, val(g[2], g[3])))
    print("%s.b4h.mean_ms=%.3f" % (target, val(g[4], g[5])))
PY
      summarise_samples b4h "$OUT/b4h.samples"
      stop_server ;;
    b5)
      # The Std.HttpServer engines cap concurrent connections at LYRIC_HTTP_MAX_CONNECTIONS (default 1000, #6071),
      # so the 10 000-connection scenario raises it; Undertow and the JDK server have no such cap.
      start_server LYRIC_HTTP_MAX_CONNECTIONS="$((IDLE + 1000))"
      start_sampler "$OUT/b5.samples"
      loadgen LG_MODE=idle LG_IDLE="$IDLE" LG_SECONDS="$SECONDS_RUN" | sed "s/^/$target.b5./" | tee -a "$RESULTS"
      summarise_samples b5 "$OUT/b5.samples"
      stop_server ;;
    b6)
      # 50% of the b1 rps, plus connect/disconnect churn from a second generator.
      peak="$(awk -F= -v k="$target.b1.rps" '$1==k {print int($2)}' "$RESULTS" | tail -1)"
      [ -n "$peak" ] || { echo "b6 needs a b1 result in this run" >&2; exit 1; }
      start_server
      start_sampler "$OUT/b6.samples"
      loadgen LG_MODE=connclose LG_CONNS=2 LG_SECONDS="$SOAK_SECONDS" LG_WARMUP=0 | sed "s/^/$target.b6.churn./" >> "$RESULTS" &
      churn=$!
      loadgen LG_MODE=soak LG_CONNS="$CONNS" LG_SECONDS="$SOAK_SECONDS" LG_WARMUP="$WARMUP" LG_RATE=$((peak / 2)) \
        | sed "s/^/$target.b6./" | tee -a "$RESULTS"
      wait "$churn" || true
      summarise_samples b6 "$OUT/b6.samples"
      # RSS drift: last sample against the sample at the end of warm-up.
      awk -v p="$target.b6" -v w="$((WARMUP + 60))" 'NR==w {base=$1} {last=$1} END { if (base>0) printf "%s.rss_drift_pct=%.1f\n", p, (last-base)*100.0/base }' "$OUT/b6.samples" | tee -a "$RESULTS"
      stop_server ;;
    b7) record "b7.unsupported=WebSocket fan-out is not driven by this script; see benchmarks/http_server/README.md" ;;
    *) echo "unknown scenario $s" >&2; exit 1 ;;
  esac
done
echo "results in $RESULTS"
