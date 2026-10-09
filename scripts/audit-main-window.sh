#!/bin/bash
set -euo pipefail

audit_repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
audit_build_dir="$audit_repo_dir/.build/main-window-audit"
mkdir -p "$audit_build_dir"
swiftc -swift-version 6 -O -parse-as-library \
    -target "$(uname -m)-apple-macosx13.0" \
    "$audit_repo_dir"/Sources/TeamsCore/*.swift \
    "$audit_repo_dir/scripts/MainWindowAudit.swift" \
    -o "$audit_build_dir/main-window-audit"
exec "$audit_build_dir/main-window-audit"
