#!/usr/bin/env bash
# deploy/modules/create_env_json.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "🚀 Preparing configuration file for SAM..."

# Fibonacci backoff variables
MAX_ATTEMPTS=5
a=1
b=1
attempt=1

while [ $attempt -le $MAX_ATTEMPTS ]; do
  cat > "${SCRIPT_DIR}/env.json" << EOF
{
  "AuthFunction": {
    "IS_LOCAL": "true",
    "AWS_ENDPOINT_URL": "http://host.docker.internal:4566",
    "JWT_SECRET": "your-secret-key"
  }
}
EOF

  if [ -f "${SCRIPT_DIR}/env.json" ]; then
    if ! jq -e . "${SCRIPT_DIR}/env.json" > /dev/null 2>&1; then
      echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: env.json contains invalid JSON. Retrying in $b seconds..."
      sleep $b
      ((attempt++))
      # Update Fibonacci sequence
      fib_next=$((a + b))
      a=$b
      b=$fib_next
      continue
    fi
    echo "✅ Configuration file created and validated at ${SCRIPT_DIR}"
    exit 0
  else
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: env.json was not created. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    # Update Fibonacci sequence
    fib_next=$((a + b))
    a=$b
    b=$fib_next
  fi
done

echo "❌ Error: Failed to create or validate env.json after $MAX_ATTEMPTS attempts."
exit 1