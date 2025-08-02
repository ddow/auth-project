#!/usr/bin/env bash
# deploy/modules/04_setup_dynamodb.sh

set -euo pipefail

echo "Debug: LOCAL_ONLY received as '$1'"

LOCAL_ONLY="${1:-false}"

if [ "$LOCAL_ONLY" == "true" ]; then
  echo "🚀 Starting local DynamoDB process..."

  # Retry loop to check if Docker daemon is running (up to 3 attempts with 5-second delays)
  MAX_ATTEMPTS=3
  ATTEMPT=1
  until docker info > /dev/null 2>&1; do
    if [ $ATTEMPT -ge $MAX_ATTEMPTS ]; then
      echo "❌ Error: Docker daemon is not running after $MAX_ATTEMPTS attempts. Please start Docker Desktop or the Docker service and try again."
      exit 1
    fi
    echo "⚠️ Docker daemon not running (attempt $ATTEMPT/$MAX_ATTEMPTS). Waiting 5 seconds..."
    sleep 5
    ((ATTEMPT++))
  done
  echo "✅ Docker daemon confirmed running."

  PORT=8000
  echo "Checking port $PORT availability..."
  if lsof -i :$PORT > /dev/null 2>&1; then
    echo "⚠️ Port $PORT is in use. Killing the occupying process..."
    lsof -i :$PORT -t | xargs kill -9 2>/dev/null || true
    sleep 1
    echo "✅ Port $PORT kill attempted."
  else
    echo "✅ Port $PORT is free."
  fi

  echo "Starting DynamoDB container..."
  CONTAINER_ID=$(docker run -d -p $PORT:8000 amazon/dynamodb-local)
  echo "✅ DynamoDB container started with ID: $CONTAINER_ID"
  echo "Container ID saved to /tmp/dynamo_pid"
  echo $CONTAINER_ID > /tmp/dynamo_pid

  echo "Waiting for DynamoDB to initialize (5 seconds)..."
  sleep 5
  echo "✅ Initial wait completed."

  echo "Checking DynamoDB readiness..."
  until aws dynamodb list-tables --endpoint-url http://localhost:$PORT > /dev/null 2>&1; do
    echo "⚠️ DynamoDB not ready yet. Retrying in 2 seconds..."
    sleep 2
  done
  echo "✅ DynamoDB is ready on port $PORT."

  echo "Creating AuthUsers table..."
  aws dynamodb create-table \
      --table-name AuthUsers \
      --attribute-definitions AttributeName=username,AttributeType=S \
      --key-schema AttributeName=username,KeyType=HASH \
      --provisioned-throughput ReadCapacityUnits=5,WriteCapacityUnits=5 \
      --endpoint-url http://localhost:$PORT
  echo "✅ AuthUsers table creation command executed."

  echo "Verifying table creation..."
  aws dynamodb describe-table --table-name AuthUsers --endpoint-url http://localhost:$PORT > /tmp/table_desc.json
  if [ $? -eq 0 ]; then
    echo "✅ AuthUsers table verified created: $(cat /tmp/table_desc.json | jq -r '.Table.TableStatus')"
  else
    echo "❌ Table creation verification failed."
    exit 1
  fi
  rm -f /tmp/table_desc.json

  echo "Seeding test user..."
  aws dynamodb put-item \
      --table-name AuthUsers \
      --item '{
          "username": {"S": "test@example.com"},
          "password": {"S": "$2b$12$KIXp8e8f9z2b3c4d5e6f7u"},
          "requires_change": {"BOOL": true},
          "totp_secret": {"S": ""},
          "biometric_key": {"S": ""}
      }' \
      --endpoint-url http://localhost:$PORT
  echo "✅ Test user seeding command executed."

  echo "Verifying test user seeding..."
  aws dynamodb get-item \
      --table-name AuthUsers \
      --key '{"username": {"S": "test@example.com"}}' \
      --endpoint-url http://localhost:$PORT > /tmp/user_check.json
  if [ $? -eq 0 ] && [ -n "$(cat /tmp/user_check.json | jq -r '.Item')" ]; then
    echo "✅ Test user verified seeded: $(cat /tmp/user_check.json | jq -r '.Item.username.S')"
  else
    echo "❌ Test user seeding verification failed."
    exit 1
  fi
  rm -f /tmp/user_check.json

  echo "DynamoDB setup completed successfully."
else
  echo "🚀 Remote DynamoDB setup will be handled by CloudFormation stack (no action taken here)."
fi