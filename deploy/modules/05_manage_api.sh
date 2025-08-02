#!/usr/bin/env bash
# deploy/modules/05_manage_api.sh

set -euo pipefail

echo "Debug: LOCAL_ONLY received as '$1'"

LOCAL_ONLY="${1:-false}"

if [ "$LOCAL_ONLY" == "true" ]; then
  echo "🚀 Starting local API..."
  TEMPLATE_FILE="${PWD}/.aws-sam/build/template.yaml"
  ENV_PATH="${PWD}/env.json"
  PORT=3000

  while lsof -i :$PORT > /dev/null 2>&1; do
    echo "⚠️ Port $PORT is in use. Trying port $((PORT + 1))..."
    PORT=$((PORT + 1))
  done
  echo "✅ Using port $PORT for API."

  sam local start-api \
    --template-file "${TEMPLATE_FILE}" \
    --docker-network host \
    --env-vars "${ENV_PATH}" \
    --port "${PORT}" \
    --container-env-vars "${ENV_PATH}" \
    --host 127.0.0.1 \
    --static-dir public \
    --layer-cache-basedir "${HOME}/.aws-sam/layers-pkg" \
    --container-host localhost \
    --container-host-interface 127.0.0.1
else
  echo "🚀 Remote API setup will be handled by CloudFormation stack (no action taken here)."
fi