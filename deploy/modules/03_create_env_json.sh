#!/usr/bin/env bash
# deploy/modules/03_create_env_json.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "🚀 Preparing configuration file for SAM..."
cat > "${SCRIPT_DIR}/env.json" << EOF
{
  "AuthFunction": {
    "DYNAMO_TABLE": "AuthUsers",
    "DOMAIN": "localhost",
    "COGNITO_USER_POOL_ID": "local-pool",
    "COGNITO_CLIENT_ID": "testclientid",
    "JWT_SECRET": "your-secret-key",
    "IS_LOCAL": "true",
    "AWS_SAM_LOCAL": "true"
  }
}
EOF

if [ ! -f "${SCRIPT_DIR}/env.json" ]; then
  echo "❌ Error: env.json was not created."
  exit 1
fi
echo "✅ Configuration file created at ${SCRIPT_DIR}"

if ! jq -e . "${SCRIPT_DIR}/env.json" > /dev/null 2>&1; then
  echo "❌ Error: env.json contains invalid JSON."
  exit 1
fi