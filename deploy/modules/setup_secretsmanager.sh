#!/usr/bin/env bash
# deploy/modules/setup_secretsmanager.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "🚀 Setting up LocalStack Secrets Manager for local development..."

# Fibonacci backoff variables
MAX_ATTEMPTS=5
a=1
b=1
attempt=1

while [ $attempt -le $MAX_ATTEMPTS ]; do
  # Check if LocalStack is running
  if ! docker ps -q -f "name=localstack" | grep -q .; then
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: LocalStack container not found. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    # Update Fibonacci sequence
    fib_next=$((a + b))
    a=$b
    b=$fib_next
    continue
  fi

  # Attempt to create or update the secret
  SECRET_DATA='{"test@example.com": {"password": "$2b$12$KIXp8e8f9z2b3c4d5e6f7u", "requires_change": true, "totp_secret": "", "biometric_key": ""}}'
  aws --endpoint-url=http://localhost:4566 secretsmanager create-secret --name UserCredentials --secret-string "$SECRET_DATA" || {
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: Failed to create secret. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    # Update Fibonacci sequence
    fib_next=$((a + b))
    a=$b
    b=$fib_next
    continue
  }

  # Verify the secret
  if aws --endpoint-url=http://localhost:4566 secretsmanager get-secret-value --secret-id UserCredentials > /dev/null 2>&1; then
    echo "✅ UserCredentials secret created and verified in LocalStack."
    exit 0
  else
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: Failed to verify secret. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    # Update Fibonacci sequence
    fib_next=$((a + b))
    a=$b
    b=$fib_next
  fi
done

echo "❌ Error: Failed to setup Secrets Manager after $MAX_ATTEMPTS attempts."
exit 1