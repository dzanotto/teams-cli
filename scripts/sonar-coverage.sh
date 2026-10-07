#!/bin/bash
set -euo pipefail

# Run after swift test --enable-code-coverage, from the repository root.
build_path=$(swift build --show-bin-path)
profile="$build_path/codecov/default.profdata"
report=.build/sonar-coverage.report
temporary_report="$report.tmp"
trap 'rm -f "$temporary_report"' EXIT
rm -f "$report" "$temporary_report"

test -s "$profile"
test -x "$build_path/teams-cli"

# SwiftPM's test bundle names differ between build systems. Include every test
# executable plus the CLI, so untested CLI code is represented as well.
shopt -s nullglob
coverage_objects=()
for binary in "$build_path/"*.xctest/Contents/MacOS/*; do
  if [[ -f "$binary" && -x "$binary" ]]; then
    coverage_objects+=(-object "$binary")
  fi
done
if [[ ${#coverage_objects[@]} -eq 0 ]]; then
  echo 'No XCTest executable found. Run swift test --enable-code-coverage first.' >&2
  exit 1
fi

xcrun llvm-cov show "$build_path/teams-cli" "${coverage_objects[@]}" \
  -instr-profile="$profile" -format=text -use-color=0 > "$temporary_report"
test -s "$temporary_report"
mv "$temporary_report" "$report"
echo "Coverage report written to $report"
