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
    echo "Run bash scripts/build-release.sh $release_tag before packaging." >&2
    exit 1
fi
if [[ "$(lipo -archs "$binary")" != "$release_arch" || "$(uname -m)" != "$release_arch" ]]; then
    echo 'The executable and packaging host must match the requested architecture.' >&2
    exit 1
fi

expected_version="teams-cli ${release_tag#v}"
reported_version=$("$binary" --version)
if [[ "$reported_version" != "$expected_version" ]]; then
    echo "The executable must report '$expected_version'. Run bash scripts/build-release.sh $release_tag before packaging." >&2
    exit 1
fi

package_name="teams-cli-${release_tag}-macos-${release_arch}"
staging_dir=$(mktemp -d "$repo_root/.build/package.XXXXXX")
trap 'rm -rf "$staging_dir"' EXIT
package_dir="$staging_dir/$package_name"
mkdir -p "$package_dir" "$repo_root/.build/release-assets"
install -m 755 "$binary" "$package_dir/teams-cli"
cp LICENSE "$package_dir/"

archive="$repo_root/.build/release-assets/$package_name.tar.gz"
COPYFILE_DISABLE=1 tar -czf "$archive" -C "$staging_dir" "$package_name"

# Check the actual archive, including the executable permission preserved by tar.
mkdir "$staging_dir/extracted"
tar -xzf "$archive" -C "$staging_dir/extracted"
"$staging_dir/extracted/$package_name/teams-cli" --help > /dev/null
extracted_version=$("$staging_dir/extracted/$package_name/teams-cli" --version)
if [[ "$extracted_version" != "$expected_version" ]]; then
    echo 'The extracted executable does not report the requested version.' >&2
    exit 1
fi
printf 'Created %s\n' "$archive"
