#!/usr/bin/env bash
# deploy/modules/manage_api.sh

set -euo pipefail

echo "Debug: LOCAL_ONLY received as '$1'"

LOCAL_ONLY="${1:-false}"

if [ "$LOCAL_ONLY" == "true" ]; then
  echo "🚀 Starting local API..."
  TEMPLATE_FILE="${PWD}/.aws-sam/build/template.yaml"
  ENV_PATH="${PWD}/env.json"
  PORT=3000

  # Check if env.json exists and is valid
  if [ ! -f "$ENV_PATH" ] || ! jq -e . >/dev/null 2>&1 "$ENV_PATH"; then
    echo "❌ Error: env.json is missing or invalid."
    exit 1
  fi

  while lsof -i :$PORT > /dev/null 2>&1; do
    echo "⚠️ Port $PORT is in use. Trying port $((PORT + 1))..."
    PORT=$((PORT + 1))
    if [ $PORT -gt 3010 ]; then
      echo "❌ Error: No available ports in range 3000-3010."
      exit 1
    fi
  done
  echo "✅ Using port $PORT for API."

  # Pass environment variables directly from env.json
  sam local start-api \
    --template-file "${TEMPLATE_FILE}" \
    --docker-network host \
    --env-vars "${ENV_PATH}" \
    --port "${PORT}" \
    --host 0.0.0.0 \
    --static-dir public \
    --layer-cache-basedir "${HOME}/.aws-sam/layers-pkg" || {
      echo "❌ Error: Failed to start local API."
      exit 1
    }
else
  echo "🚀 Remote API setup will be handled by CloudFormation stack (no action taken here)."
fi