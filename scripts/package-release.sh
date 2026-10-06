#!/bin/bash
set -euo pipefail

if [[ $# -ne 2 || ! "$1" =~ ^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo 'Usage: bash scripts/package-release.sh vMAJOR.MINOR.PATCH arm64|x86_64' >&2
    exit 64
fi

release_tag=$1
release_arch=$2
case "$release_arch" in
    arm64|x86_64) ;;
    *) echo "Unsupported architecture: $release_arch" >&2; exit 64 ;;
esac

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
binary="$repo_root/.build/release/teams-cli"
if [[ ! -x "$binary" ]]; then
    echo 'Run swift build -c release before packaging.' >&2
    exit 1
fi
if [[ "$(lipo -archs "$binary")" != "$release_arch" || "$(uname -m)" != "$release_arch" ]]; then
    echo 'The executable and packaging host must match the requested architecture.' >&2
    exit 1
fi

package_name="teams-cli-${release_tag}-macos-${release_arch}"
staging_dir=$(mktemp -d "$repo_root/.build/package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
package_dir="$staging_dir/$package_name"
mkdir -p "$package_dir" "$repo_root/.build/release-assets"
install -m 755 "$binary" "$package_dir/teams-cli"
cp README.md LICENSE AGENTS.md "$package_dir/"
cp -R docs "$package_dir/docs"

{
    printf 'version=%s\n' "${release_tag#v}"
    printf 'tag=%s\n' "$release_tag"
    printf 'commit=%s\n' "$(git rev-parse HEAD)"
    printf 'architecture=%s\n' "$release_arch"
    if [[ -n "$(git status --porcelain)" ]]; then
        printf 'working_tree=dirty\n'
    else
        printf 'working_tree=clean\n'
    fi
    swift --version 2>&1
} > "$package_dir/BUILD-INFO.txt"

archive="$repo_root/.build/release-assets/$package_name.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$staging_dir" "$package_name"

# Check the actual archive, including the executable permission preserved by tar.
mkdir "$staging_dir/extracted"
tar -xzf "$archive" -C "$staging_dir/extracted"
"$staging_dir/extracted/$package_name/teams-cli" --help > /dev/null
printf 'Created %s\n' "$archive"
