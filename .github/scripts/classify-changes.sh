#!/usr/bin/env bash
# Classifies the files changed between two commits into areas and writes them as GitHub outputs.
#
#   classify-changes.sh <base-sha> <head-sha>
#
# Outputs (GITHUB_OUTPUT): docs-only, code, managed, native, build, templates
#   docs-only  every changed file is documentation; the lanes can skip the build
#   code       the inverse of docs-only
#   managed    framework, tools, tests or content pipeline source changed
#   native     native/** or the submodule list changed (natives must be rebuilt)
#   build      build/**, build scripts or anything under .github changed
#   templates  Templates/** or the templates submodule pointer changed
set -euo pipefail

base="${1:?base sha}"
head="${2:?head sha}"

docs_only=true
managed=false
native=false
build=false
templates=false

files="$(git diff --name-only "$base" "$head")"

while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.md|Images/*|LICENSE.txt|THIRD-PARTY-NOTICES.txt|CODEOWNERS|.github/ISSUE_TEMPLATE/*|.github/PULL_REQUEST_TEMPLATE.md|.github/FUNDING.yml)
      ;;
    native/*|.gitmodules)
      native=true; docs_only=false ;;
    .github/*|build/*|build.ps1|build.sh|MonoGame.props)
      build=true; docs_only=false ;;
    Templates/*|external/MonoGame.Templates|external/MonoGame.Templates/*)
      templates=true; docs_only=false ;;
    *)
      managed=true; docs_only=false ;;
  esac
done <<< "$files"

code=true
if [ "$docs_only" = true ]; then
  code=false
fi

{
  echo "docs-only=$docs_only"
  echo "code=$code"
  echo "managed=$managed"
  echo "native=$native"
  echo "build=$build"
  echo "templates=$templates"
} >> "${GITHUB_OUTPUT:-/dev/stdout}"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### Change classification"
    echo
    echo "| Area | Changed |"
    echo "|---|---|"
    echo "| docs only | $docs_only |"
    echo "| managed | $managed |"
    echo "| native | $native |"
    echo "| build / workflows | $build |"
    echo "| templates | $templates |"
    echo
    echo "<details><summary>Files</summary>"
    echo
    echo '~~~'
    echo "$files"
    echo '~~~'
    echo "</details>"
  } >> "$GITHUB_STEP_SUMMARY"
fi
