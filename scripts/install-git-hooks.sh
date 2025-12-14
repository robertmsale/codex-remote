#!/usr/bin/env bash
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "${root}"

git config core.hooksPath .githooks
chmod +x .githooks/pre-commit

echo "Installed git hooks via core.hooksPath=.githooks"

