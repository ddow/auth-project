#!/usr/bin/env bash
# deploy/modules/sam_build.sh

set -euo pipefail

# Determine the script's root directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "📦 Building SAM project..."

# Run sam build with explicit template and build directory
sam build \
  --template "${SCRIPT_DIR}/template.yml" \
  --build-dir "${SCRIPT_DIR}/.aws-sam/build" || {
  echo "❌ SAM build failed."
  exit 1
}

echo "✅ SAM build completed."