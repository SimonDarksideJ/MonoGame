#!/usr/bin/env bash
# Runs the framework test suites that Tests/ci-manifest.json assigns to one backend on one runner class.
#
# Environment:
#   MANIFEST      path to the manifest (default Tests/ci-manifest.json)
#   BACKEND       desktopgl | desktopgl4 | desktopvk | windowsdx | windowsdx12
#   RUNNER_CLASS  hosted-linux | hosted-linux-arm64 | hosted-windows | hosted-macos | selfhosted-windows | selfhosted-macos
#   TIERS         JSON array of tiers to run, e.g. ["fast","windowed"]
#   PAYLOAD_DIR   directory holding MonoGame.Tests.dll for the backend
#   RESULTS_DIR   where result files are written (default TestResults)
#
# Every selected suite runs even if an earlier one fails; the script exits non-zero if any suite failed.
# Each suite is its own process, which is what main.yml did with one YAML step per fixture.
set -uo pipefail

MANIFEST="${MANIFEST:-Tests/ci-manifest.json}"
: "${BACKEND:?BACKEND is required}"
: "${RUNNER_CLASS:?RUNNER_CLASS is required}"
: "${PAYLOAD_DIR:?PAYLOAD_DIR is required}"
TIERS="${TIERS:-[\"fast\"]}"
RESULTS_DIR="${RESULTS_DIR:-TestResults}"

case "$(uname -s)" in
  Linux*)  OS=linux ;;
  Darwin*) OS=macos ;;
  *)       OS=windows ;;
esac
case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64 ;;
  *)             ARCH=x64 ;;
esac

# dotnet on Windows needs a Windows path, not the /c/... form git bash reports.
abspath() {
  if [ "$OS" = windows ]; then
    (cd "$1" && pwd -W)
  else
    (cd "$1" && pwd)
  fi
}

# Fail loudly on a missing prerequisite. A silent exit here would turn a broken runner into a green job.
for tool in jq dotnet; do
  if ! command -v "$tool" > /dev/null 2>&1; then
    echo "::error::'$tool' is not on PATH on this runner ($RUNNER_CLASS); it is required by run-tests.sh"
    exit 1
  fi
done
if [ ! -f "$MANIFEST" ]; then
  echo "::error::Manifest not found: $MANIFEST"
  exit 1
fi

mkdir -p "$RESULTS_DIR"
PAYLOAD_DIR="$(abspath "$PAYLOAD_DIR")"
RESULTS_DIR="$(abspath "$RESULTS_DIR")"

if [ ! -f "$PAYLOAD_DIR/MonoGame.Tests.dll" ]; then
  echo "::error::MonoGame.Tests.dll not found in $PAYLOAD_DIR"
  exit 1
fi

# Backend-level gates: operating system and architecture.
backend_ok="$(jq -r --arg b "$BACKEND" --arg os "$OS" --arg arch "$ARCH" '
  .backends[$b] as $be
  | if $be == null then "unknown"
    elif (($be.os // []) | length) > 0 and (($be.os // []) | index($os)) == null then "os"
    elif (($be.skip // []) | index($arch)) != null then "arch"
    else "ok" end' "$MANIFEST")"

case "$backend_ok" in
  ok) ;;
  os|arch)
    echo "::notice::Backend $BACKEND is not run on $OS/$ARCH (manifest $backend_ok rule); nothing to do."
    exit 0 ;;
  *)
    echo "::error::Backend '$BACKEND' is not defined in $MANIFEST (lookup returned '$backend_ok')"
    exit 1 ;;
esac

selected="$(jq -c --arg b "$BACKEND" --arg class "$RUNNER_CLASS" --argjson tiers "$TIERS" --arg os "$OS" --arg arch "$ARCH" '
  .suites[]
  | .tier as $t
  | select(($tiers | index($t)) != null)
  | select((.backends | index($b)) != null)
  | select(((.runners // []) | length) == 0 or ((.runners // []) | index($class)) != null)
  | select(((.["exclude-runners"] // []) | index($class)) == null)
  | select(((.skip // []) | index($os)) == null and ((.skip // []) | index($arch)) == null)
' "$MANIFEST")" || { echo "::error::Failed to query $MANIFEST"; exit 1; }

if [ -z "$selected" ]; then
  echo "::warning::No suites in $MANIFEST match backend=$BACKEND tiers=$TIERS runner-class=$RUNNER_CLASS on $OS/$ARCH. Check the lane inputs."
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    echo "### Tests: $BACKEND on $RUNNER_CLASS ($OS/$ARCH): no suites matched tiers $TIERS" >> "$GITHUB_STEP_SUMMARY"
  fi
  exit 0
fi

# Hosted Linux has no display; wrap every run in xvfb like main.yml did.
use_xvfb=false
if [ "$OS" = linux ] && [[ "$RUNNER_CLASS" == hosted-* ]]; then
  use_xvfb=true
fi

run_cmd() {
  if [ "$use_xvfb" = true ]; then
    xvfb-run -a -s "-screen 0 1024x768x24" "$@"
  else
    "$@"
  fi
}

summary_rows=""
failed=0
count=0
export CI=true

while IFS= read -r suite; do
  [ -z "$suite" ] && continue
  count=$((count + 1))
  id="$(jq -r '.id' <<<"$suite")"
  tier="$(jq -r '.tier' <<<"$suite")"
  kind="$(jq -r '.runner // "nunitlite"' <<<"$suite")"
  test_filter="$(jq -r '.test // empty' <<<"$suite")"
  where="$(jq -r '.where // empty' <<<"$suite")"
  filter="$(jq -r '.filter // empty' <<<"$suite")"
  timeout="$(jq -r '.timeout // 300000' <<<"$suite")"
  labels="$(jq -r '.labels // empty' <<<"$suite")"

  echo "::group::[$tier] $id  ($BACKEND on $RUNNER_CLASS)"
  args=()
  result_file=""
  case "$kind" in
    nunitlite)
      result_file="$RESULTS_DIR/$BACKEND-$id.xml"
      args=(dotnet MonoGame.Tests.dll "--timeout=$timeout" "--result=$result_file")
      if [ -n "$test_filter" ]; then args+=("--test=$test_filter"); fi
      if [ -n "$where" ]; then args+=("--where=$where"); fi
      if [ -n "$labels" ]; then args+=("--labels=$labels"); fi
      ;;
    dotnet-test)
      args=(dotnet test MonoGame.Tests.dll --results-directory "$RESULTS_DIR" --logger "trx;LogFileName=$BACKEND-$id.trx")
      if [ -n "$filter" ]; then args+=(--filter "$filter"); fi
      ;;
    *)
      echo "::error::Unknown runner kind '$kind' for suite $id"
      failed=$((failed + 1))
      echo "::endgroup::"
      continue
      ;;
  esac

  echo "+ ${args[*]}"
  start=$(date +%s)
  (cd "$PAYLOAD_DIR" && run_cmd "${args[@]}")
  rc=$?
  elapsed=$(( $(date +%s) - start ))
  echo "::endgroup::"

  counts="-"
  if [ -n "$result_file" ] && [ -f "$result_file" ]; then
    total="$(grep -o 'total="[0-9]*"' "$result_file" | head -1 | grep -o '[0-9]*')"
    passed="$(grep -o 'passed="[0-9]*"' "$result_file" | head -1 | grep -o '[0-9]*')"
    failedn="$(grep -o 'failed="[0-9]*"' "$result_file" | head -1 | grep -o '[0-9]*')"
    skipped="$(grep -o 'skipped="[0-9]*"' "$result_file" | head -1 | grep -o '[0-9]*')"
    counts="${total:-?} / ${passed:-?} / ${failedn:-?} / ${skipped:-?}"
  fi

  if [ "$rc" -eq 0 ]; then
    status="pass"
  else
    status="FAIL (exit $rc)"
    failed=$((failed + 1))
    echo "::error::Suite '$id' failed on $BACKEND ($RUNNER_CLASS), exit code $rc"
  fi
  summary_rows+="| $tier | $id | $status | $counts | ${elapsed}s |"$'\n'
done <<< "$selected"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Tests: $BACKEND on $RUNNER_CLASS ($OS/$ARCH)"
    echo
    echo "Tiers: $TIERS. Suites run: $count. Failed: $failed."
    echo
    echo "| Tier | Suite | Result | total / passed / failed / skipped | Time |"
    echo "|---|---|---|---|---|"
    printf '%s' "$summary_rows"
  } >> "$GITHUB_STEP_SUMMARY"
fi

echo "Suites run: $count, failed: $failed"
[ "$failed" -eq 0 ]
