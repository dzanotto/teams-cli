#!/bin/bash
set -euo pipefail

compat_repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
compat_build_dir="$compat_repo_dir/.build/teams-compatibility"
mkdir -p "$compat_build_dir"
compat_sources=("$compat_repo_dir"/Sources/TeamsCore/*.swift
    "$compat_repo_dir/Sources/TeamsCLI/BuildVersion.swift"
    "$compat_repo_dir/scripts/TeamsCompatibilityCheck.swift")

# Cache by compiler, SDK, architecture, and source contents, including added/deleted files.
# Only the first run after a source/toolchain change needs to compile.
compat_fingerprint=$({
    xcrun --find swiftc
    xcrun swiftc --version 2>&1
    xcrun --show-sdk-path
    xcrun --show-sdk-version
    uname -m
    shasum -a 256 "$compat_repo_dir/scripts/check-teams-compatibility.sh" "${compat_sources[@]}"
} | shasum -a 256 | cut -d ' ' -f 1)
compat_binary="$compat_build_dir/check-$compat_fingerprint"
if [[ ! -x "$compat_binary" ]]; then
    compat_temporary=$(mktemp "$compat_build_dir/build.XXXXXX")
    trap 'rm -f "$compat_temporary"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    xcrun swiftc -swift-version 6 -O -parse-as-library \
        -module-cache-path "$compat_build_dir/module-cache" \
        -target "$(uname -m)-apple-macosx13.0" \
        "${compat_sources[@]}" -o "$compat_temporary"
    mv "$compat_temporary" "$compat_binary"
fi

export TEAMS_COMPATIBILITY_SOURCE_REVISION
TEAMS_COMPATIBILITY_SOURCE_REVISION=$(git -C "$compat_repo_dir" rev-parse HEAD 2>/dev/null || echo unknown)
export TEAMS_COMPATIBILITY_SOURCE_DIRTY=unknown
if compat_status=$(git -C "$compat_repo_dir" status --porcelain 2>/dev/null); then
    TEAMS_COMPATIBILITY_SOURCE_DIRTY=false
    if [[ -n "$compat_status" ]]; then TEAMS_COMPATIBILITY_SOURCE_DIRTY=true; fi
fi
export TEAMS_COMPATIBILITY_DEFAULT_OUTPUT="$compat_build_dir/latest.json"
exec "$compat_binary" "$@"
