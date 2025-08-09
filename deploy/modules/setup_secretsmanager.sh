#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "🚀 Setting up LocalStack Secrets Manager for local development..."

MAX_ATTEMPTS=5
a=1
b=1
attempt=1

# Generate bcrypt hash using Python bcrypt library to match main.py
PASSWORD_HASH=$(python3 -c 'import bcrypt; print(bcrypt.hashpw("testpassword".encode(), bcrypt.gensalt()).decode())')

while [ $attempt -le $MAX_ATTEMPTS ]; do
  if ! docker ps -q -f "name=localstack" | grep -q .; then
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: LocalStack container not found. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    fib_next=$((a + b))
    a=$b
    b=$fib_next
    continue
  fi

  # Create UserCredentials secret
  SECRET_DATA='{"testuser":{"password":"'"$PASSWORD_HASH"'","requires_change":true,"totp_secret":"ABCDEF1234567890","biometric_key":""}}'
  aws --endpoint-url=http://localhost:4566 secretsmanager create-secret --name UserCredentials --secret-string "$SECRET_DATA" || {
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: Failed to create UserCredentials secret. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    fib_next=$((a + b))
    a=$b
    b=$fib_next
    continue
  }

  # Create auth-project-secret for JWT_SECRET
  JWT_SECRET='{"SECRET_KEY":"'$(openssl rand -hex 32)'"}'
  aws --endpoint-url=http://localhost:4566 secretsmanager create-secret --name auth-project-secret --secret-string "$JWT_SECRET" || {
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: Failed to create auth-project-secret. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    fib_next=$((a + b))
    a=$b
    b=$fib_next
    continue
  }

  if aws --endpoint-url=http://localhost:4566 secretsmanager get-secret-value --secret-id UserCredentials > /dev/null 2>&1 && \
     aws --endpoint-url=http://localhost:4566 secretsmanager get-secret-value --secret-id auth-project-secret > /dev/null 2>&1; then
    echo "✅ UserCredentials and auth-project-secret created and verified in LocalStack."
    exit 0
  else
    echo "⚠️ Attempt $attempt/$MAX_ATTEMPTS: Failed to verify secrets. Retrying in $b seconds..."
    sleep $b
    ((attempt++))
    fib_next=$((a + b))
    a=$b
    b=$fib_next
  fi
done

echo "❌ Error: Failed to setup Secrets Manager after $MAX_ATTEMPTS attempts."
exit 1