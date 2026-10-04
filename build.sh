#!/usr/bin/env bash
# Build and smoke-test variants locally, the same way CI does before pushing.
#
# Usage: ./build.sh [variant...]    (default: base souin anycable)
# Images are tagged caddy8d:<variant>.
set -euo pipefail
cd "$(dirname "$0")"
variants=("${@:-base souin anycable}")
# shellcheck disable=SC2206 # split the default list
variants=(${variants[*]})
fail=0
for v in "${variants[@]}"; do
  echo "=== Building $v"
  docker build --pull --build-arg VARIANT="$v" -t "caddy8d:$v" .
done
for v in "${variants[@]}"; do
  tests/smoke.sh "caddy8d:$v" "$v" || fail=1
done
exit $fail
