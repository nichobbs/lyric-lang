#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# restored-dependency-self-tests.sh — run the self-tests that build a
# PRODUCER package in-process via `Lyric.Emitter.emitProject` and then
# compile and run a CONSUMER that imports it as a restored dependency. They
# share that two-stage harness and all need LYRIC_LOAD_COMPILER=1, so they
# run from one ci.yml step (kept out of ci.yml to stay under the
# workflow-size ceiling, see scripts/ci/check-workflow-size.sh).
#
# - nat_cross_package_self_test.l (docs/59 §3.3): a `Nat`-typed (or
#   `Nat range A..=B`-typed) parameter, return or field used to lower to an
#   in-package `MClass("<pkg>.Nat")` guess instead of `int64`. Consistent
#   within one unit, but a restored consumer decodes the real `I8`
#   signature, so the call site threw InvalidProgramException.
# - restored_async_self_test.l (#5561): a consumer awaiting the producer's
#   `pub async func`s. The consumer MemberRef must encode the Task-wrapped
#   kickoff return (asyncness comes from the producer's MethodDef metadata;
#   contract reprs don't carry it), and the caller-side await must unwrap
#   it on both the blocking shim and the Phase-B state-machine paths.
# - restored_slice_list_return_self_test.l (#5575): a `List[slice[Byte]]`
#   return across a genuine restored-DLL boundary, which the same-bundle
#   regression coverage of #6332 does not exercise.
# - restored_default_args_self_test.l (#7827, D168): a call that leaves out
#   a defaulted argument of a restored free function, record method,
#   dot-named function, interface member or `impl` method calls the thunk
#   the library compiled the default into, including a default that reads a
#   private value and a widening default. Built for both targets (a DLL run
#   under `dotnet`, a JAR under `java`).
#
# Every test runs even if an earlier one fails; the script exits non-zero
# if any failed. Each run goes through scripts/ci-retry-on-signal.sh (#5933).
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
export LYRIC_LOAD_COMPILER=1

tests=(
  lyric-compiler/lyric/nat_cross_package_self_test.l
  lyric-compiler/lyric/restored_async_self_test.l
  lyric-compiler/lyric/restored_slice_list_return_self_test.l
  lyric-compiler/lyric/restored_default_args_self_test.l
)

failed=()
for t in "${tests[@]}"; do
  echo "::group::$t"
  bash scripts/ci-retry-on-signal.sh bash scripts/ci/self-test.sh "$t"
  rc=$?
  echo "::endgroup::"
  if [ "$rc" -ne 0 ]; then
    echo "::error::$t failed (exit $rc)"
    failed+=("$t")
  fi
done

if [ "${#failed[@]}" -gt 0 ]; then
  echo "restored-dependency self-tests failed: ${failed[*]}" >&2
  exit 1
fi
echo "restored-dependency self-tests: all ${#tests[@]} passed"
