#!/bin/bash
set -euo pipefail

mutation_repo_dir=$(cd "$(dirname "$0")/.." && pwd)
exec python3 "$mutation_repo_dir/scripts/mutation-test.py" "$@"
